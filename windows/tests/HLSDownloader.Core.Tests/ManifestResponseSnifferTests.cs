using System.Text;
using HLSDownloader.WebProbe;

namespace HLSDownloader.Core.Tests;

public sealed class ManifestResponseSnifferTests
{
    [Fact]
    public void BrowserProfilePathUsesStableApplicationDataSubdirectory()
    {
        var localApplicationData = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "local-app-data"));

        var result = ProbeBrowserProfilePath.FromLocalApplicationData(localApplicationData);

        Assert.Equal(
            Path.Combine(localApplicationData, "HLSDownloader.Windows", "WebView2Profile"),
            result);
    }

    [Fact]
    public void BrowserProfilePathRejectsRelativeDirectory()
    {
        Assert.Throws<ArgumentException>(() =>
            ProbeBrowserProfilePath.FromLocalApplicationData("relative-profile"));
    }

    [Fact]
    public void ShouldInspectAcceptsSmallExtensionlessTextResponse()
    {
        var result = ManifestResponseSniffer.ShouldInspect(
            new Uri("https://media.example.test/playback?id=redacted"),
            "text/plain; charset=utf-8",
            1_024,
            200);

        Assert.True(result);
    }

    [Theory]
    [InlineData("text/plain", 0L, 200)]
    [InlineData("text/plain", 524_289L, 200)]
    [InlineData("video/mp4", 100L, 200)]
    [InlineData("text/plain", 100L, 302)]
    public void ShouldInspectRejectsUnboundedOrNonCandidateResponses(
        string? contentType,
        long contentLength,
        int statusCode)
    {
        var result = ManifestResponseSniffer.ShouldInspect(
            new Uri("https://media.example.test/playback"),
            contentType,
            contentLength,
            statusCode);

        Assert.False(result);
    }

    [Fact]
    public void ShouldInspectRejectsMissingDeclaredLength()
    {
        var result = ManifestResponseSniffer.ShouldInspect(
            new Uri("https://media.example.test/playback"),
            "text/plain",
            null,
            200);

        Assert.False(result);
    }

    [Fact]
    public void ShouldInspectRejectsOversizedContentTypeHeader()
    {
        var result = ManifestResponseSniffer.ShouldInspect(
            new Uri("https://media.example.test/playback"),
            new string('x', 257),
            100,
            200);

        Assert.False(result);
    }

    [Fact]
    public void ShouldInspectRejectsKnownBinaryResource()
    {
        var result = ManifestResponseSniffer.ShouldInspect(
            new Uri("https://media.example.test/segment.m4s"),
            "application/octet-stream",
            4_096,
            200);

        Assert.False(result);
    }

    [Fact]
    public void ClassifyPrefixRecognizesHlsAfterUtf8BomAndWhitespace()
    {
        var bytes = Encoding.UTF8.GetPreamble()
            .Concat(Encoding.UTF8.GetBytes(" \r\n#EXTM3U\n#EXT-X-VERSION:7"))
            .ToArray();

        Assert.Equal(SniffedManifestKind.Hls, ManifestResponseSniffer.ClassifyPrefix(bytes));
    }

    [Fact]
    public void ClassifyPrefixRecognizesDashAfterXmlPreamble()
    {
        var bytes = Encoding.UTF8.GetBytes(
            "<?xml version=\"1.0\"?>\n<!-- manifest -->\n<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\">");

        Assert.Equal(SniffedManifestKind.Dash, ManifestResponseSniffer.ClassifyPrefix(bytes));
    }

    [Fact]
    public void ClassifyPrefixDoesNotSearchArbitraryResponseText()
    {
        var bytes = Encoding.UTF8.GetBytes("{\"markup\":\"<MPD>\"}");

        Assert.Equal(SniffedManifestKind.None, ManifestResponseSniffer.ClassifyPrefix(bytes));
    }

    [Fact]
    public async Task ClassifyPrefixAsyncNeverReadsPastPrefixLimit()
    {
        var bytes = Enumerable.Repeat((byte)' ', ManifestResponseSniffer.MaximumPrefixBytes + 64).ToArray();
        await using var stream = new MemoryStream(bytes);

        var result = await ManifestResponseSniffer.ClassifyPrefixAsync(stream);

        Assert.Equal(SniffedManifestKind.None, result);
        Assert.Equal(ManifestResponseSniffer.MaximumPrefixBytes, stream.Position);
    }

    [Fact]
    public void TryResolveRedirectTargetNormalizesRelativeHttpTarget()
    {
        var result = ManifestResponseSniffer.TryResolveRedirectTarget(
            new Uri("https://media.example.test/api/start"),
            "../stream/master.m3u8?token=sensitive#fragment",
            out var target);

        Assert.True(result);
        Assert.Equal("https://media.example.test/stream/master.m3u8?token=sensitive", target!.AbsoluteUri);
    }

    [Theory]
    [InlineData("file:///C:/secret.m3u8")]
    [InlineData("https://user:password@media.example.test/master.m3u8")]
    public void TryResolveRedirectTargetRejectsUnsafeTarget(string location)
    {
        var result = ManifestResponseSniffer.TryResolveRedirectTarget(
            new Uri("https://media.example.test/api/start"),
            location,
            out var target);

        Assert.False(result);
        Assert.Null(target);
    }
}
