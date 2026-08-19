using System.Text.Json;
using System.Diagnostics;
using HLSDownloader.WebProbe;

namespace HLSDownloader.Core.Tests;

public sealed class BrowserGeneratedProbeTests
{
    [Fact]
    public void BrowserCaptureAlwaysPreservesFixedFreeSpaceReserve()
    {
        long reserve = BrowserCaptureStoragePolicy.RequiredFreeSpaceReserveBytes;

        Assert.False(BrowserCaptureStoragePolicy.CanCapture(100L * 1024 * 1024, 50L * 1024 * 1024));
        Assert.False(BrowserCaptureStoragePolicy.CanCapture(reserve + 10_000, 10_000));
        Assert.True(BrowserCaptureStoragePolicy.CanCapture(reserve + 10_001, 10_000));
    }

    [Fact]
    public void ParsesBoundedBrowserBlobWithoutExposingBlobUrl()
    {
        var session = new ProbeSession();
        string json = Payload(
            session,
            "browser-blob",
            "blob-12",
            12_345,
            "webm",
            "video/webm");

        Assert.True(ProbePayloadParser.TryParse(json, session, out var signal));
        Assert.NotNull(signal);
        Assert.Equal(ProbeSignalKind.BrowserBlob, signal.Kind);
        Assert.Equal(new Uri("https://example.com/player"), signal.Url);
        Assert.Equal("blob-12", signal.BrowserObjectId);
        Assert.Equal(12_345, signal.ByteLength);
        Assert.Equal(ProbeMediaContainer.WebM, signal.Container);
        Assert.DoesNotContain("blob:", json, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("ProbeSignal(<redacted>)", signal.ToString());
        Assert.DoesNotContain("example.com", signal.ToString(), StringComparison.OrdinalIgnoreCase);
        var debuggerDisplay = Assert.Single(
            typeof(ProbeSignal).GetCustomAttributes(typeof(DebuggerDisplayAttribute), inherit: false)
                .Cast<DebuggerDisplayAttribute>());
        Assert.Equal("ProbeSignal(<redacted>)", debuggerDisplay.Value);
    }

    [Fact]
    public void RejectsBrowserBlobAboveProcessingLimit()
    {
        var session = new ProbeSession();

        Assert.False(ProbePayloadParser.TryParse(
            Payload(
                session,
                "browser-blob",
                "blob-too-large",
                ProbePayloadParser.MaximumBrowserBlobBytes + 1,
                "mp4",
                "video/mp4"),
            session,
            out _));
        Assert.Equal(20L * 1024 * 1024 * 1024, ProbePayloadParser.MaximumBrowserBlobBytes);
    }

    [Fact]
    public void RoutesIframeBrowserObjectToItsOwningFrameAndRemovesDestroyedFrame()
    {
        var registry = new BrowserObjectRouteRegistry<object>();
        var frame = new object();
        var otherFrame = new object();
        registry.Set("blob-document-a-1", frame);
        registry.Set("blob-document-a-2", frame);
        registry.Set("blob-document-b-1", otherFrame);

        Assert.True(registry.TryGet("blob-document-a-1", out var route));
        Assert.Same(frame, route);
        Assert.Equal(
            ["blob-document-a-1", "blob-document-a-2"],
            registry.RemoveTarget(frame).Order().ToArray());
        Assert.False(registry.TryGet("blob-document-a-1", out _));
        Assert.True(registry.TryGet("blob-document-b-1", out route));
        Assert.Same(otherFrame, route);

        registry.Set("blob-document-b-1", null);
        Assert.False(registry.TryGet("blob-document-b-1", out _));
    }

    [Theory]
    [InlineData("../blob", 100L)]
    [InlineData("blob:12", 100L)]
    [InlineData("blob-12", 0L)]
    [InlineData("blob-12", -1L)]
    public void RejectsInvalidBrowserBlobMetadata(string objectId, long byteLength)
    {
        var session = new ProbeSession();

        Assert.False(ProbePayloadParser.TryParse(
            Payload(session, "browser-blob", objectId, byteLength, "mp4", "video/mp4"),
            session,
            out _));
    }

    [Fact]
    public void ParsesMediaSourceWithoutPretendingItIsCapturableBlob()
    {
        var session = new ProbeSession();

        Assert.True(ProbePayloadParser.TryParse(
            Payload(session, "media-source", "mse-1", null, "mp4", "video/mp4"),
            session,
            out var signal));
        Assert.NotNull(signal);
        Assert.True(signal.IsMediaSource);
        Assert.Null(signal.ByteLength);
    }

    [Theory]
    [InlineData("https://example.com/video.mp4", null)]
    [InlineData("https://example.com/no-extension", "audio/ogg; codecs=opus")]
    [InlineData("https://example.com/movie", "video/webm")]
    [InlineData("https://example.com/audio.m4a", "application/octet-stream")]
    public void ClassifiesSupportedProgressiveMedia(string rawUrl, string? mime)
        => Assert.True(ResourceClassifier.IsProgressiveMedia(new Uri(rawUrl), mime));

    [Theory]
    [InlineData("https://example.com/segment.m4s", "video/mp4")]
    [InlineData("https://example.com/image.png", "image/png")]
    [InlineData("https://example.com/data", "application/octet-stream")]
    public void DoesNotClassifySegmentOrUnrelatedResourceByWeakHint(string rawUrl, string? mime)
        => Assert.False(ResourceClassifier.IsProgressiveMedia(new Uri(rawUrl), mime));

    private static string Payload(
        ProbeSession session,
        string kind,
        string objectId,
        long? byteLength,
        string container,
        string mime)
        => JsonSerializer.Serialize(new
        {
            channel = "hls-downloader-probe",
            version = 1,
            nonce = session.Nonce,
            seq = 1,
            kind,
            url = "https://example.com/player",
            pageUrl = "https://example.com/player",
            source = "createObjectURL",
            objectId,
            byteLength,
            container,
            mime
        });
}
