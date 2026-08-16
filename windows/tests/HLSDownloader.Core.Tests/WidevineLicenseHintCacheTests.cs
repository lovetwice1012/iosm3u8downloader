namespace HLSDownloader.Core.Tests;

public sealed class WidevineLicenseHintCacheTests
{
    private static readonly Uri Manifest = new("https://widevine.sprink.cloud/video/manifest.mpd");
    private static readonly Uri License = new("https://widevine.sprink.cloud/license?session=opaque");
    private static readonly DateTimeOffset CapturedAt = new(2026, 8, 16, 0, 0, 0, TimeSpan.Zero);
    private static readonly BrowserCookieSnapshot Snapshot = new([Manifest, License], []);

    [Fact]
    public void HintTextDoesNotExposeLicenseUriOrCookieScope()
    {
        var hint = new ObservedWidevineLicenseHint(License, Snapshot);

        Assert.Equal("ObservedWidevineLicenseHint(<redacted>)", hint.ToString());
        Assert.DoesNotContain("opaque", $"{hint}", StringComparison.Ordinal);
        Assert.DoesNotContain("/license", string.Concat(hint), StringComparison.Ordinal);
        var debuggerDisplay = Assert.IsType<System.Diagnostics.DebuggerDisplayAttribute>(Assert.Single(
            typeof(ObservedWidevineLicenseHint).GetCustomAttributes(
                typeof(System.Diagnostics.DebuggerDisplayAttribute),
                inherit: false)));
        Assert.Equal("ObservedWidevineLicenseHint(<redacted>)", debuggerDisplay.Value);
    }

    [Fact]
    public void HintIsSingleUseAndRetainsCookieScope()
    {
        var cache = new WidevineLicenseHintCache();

        Assert.True(cache.Remember(Manifest, License, Snapshot, CapturedAt));
        Assert.True(cache.TryTake(
            Manifest,
            CapturedAt.AddMinutes(4),
            out var hint));
        Assert.NotNull(hint);
        Assert.Equal(License, hint.LicenseUri);
        Assert.Same(Snapshot, hint.CookieSnapshot);
        Assert.False(cache.TryTake(
            Manifest,
            CapturedAt.AddMinutes(4),
            out _));
        Assert.Equal(0, cache.Count);
    }

    [Fact]
    public void HintExpiresAtFiveMinutes()
    {
        var cache = new WidevineLicenseHintCache();
        Assert.True(cache.Remember(Manifest, License, Snapshot, CapturedAt));

        Assert.False(cache.TryTake(
            Manifest,
            CapturedAt.AddMinutes(5),
            out _));
        Assert.Equal(0, cache.Count);
    }

    [Theory]
    [InlineData("https://example.com/video/manifest.mpd", "https://widevine.sprink.cloud/license")]
    [InlineData("https://widevine.sprink.cloud/video/manifest.mpd", "http://widevine.sprink.cloud/license")]
    [InlineData("https://widevine.sprink.cloud/video/manifest.mpd", "https://www.widevine.sprink.cloud/license")]
    [InlineData("https://widevine.sprink.cloud/video/manifest.mpd", "https://widevine.sprink.cloud.example.com/license")]
    [InlineData("https://widevine.sprink.cloud/video/manifest.mpd", "https://evil-widevine.sprink.cloud/license")]
    public void HintRejectsAnythingOutsideExactAllowedHttpsHost(
        string manifest,
        string license)
    {
        var cache = new WidevineLicenseHintCache();

        Assert.False(cache.Remember(
            new Uri(manifest),
            new Uri(license),
            Snapshot,
            CapturedAt));
        Assert.Equal(0, cache.Count);
    }

    [Fact]
    public void OldestHintIsEvictedAtCapacity()
    {
        var cache = new WidevineLicenseHintCache(capacity: 1);
        var firstManifest = Manifest;
        var secondManifest = new Uri("https://widevine.sprink.cloud/video/second.mpd");

        Assert.True(cache.Remember(firstManifest, License, Snapshot, CapturedAt));
        Assert.True(cache.Remember(
            secondManifest,
            License,
            Snapshot,
            CapturedAt.AddSeconds(1)));

        Assert.False(cache.TryTake(firstManifest, CapturedAt.AddSeconds(2), out _));
        Assert.True(cache.TryTake(secondManifest, CapturedAt.AddSeconds(2), out _));
    }
}
