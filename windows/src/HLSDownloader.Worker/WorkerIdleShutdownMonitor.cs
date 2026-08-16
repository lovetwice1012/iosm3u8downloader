namespace HLSDownloader.Worker;

public sealed class WorkerIdleShutdownMonitor
{
    private readonly WorkerCoordinator _coordinator;
    private readonly CancellationTokenSource _shutdownSource;
    private readonly TimeSpan _idleTimeout;
    private readonly TimeSpan _pollInterval;
    private long _lastActivityUtcTicks;

    public WorkerIdleShutdownMonitor(
        WorkerCoordinator coordinator,
        CancellationTokenSource shutdownSource,
        TimeSpan? idleTimeout = null,
        TimeSpan? pollInterval = null)
    {
        _coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
        _shutdownSource = shutdownSource ?? throw new ArgumentNullException(nameof(shutdownSource));
        _idleTimeout = idleTimeout ?? TimeSpan.FromSeconds(60);
        _pollInterval = pollInterval ?? TimeSpan.FromSeconds(2);
        if (_idleTimeout <= TimeSpan.Zero || _pollInterval <= TimeSpan.Zero || _pollInterval > _idleTimeout)
        {
            throw new ArgumentOutOfRangeException(nameof(idleTimeout), "Idle and polling intervals must be positive, and polling cannot exceed the idle timeout.");
        }

        Touch();
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        _coordinator.ActivityOccurred += OnActivityOccurred;
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(_pollInterval, cancellationToken).ConfigureAwait(false);
                DateTimeOffset lastActivity = new(Interlocked.Read(ref _lastActivityUtcTicks), TimeSpan.Zero);
                if (DateTimeOffset.UtcNow - lastActivity < _idleTimeout)
                {
                    continue;
                }

                if (await _coordinator.TryBeginIdleShutdownAsync(cancellationToken).ConfigureAwait(false))
                {
                    _shutdownSource.Cancel();
                    return;
                }

                // An active queued/running job was observed. Its existence itself is activity,
                // preventing repeated shutdown checks while work remains active.
                Touch();
            }
        }
        finally
        {
            _coordinator.ActivityOccurred -= OnActivityOccurred;
        }
    }

    private void OnActivityOccurred(object? sender, EventArgs eventArgs) => Touch();

    private void Touch() => Interlocked.Exchange(ref _lastActivityUtcTicks, DateTimeOffset.UtcNow.UtcTicks);
}
