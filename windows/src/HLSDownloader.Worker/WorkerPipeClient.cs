using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace HLSDownloader.Worker;

public sealed class WorkerPipeClient(string pipeName)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);
    private readonly string _pipeName = pipeName;

    public Task<WorkerPipeResponse> EnqueueAsync(WorkerJobRecord job, CancellationToken cancellationToken = default) =>
        SendAsync(new WorkerPipeCommand("enqueue", job), cancellationToken);

    public Task<WorkerPipeResponse> CancelAsync(Guid jobId, CancellationToken cancellationToken = default) =>
        SendAsync(new WorkerPipeCommand("cancel", JobId: jobId), cancellationToken);

    public Task<WorkerPipeResponse> GetStatusAsync(CancellationToken cancellationToken = default) =>
        SendAsync(new WorkerPipeCommand("status"), cancellationToken);

    public Task<WorkerPipeResponse> ShutdownAsync(CancellationToken cancellationToken = default) =>
        SendAsync(new WorkerPipeCommand("shutdown"), cancellationToken);

    public async IAsyncEnumerable<WorkerPipeResponse> WatchProgressAsync(
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        await using var pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(5000, cancellationToken).ConfigureAwait(false);
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        await writer.WriteLineAsync(JsonSerializer.Serialize(new WorkerPipeCommand("watch"), JsonOptions)).ConfigureAwait(false);
        while (!cancellationToken.IsCancellationRequested)
        {
            string? line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
            if (line is null)
            {
                yield break;
            }

            yield return JsonSerializer.Deserialize<WorkerPipeResponse>(line, JsonOptions)
                ?? throw new InvalidDataException("The background worker returned an invalid progress response.");
        }
    }

    private async Task<WorkerPipeResponse> SendAsync(WorkerPipeCommand command, CancellationToken cancellationToken)
    {
        for (int attempt = 0; ; attempt++)
        {
            try
            {
                return await SendOnceAsync(command, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception ex) when (attempt == 0 && ex is IOException or TimeoutException)
            {
                // An idle worker may exit between UI launch and pipe connection. The replacement
                // process waits for the old single-instance mutex, so one bounded retry reattaches.
                await Task.Delay(TimeSpan.FromMilliseconds(200), cancellationToken).ConfigureAwait(false);
            }
        }
    }

    private async Task<WorkerPipeResponse> SendOnceAsync(WorkerPipeCommand command, CancellationToken cancellationToken)
    {
        await using var pipe = new NamedPipeClientStream(".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        await pipe.ConnectAsync(5000, cancellationToken).ConfigureAwait(false);
        using var reader = new StreamReader(pipe, new UTF8Encoding(false), leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        await writer.WriteLineAsync(JsonSerializer.Serialize(command, JsonOptions)).ConfigureAwait(false);
        string? line = await reader.ReadLineAsync(cancellationToken).ConfigureAwait(false);
        return line is null
            ? throw new IOException("The background worker disconnected without a response.")
            : JsonSerializer.Deserialize<WorkerPipeResponse>(line, JsonOptions)
              ?? throw new InvalidDataException("The background worker returned an invalid response.");
    }
}

public static class BackgroundWorkerLauncher
{
    public static Process Start(
        string workerExecutable,
        string ledgerPath,
        string pipeName = "HLSDownloader.Worker")
    {
        if (!File.Exists(workerExecutable))
        {
            throw new FileNotFoundException("The background worker executable was not found.", workerExecutable);
        }

        var startInfo = new ProcessStartInfo
        {
            FileName = Path.GetFullPath(workerExecutable),
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = Path.GetDirectoryName(Path.GetFullPath(workerExecutable))!
        };
        startInfo.ArgumentList.Add("--ledger");
        startInfo.ArgumentList.Add(Path.GetFullPath(ledgerPath));
        startInfo.ArgumentList.Add("--pipe");
        startInfo.ArgumentList.Add(pipeName);
        return Process.Start(startInfo) ?? throw new InvalidOperationException("The background worker could not be started.");
    }
}
