namespace HLSDownloader.Core.Tests;

public sealed class DiagnosticRedactorTests
{
    [Fact]
    public void UrlSummaryOmitsPathQueryFragmentAndUserInfo()
    {
        var summary = DiagnosticRedactor.SummarizeUri(new Uri("https://user:pass@example.com/private/path?token=secret#frag"));
        Assert.Contains("host=example.com", summary);
        Assert.Contains("pathHash=", summary);
        Assert.DoesNotContain("private", summary);
        Assert.DoesNotContain("secret", summary);
        Assert.DoesNotContain("user", summary);
    }

    [Fact]
    public void RedactRemovesUrlsAndCommonSecrets()
    {
        var output = DiagnosticRedactor.Redact(
            "GET https://example.com/a.m3u8?token=abc token=xyz Authorization:super Bearer abc.def Cookie=sid");
        Assert.DoesNotContain("abc", output);
        Assert.DoesNotContain("xyz", output);
        Assert.DoesNotContain("super", output);
        Assert.DoesNotContain("sid", output);
        Assert.Contains("[REDACTED]", output);
    }
}
