using HLSDownloader.Worker;

namespace HLSDownloader.Media.Tests;

public sealed class JobLedgerTests
{
    [Fact]
    public async Task PersistsAtomicallyAndRequeuesInterruptedJob()
    {
        using var scope = new TestFileScope();
        string ledgerPath = scope.PathFor("state/jobs.json");
        var ledger = new JobLedger(ledgerPath);
        WorkerJobRecord job = WorkerJobRecord.Create(scope.PathFor("input.m3u8"), scope.PathFor("output"));

        await ledger.AddAsync(job);
        await ledger.UpdateAsync(job.Id, current => current with { State = WorkerJobState.Running, Progress = 0.5 });
        await ledger.RequeueInterruptedJobsAsync();

        WorkerJobRecord restored = Assert.Single(await new JobLedger(ledgerPath).GetJobsAsync());
        Assert.Equal(WorkerJobState.Queued, restored.State);
        Assert.Equal(0, restored.Progress);
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(ledgerPath)!, "*.tmp"));
    }

    [Fact]
    public async Task DpapiLedgerDoesNotStoreSignedUrlInPlaintext()
    {
        if (!OperatingSystem.IsWindows())
        {
            return;
        }

        using var scope = new TestFileScope();
        string ledgerPath = scope.PathFor("state/jobs.dat");
        var ledger = new JobLedger(ledgerPath);
        const string secret = "top-secret-signed-token";
        WorkerJobRecord job = WorkerJobRecord.CreateHls(
            new Uri($"https://media.example/master.m3u8?token={secret}"),
            new Uri($"https://media.example/original.m3u8?token={secret}"),
            new Uri("https://media.example/watch"),
            scope.PathFor("output"));

        await ledger.AddAsync(job);

        string stored = System.Text.Encoding.UTF8.GetString(await File.ReadAllBytesAsync(ledgerPath));
        Assert.DoesNotContain(secret, stored, StringComparison.Ordinal);
        Assert.StartsWith("HLJ1", stored, StringComparison.Ordinal);
        WorkerJobRecord restored = Assert.Single(await ledger.GetJobsAsync());
        Assert.Contains("original.m3u8", restored.RequestedUri, StringComparison.Ordinal);
    }

    [Fact]
    public async Task RejectsUnprotectedLedgerJson()
    {
        using var scope = new TestFileScope();
        string ledgerPath = scope.PathFor("jobs.json");
        await File.WriteAllTextAsync(ledgerPath, "{\"version\":1,\"jobs\":[]}");

        await Assert.ThrowsAsync<InvalidDataException>(() => new JobLedger(ledgerPath).GetJobsAsync());
    }
}
