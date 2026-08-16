using HLSDownloader.Worker;

namespace HLSDownloader.Media.Tests;

public sealed class WorkerFileLogTests
{
    [Fact]
    public void RedactsSignedUrlsAndSecretAssignments()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("worker.log");
        var log = new WorkerFileLog(path);

        log.Write("GET https://media.example/video.ts?token=abc123 token=abc123");

        string content = File.ReadAllText(path);
        Assert.DoesNotContain("abc123", content, StringComparison.Ordinal);
        Assert.Contains("host=media.example", content, StringComparison.Ordinal);
        Assert.Contains("token=[REDACTED]", content, StringComparison.Ordinal);
    }
}
