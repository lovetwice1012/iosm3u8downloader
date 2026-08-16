namespace HLSDownloader.Worker;

/// <summary>
/// Owns the per-pipe worker mutex. The lease must be acquired and disposed on
/// the same thread because <see cref="Mutex"/> ownership is thread-affine.
/// </summary>
public sealed class WorkerSingleInstanceLease : IDisposable
{
    private readonly Mutex _mutex;
    private bool _ownsMutex;

    private WorkerSingleInstanceLease(Mutex mutex)
    {
        _mutex = mutex;
        _ownsMutex = true;
    }

    public static WorkerSingleInstanceLease? TryAcquire(string pipeName, TimeSpan waitTimeout)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(pipeName);
        if (waitTimeout < TimeSpan.Zero && waitTimeout != Timeout.InfiniteTimeSpan)
        {
            throw new ArgumentOutOfRangeException(nameof(waitTimeout));
        }

        var mutex = new Mutex(initiallyOwned: false, $"Local\\{pipeName}.SingleInstance");
        bool ownsMutex;
        try
        {
            ownsMutex = mutex.WaitOne(waitTimeout);
        }
        catch (AbandonedMutexException)
        {
            ownsMutex = true;
        }

        if (ownsMutex)
        {
            return new WorkerSingleInstanceLease(mutex);
        }

        mutex.Dispose();
        return null;
    }

    public void Dispose()
    {
        if (!_ownsMutex)
        {
            return;
        }

        _ownsMutex = false;
        try
        {
            _mutex.ReleaseMutex();
        }
        finally
        {
            _mutex.Dispose();
        }
    }
}
