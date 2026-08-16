using System.Diagnostics;
using HLSDownloader.Worker;

namespace HLSDownloader.Media.Tests;

public sealed class WorkerSingleInstanceLeaseTests
{
    [Fact]
    public void ReplacementWorkerWaitsForStoppingWorkerMutexThenAcquiresIt()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        string pipeName = $"HLSDownloader.Worker.Test.{Guid.NewGuid():N}";
        WorkerSingleInstanceLease? currentWorker = WorkerSingleInstanceLease.TryAcquire(
            pipeName,
            TimeSpan.Zero);
        Assert.NotNull(currentWorker);

        using var replacementStarted = new ManualResetEventSlim();
        TimeSpan replacementWait = TimeSpan.Zero;
        WorkerSingleInstanceLease? replacement = null;
        Exception? replacementFailure = null;
        var replacementThread = new Thread(() =>
        {
            try
            {
                replacementStarted.Set();
                var stopwatch = Stopwatch.StartNew();
                replacement = WorkerSingleInstanceLease.TryAcquire(pipeName, TimeSpan.FromSeconds(2));
                replacementWait = stopwatch.Elapsed;
            }
            catch (Exception ex)
            {
                replacementFailure = ex;
            }
            finally
            {
                replacement?.Dispose();
            }
        })
        {
            IsBackground = true,
            Name = "replacement-worker-mutex-test"
        };

        try
        {
            replacementThread.Start();
            Assert.True(replacementStarted.Wait(TimeSpan.FromSeconds(1)));
            Assert.False(replacementThread.Join(TimeSpan.FromMilliseconds(150)));

            // Models the old idle worker finishing shutdown and releasing its mutex.
            currentWorker!.Dispose();
            currentWorker = null;

            Assert.True(replacementThread.Join(TimeSpan.FromSeconds(2)));
            Assert.Null(replacementFailure);
            Assert.NotNull(replacement);
            Assert.True(replacementWait >= TimeSpan.FromMilliseconds(100));
            Assert.True(replacementWait < TimeSpan.FromSeconds(2));
        }
        finally
        {
            currentWorker?.Dispose();
            if (replacementThread.IsAlive)
            {
                Assert.True(replacementThread.Join(TimeSpan.FromSeconds(3)));
            }
        }
    }
}
