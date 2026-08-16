using HLSDownloader.Media;
using HLSDownloader.Core;

namespace HLSDownloader.Worker;

public sealed class WorkerCoordinator(
    JobLedger ledger,
    IMediaComposer composer,
    HlsDownloadCoordinator? hlsDownloadCoordinator = null,
    Action<string>? log = null)
{
    private readonly JobLedger _ledger = ledger;
    private readonly IMediaComposer _composer = composer;
    private readonly HlsDownloadCoordinator? _hlsDownloadCoordinator = hlsDownloadCoordinator;
    private readonly Action<string>? _log = log;
    private readonly SemaphoreSlim _wakeSignal = new(0, 1);
    private readonly SemaphoreSlim _lifecycleGate = new(1, 1);
    private readonly object _cancellationLock = new();
    private readonly Dictionary<Guid, CancellationTokenSource> _running = new();
    private bool _stopping;
    private int _activeClientOperations;

    public event EventHandler<WorkerProgressEvent>? ProgressChanged;
    public event EventHandler? ActivityOccurred;

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        await _ledger.RequeueInterruptedJobsAsync(cancellationToken).ConfigureAwait(false);
        while (!cancellationToken.IsCancellationRequested)
        {
            WorkerJobRecord? next = (await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false))
                .Where(job => job.State == WorkerJobState.Queued)
                .OrderBy(job => job.CreatedAt)
                .FirstOrDefault();
            if (next is null)
            {
                await _wakeSignal.WaitAsync(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false);
                continue;
            }

            await ProcessAsync(next, cancellationToken).ConfigureAwait(false);
        }
    }

    public async Task EnqueueAsync(WorkerJobRecord job, CancellationToken cancellationToken = default)
    {
        if (job.Kind == WorkerJobKind.LocalMedia && !File.Exists(job.InputPath))
        {
            throw new FileNotFoundException("The worker input does not exist.", job.InputPath);
        }

        if (job.Kind == WorkerJobKind.HlsUrl &&
            (!Uri.TryCreate(job.CandidateUri, UriKind.Absolute, out _) ||
             !Uri.TryCreate(job.RequestedUri, UriKind.Absolute, out _) ||
             !Uri.TryCreate(job.PageUri, UriKind.Absolute, out _)))
        {
            throw new ArgumentException("An HLS URL job requires absolute requested, effective candidate, and page URIs.", nameof(job));
        }

        if (job.State != WorkerJobState.Queued)
        {
            throw new ArgumentException("New jobs must be queued.", nameof(job));
        }

        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_stopping)
            {
                throw new InvalidOperationException("The idle background worker is shutting down; start a new worker and retry.");
            }

            WorkerJobRecord? existing = (await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false))
                .FirstOrDefault(candidate => candidate.Id == job.Id);
            if (existing is not null)
            {
                if (!HasSameJobIdentity(existing, job))
                {
                    throw new InvalidOperationException($"Worker job id {job.Id} is already used by a different request.");
                }

                Publish(new WorkerProgressEvent(existing.Id, existing.State, existing.Progress, existing.OutputPath, existing.Error));
                return;
            }

            await _ledger.AddAsync(job, cancellationToken).ConfigureAwait(false);
            Publish(new WorkerProgressEvent(job.Id, job.State, job.Progress));
            Wake();
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    public async Task CancelAsync(Guid jobId, CancellationToken cancellationToken = default)
    {
        CancellationTokenSource? running;
        lock (_cancellationLock)
        {
            _running.TryGetValue(jobId, out running);
        }

        if (running is not null)
        {
            running.Cancel();
            return;
        }

        await _ledger.UpdateAsync(jobId, job => job.State == WorkerJobState.Queued
            ? job with { State = WorkerJobState.Cancelled, Error = "Cancelled before processing." }
            : job, cancellationToken).ConfigureAwait(false);
        WorkerJobRecord updated = (await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false))
            .Single(job => job.Id == jobId);
        Publish(new WorkerProgressEvent(updated.Id, updated.State, updated.Progress, updated.OutputPath, updated.Error));
    }

    public void Wake()
    {
        if (_wakeSignal.CurrentCount == 0)
        {
            _wakeSignal.Release();
        }
    }

    public void NotifyClientActivity() => ActivityOccurred?.Invoke(this, EventArgs.Empty);

    public IDisposable BeginClientOperation()
    {
        if (Volatile.Read(ref _stopping))
        {
            throw new InvalidOperationException("The idle background worker is shutting down.");
        }

        Interlocked.Increment(ref _activeClientOperations);
        if (Volatile.Read(ref _stopping))
        {
            Interlocked.Decrement(ref _activeClientOperations);
            throw new InvalidOperationException("The idle background worker is shutting down.");
        }

        NotifyClientActivity();
        return new ClientActivityLease(this);
    }

    public async Task<bool> TryBeginIdleShutdownAsync(CancellationToken cancellationToken = default)
    {
        await _lifecycleGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (_stopping)
            {
                return true;
            }

            bool hasRunningProcess;
            lock (_cancellationLock)
            {
                hasRunningProcess = _running.Count > 0;
            }

            bool hasActiveLedgerJob = (await _ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false))
                .Any(job => job.State is WorkerJobState.Queued or WorkerJobState.Running);
            if (hasRunningProcess || hasActiveLedgerJob || Volatile.Read(ref _activeClientOperations) > 0)
            {
                return false;
            }

            Volatile.Write(ref _stopping, true);
            return true;
        }
        finally
        {
            _lifecycleGate.Release();
        }
    }

    private async Task ProcessAsync(WorkerJobRecord job, CancellationToken workerCancellationToken)
    {
        using var jobCancellation = CancellationTokenSource.CreateLinkedTokenSource(workerCancellationToken);
        lock (_cancellationLock)
        {
            _running[job.Id] = jobCancellation;
        }

        try
        {
            await _ledger.UpdateAsync(job.Id, current => current with
            {
                State = WorkerJobState.Running,
                Progress = 0.05,
                AttemptCount = current.AttemptCount + 1,
                Error = null
            }, workerCancellationToken).ConfigureAwait(false);
            Publish(new WorkerProgressEvent(job.Id, WorkerJobState.Running, 0.05));

            MediaComposeResult result;
            if (job.Kind == WorkerJobKind.HlsUrl)
            {
                if (_hlsDownloadCoordinator is null)
                {
                    throw new InvalidOperationException("The worker was not configured for HLS URL jobs.");
                }

                var candidate = new MediaCandidate(
                    new Uri(job.CandidateUri!, UriKind.Absolute),
                    MediaCandidateKind.Hls,
                    MediaCandidateOrigin.Direct,
                    new Uri(job.PageUri!, UriKind.Absolute),
                    RequestedUri: new Uri(job.RequestedUri!, UriKind.Absolute));
                var progress = new InlineProgress<DownloadProgress>(update =>
                {
                    double fraction = update.Fraction ?? 0.05;
                    Publish(new WorkerProgressEvent(job.Id, WorkerJobState.Running, fraction));
                });
                result = await _hlsDownloadCoordinator.DownloadAsync(
                    candidate,
                    job.OutputBasePath,
                    progress,
                    jobCancellation.Token).ConfigureAwait(false);
            }
            else
            {
                result = await _composer.ComposeAsync(
                    new MediaComposeRequest(job.InputPath, job.OutputBasePath),
                    jobCancellation.Token).ConfigureAwait(false);
            }
            await _ledger.UpdateAsync(job.Id, current => current with
            {
                State = WorkerJobState.Completed,
                Progress = 1,
                OutputPath = result.OutputPath,
                Error = null
            }, workerCancellationToken).ConfigureAwait(false);
            Publish(new WorkerProgressEvent(job.Id, WorkerJobState.Completed, 1, result.OutputPath));
        }
        catch (OperationCanceledException) when (jobCancellation.IsCancellationRequested && !workerCancellationToken.IsCancellationRequested)
        {
            CleanupPartialOutputs(job.OutputBasePath);
            await _ledger.UpdateAsync(job.Id, current => current with
            {
                State = WorkerJobState.Cancelled,
                Error = "Cancelled.",
                Progress = 0
            }, workerCancellationToken).ConfigureAwait(false);
            Publish(new WorkerProgressEvent(job.Id, WorkerJobState.Cancelled, 0, Error: "Cancelled."));
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            CleanupPartialOutputs(job.OutputBasePath);
            string safeMessage = DiagnosticRedactor.Redact(ex.Message);
            _log?.Invoke($"Worker job {job.Id} failed: {safeMessage}");
            await _ledger.UpdateAsync(job.Id, current => current with
            {
                State = WorkerJobState.Failed,
                Error = safeMessage,
                Progress = 0
            }, workerCancellationToken).ConfigureAwait(false);
            Publish(new WorkerProgressEvent(job.Id, WorkerJobState.Failed, 0, Error: safeMessage));
        }
        finally
        {
            lock (_cancellationLock)
            {
                _running.Remove(job.Id);
            }
        }
    }

    private void Publish(WorkerProgressEvent progress)
    {
        ActivityOccurred?.Invoke(this, EventArgs.Empty);
        ProgressChanged?.Invoke(this, progress);
    }

    private static void CleanupPartialOutputs(string outputBasePath)
    {
        foreach (string path in new[]
        {
            Path.ChangeExtension(outputBasePath, ".mp4") + ".part",
            Path.ChangeExtension(outputBasePath, ".wav") + ".part"
        })
        {
            try
            {
                File.Delete(path);
            }
            catch (IOException)
            {
                // The composing process may still be closing its handle.
            }
        }
    }

    private static bool HasSameJobIdentity(WorkerJobRecord left, WorkerJobRecord right) =>
        left.Id == right.Id &&
        left.Kind == right.Kind &&
        string.Equals(left.InputPath, right.InputPath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.OutputBasePath, right.OutputBasePath, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.CandidateUri, right.CandidateUri, StringComparison.Ordinal) &&
        string.Equals(left.RequestedUri, right.RequestedUri, StringComparison.Ordinal) &&
        string.Equals(left.PageUri, right.PageUri, StringComparison.Ordinal);

    private sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed class ClientActivityLease(WorkerCoordinator owner) : IDisposable
    {
        private WorkerCoordinator? _owner = owner;

        public void Dispose()
        {
            WorkerCoordinator? current = Interlocked.Exchange(ref _owner, null);
            if (current is not null)
            {
                Interlocked.Decrement(ref current._activeClientOperations);
                current.NotifyClientActivity();
            }
        }
    }
}
