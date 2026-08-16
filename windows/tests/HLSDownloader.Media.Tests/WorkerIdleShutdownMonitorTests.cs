using HLSDownloader.Media;
using HLSDownloader.Worker;

namespace HLSDownloader.Media.Tests;

public sealed class WorkerIdleShutdownMonitorTests
{
    [Fact]
    public async Task ExitsAfterContinuousIdlePeriod()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        var ledger = new JobLedger(scope.PathFor("jobs.dat"));
        var coordinator = new WorkerCoordinator(ledger, new NeverCalledComposer());
        using var shutdown = new CancellationTokenSource();
        var monitor = new WorkerIdleShutdownMonitor(
            coordinator,
            shutdown,
            TimeSpan.FromMilliseconds(80),
            TimeSpan.FromMilliseconds(10));

        await monitor.RunAsync(CancellationToken.None).WaitAsync(TimeSpan.FromSeconds(2));

        Assert.True(shutdown.IsCancellationRequested);
        Assert.True(await coordinator.TryBeginIdleShutdownAsync());
        Assert.Throws<InvalidOperationException>(() => coordinator.BeginClientOperation());
    }

    [Theory]
    [InlineData(WorkerJobState.Queued)]
    [InlineData(WorkerJobState.Running)]
    public async Task NeverExitsWhileLedgerContainsActiveJob(WorkerJobState state)
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        string input = scope.PathFor("input.ts");
        await File.WriteAllBytesAsync(input, [1]);
        var ledger = new JobLedger(scope.PathFor("jobs.dat"));
        WorkerJobRecord job = WorkerJobRecord.Create(input, scope.PathFor("output"));
        await ledger.AddAsync(job);
        if (state == WorkerJobState.Running)
        {
            await ledger.UpdateAsync(job.Id, current => current with { State = state });
        }
        var coordinator = new WorkerCoordinator(ledger, new NeverCalledComposer());
        using var shutdown = new CancellationTokenSource();
        using var stopTest = new CancellationTokenSource(TimeSpan.FromMilliseconds(220));
        var monitor = new WorkerIdleShutdownMonitor(
            coordinator,
            shutdown,
            TimeSpan.FromMilliseconds(60),
            TimeSpan.FromMilliseconds(10));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => monitor.RunAsync(stopTest.Token));

        Assert.False(shutdown.IsCancellationRequested);
        Assert.False(await coordinator.TryBeginIdleShutdownAsync());
    }

    [Fact]
    public async Task NeverExitsWhilePipeOperationIsAttached()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        var ledger = new JobLedger(scope.PathFor("jobs.dat"));
        var coordinator = new WorkerCoordinator(ledger, new NeverCalledComposer());
        using var shutdown = new CancellationTokenSource();
        using var stopTest = new CancellationTokenSource(TimeSpan.FromMilliseconds(180));
        var monitor = new WorkerIdleShutdownMonitor(
            coordinator,
            shutdown,
            TimeSpan.FromMilliseconds(50),
            TimeSpan.FromMilliseconds(10));

        using (coordinator.BeginClientOperation())
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => monitor.RunAsync(stopTest.Token));
            Assert.False(shutdown.IsCancellationRequested);
            Assert.False(await coordinator.TryBeginIdleShutdownAsync());
        }

        Assert.True(await coordinator.TryBeginIdleShutdownAsync());
    }

    [Fact]
    public async Task AlreadyCancelledTokenIsPropagated()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        var ledger = new JobLedger(scope.PathFor("jobs.dat"));
        var coordinator = new WorkerCoordinator(ledger, new NeverCalledComposer());
        using var shutdown = new CancellationTokenSource();
        using var stopTest = new CancellationTokenSource();
        stopTest.Cancel();
        var monitor = new WorkerIdleShutdownMonitor(
            coordinator,
            shutdown,
            TimeSpan.FromMilliseconds(50),
            TimeSpan.FromMilliseconds(10));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => monitor.RunAsync(stopTest.Token));

        Assert.False(shutdown.IsCancellationRequested);
    }

    [Fact]
    public async Task RetriedEnqueueWithSameJobIdIsIdempotent()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        string input = scope.PathFor("input.ts");
        await File.WriteAllBytesAsync(input, [1]);
        var ledger = new JobLedger(scope.PathFor("jobs.dat"));
        var coordinator = new WorkerCoordinator(ledger, new NeverCalledComposer());
        WorkerJobRecord job = WorkerJobRecord.Create(input, scope.PathFor("output"));

        await coordinator.EnqueueAsync(job);
        await coordinator.EnqueueAsync(job);

        Assert.Single(await ledger.GetJobsAsync());
    }

    private sealed class NeverCalledComposer : IMediaComposer
    {
        public Task<MediaComposeResult> ComposeAsync(
            MediaComposeRequest request,
            CancellationToken cancellationToken = default) =>
            throw new InvalidOperationException("The idle monitor must not compose media.");
    }
}
