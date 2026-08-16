using System.Net;

namespace HLSDownloader.Core.Tests;

public sealed class PolicyAndUriTests
{
    [Theory]
    [InlineData("https://widevine.sprink.cloud/video/manifest.mpd", true)]
    [InlineData("HTTPS://WIDEVINE.SPRINK.CLOUD/video/manifest.mpd", true)]
    [InlineData("http://widevine.sprink.cloud/video/manifest.mpd", false)]
    [InlineData("https://user@widevine.sprink.cloud/video/manifest.mpd", false)]
    [InlineData("https://www.widevine.sprink.cloud/video/manifest.mpd", false)]
    [InlineData("https://widevine.sprink.cloud.example.com/video/manifest.mpd", false)]
    [InlineData("https://evil-widevine.sprink.cloud/video/manifest.mpd", false)]
    public void WidevinePolicyUsesSecureExactHost(string raw, bool expected) =>
        Assert.Equal(expected, WidevineDownloadPolicy.IsDownloadableWidevineDomain(new Uri(raw)));

    [Theory]
    [InlineData("8.8.8.8", true)]
    [InlineData("127.0.0.1", false)]
    [InlineData("10.0.0.1", false)]
    [InlineData("172.16.1.1", false)]
    [InlineData("192.168.1.1", false)]
    [InlineData("169.254.1.1", false)]
    [InlineData("100.64.0.1", false)]
    [InlineData("224.0.0.1", false)]
    [InlineData("203.0.113.1", false)]
    [InlineData("2001:4860:4860::8888", true)]
    [InlineData("::1", false)]
    [InlineData("fe80::1", false)]
    [InlineData("fd00::1", false)]
    [InlineData("2001:db8::1", false)]
    [InlineData("::ffff:127.0.0.1", false)]
    [InlineData("::ffff:8.8.8.8", true)]
    [InlineData("64:ff9b::7f00:1", false)]
    public void PublicAddressClassificationIsFailClosed(string raw, bool expected) =>
        Assert.Equal(expected, UriUtilities.IsPublicAddress(IPAddress.Parse(raw)));

    [Fact]
    public async Task LocalhostNameIsBlockedWithoutDns() =>
        Assert.False(await UriUtilities.IsPublicHttpTargetAsync(new Uri("https://foo.localhost/video.m3u8")));

    [Fact]
    public void SameOriginNormalizesDefaultPorts()
    {
        Assert.True(UriUtilities.IsSameOrigin(new Uri("https://example.com/a"), new Uri("https://EXAMPLE.com:443/b")));
        Assert.False(UriUtilities.IsSameOrigin(new Uri("https://example.com/a"), new Uri("http://example.com/b")));
    }

    [Fact]
    public void WidevineCandidateRequiresRequestedAndEffectiveUrisToBeAllowed()
    {
        var allowed = new Uri("https://widevine.sprink.cloud/video/manifest.mpd");
        var candidate = new MediaCandidate(allowed, MediaCandidateKind.WidevineDash,
            MediaCandidateOrigin.Direct, allowed, RequestedUri: new Uri("https://example.com/redirect"));
        Assert.False(candidate.CanDownload);
        Assert.True((candidate with { RequestedUri = allowed }).CanDownload);
    }

    [Fact]
    public async Task WidevineOutboundPolicyChecksExactHostBeforeNetworkPolicy()
    {
        var inner = new RecordingOutboundPolicy();
        var policy = new DownloadableWidevineUriPolicy(inner);

        Assert.False(await policy.IsAllowedAsync(new Uri("https://example.com/video/manifest.mpd")));
        Assert.Equal(0, inner.CallCount);

        Assert.True(await policy.IsAllowedAsync(
            new Uri("https://widevine.sprink.cloud/video/manifest.mpd")));
        Assert.Equal(1, inner.CallCount);
    }

    private sealed class RecordingOutboundPolicy : IOutboundUriPolicy
    {
        public int CallCount { get; private set; }

        public ValueTask<bool> IsAllowedAsync(
            Uri uri,
            CancellationToken cancellationToken = default)
        {
            CallCount++;
            return ValueTask.FromResult(true);
        }
    }
}
