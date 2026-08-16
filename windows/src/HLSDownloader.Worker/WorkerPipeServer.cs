using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace HLSDownloader.Worker;

public sealed class WorkerPipeServer(
    string pipeName,
    JobLedger ledger,
    WorkerCoordinator coordinator,
    CancellationTokenSource shutdownSource)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _pipeName = ValidatePipeName(pipeName);
    private readonly JobLedger _ledger = ledger;
    private readonly WorkerCoordinator _coordinator = coordinator;
    private readonly CancellationTokenSource _shutdownSource = shutdownSource;
    private readonly ConcurrentDictionary<int, Task> _connections = new();
    private int _connectionId;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var pipe = new NamedPipeServerStream(
                    _pipeName,
                    PipeDirection.InOut,
                    NamedPipeServerStream.MaxAllowedServerInstances,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                try
                {
                    await pipe.WaitForConnectionAsync(cancellationToken).ConfigureAwait(false);
                }
                catch
                {
                    await pipe.DisposeAsync().ConfigureAwait(false);
                    throw;
                }

                int id = Interlocked.Increment(ref _connectionId);
                Task connection = HandleConnectionAsync(pipe, cancellationToken);
                _connections[id] = connection;
                _ = connection.ContinueWith(
                    completedTask =>
                    {
                        _connections.TryRemove(id, out Task? ignoredTask);
                    },
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
            }
        }
        finally
        {
            await Task.WhenAll(_connections.Values).ConfigureAwait(false);
        }
    }

    private async Task HandleConnectionAsync(NamedPipeServerStream pipe, CancellationToken cancellationToken)
    {
        await using (pipe.ConfigureAwait(false))
        using (IDisposable clientActivity = _coordinator.BeginClientOperation())
        using (var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true))
        using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true })
        {
            string? line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null || line.Length > 1024 * 1024)
            {
                return;
            }

            WorkerPipeCommand command;
            try
            {
                command = JsonSerializer.Deserialize<WorkerPipeCommand>(line, JsonOptions)
                    ?? throw new InvalidDataException("The pipe command is empty.");
            }
            catch (Exception ex) when (ex is JsonException or InvalidDataException or ArgumentException or KeyNotFoundException or InvalidOperationException or FileNotFoundException)
            {
                await writer.WriteLineAsync(JsonSerializer.Serialize(new WorkerPipeResponse(false, ex.Message), JsonOptions)).ConfigureAwait(false);
                return;
            }

            if (command.Type.Equals("watch", StringComparison.OrdinalIgnoreCase))
            {
                _coordinator.NotifyClientActivity();
                await WatchProgressAsync(writer, cancellationToken).ConfigureAwait(false);
                return;
            }

            _coordinator.NotifyClientActivity();
            WorkerPipeResponse response;
            try
            {
                response = await ExecuteAsync(command, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is InvalidDataException or ArgumentException or KeyNotFoundException or InvalidOperationException or FileNotFoundException)
            {
                response = new WorkerPipeResponse(false, ex.Message);
            }

            await writer.WriteLineAsync(JsonSerializer.Serialize(response, JsonOptions)).ConfigureAwait(false);
        }
    }

    private async Task WatchProgressAsync(StreamWriter writer, CancellationToken cancellationToken)
    {
        var channel = Channel.CreateBounded<WorkerProgressEvent>(new BoundedChannelOptions(100)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false
        });
        void OnProgress(object? sender, WorkerProgressEvent progress) => channel.Writer.TryWrite(progress);
        _coordinator.ProgressChanged += OnProgress;
        try
        {
            IReadOnlyList<WorkerJobRecord> snapshot = await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false);
            await writer.WriteLineAsync(JsonSerializer.Serialize(new WorkerPipeResponse(true, Jobs: snapshot), JsonOptions)).ConfigureAwait(false);
            await foreach (WorkerProgressEvent progress in channel.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                await writer.WriteLineAsync(JsonSerializer.Serialize(new WorkerPipeResponse(true, Progress: progress), JsonOptions)).ConfigureAwait(false);
            }
        }
        catch (IOException)
        {
            // The UI disconnected; the worker and download continue.
        }
        finally
        {
            _coordinator.ProgressChanged -= OnProgress;
            channel.Writer.TryComplete();
        }
    }

    private async Task<WorkerPipeResponse> ExecuteAsync(WorkerPipeCommand command, CancellationToken cancellationToken)
    {
        switch (command.Type.ToLowerInvariant())
        {
            case "enqueue":
                if (command.Job is null)
                {
                    throw new ArgumentException("enqueue requires a job.");
                }

                await _coordinator.EnqueueAsync(command.Job, cancellationToken).ConfigureAwait(false);
                return new WorkerPipeResponse(true, Progress: new WorkerProgressEvent(command.Job.Id, WorkerJobState.Queued, 0));
            case "cancel":
                if (command.JobId is null)
                {
                    throw new ArgumentException("cancel requires a job id.");
                }

                await _coordinator.CancelAsync(command.JobId.Value, cancellationToken).ConfigureAwait(false);
                return new WorkerPipeResponse(true);
            case "status":
                return new WorkerPipeResponse(true, Jobs: await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false));
            case "shutdown":
                _shutdownSource.Cancel();
                return new WorkerPipeResponse(true);
            default:
                throw new ArgumentException($"Unknown worker command: {command.Type}");
        }
    }

    private static string ValidatePipeName(string value)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value);
        if (value.Length > 128 || value.Any(character => !char.IsAsciiLetterOrDigit(character) && character is not ('.' or '-' or '_')))
        {
            throw new ArgumentException("The named pipe identifier contains unsupported characters.", nameof(value));
        }

        return value;
    }
}
