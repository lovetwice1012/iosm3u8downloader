using System.Net;
using HLSDownloader.Core;

namespace HLSDownloader.Media.Tests;

public sealed class WidevineRawLicenseTransportTests
{
    [Fact]
    public async Task DisallowedHostIsRejectedBeforeChallengeIsSent()
    {
        var handler = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent([1])
        });
        using var transport = new WidevineRawLicenseTransport(handler, new AllowAllNetworkPolicy());

        await Assert.ThrowsAsync<WidevineL3ClientException>(() => transport.SendAsync(
            new Uri("https://example.com/license"),
            new byte[] { 1, 2, 3 },
            null,
            WidevineDownloadPolicy.IsDownloadableWidevineDomain));
        Assert.Equal(0, handler.CallCount);
    }

    [Fact]
    public async Task LicenseRedirectIsNeverFollowed()
    {
        var handler = new RecordingHandler(_ => new HttpResponseMessage(HttpStatusCode.Redirect)
        {
            Headers = { Location = new Uri("https://widevine.sprink.cloud/other") }
        });
        using var transport = new WidevineRawLicenseTransport(handler, new AllowAllNetworkPolicy());

        await Assert.ThrowsAsync<WidevineL3ClientException>(() => transport.SendAsync(
            new Uri("https://widevine.sprink.cloud/license"),
            new byte[] { 1, 2, 3 },
            new Uri("https://widevine.sprink.cloud/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain));
        Assert.Equal(1, handler.CallCount);
    }

    private sealed class AllowAllNetworkPolicy : IOutboundUriPolicy
    {
        public ValueTask<bool> IsAllowedAsync(Uri uri, CancellationToken cancellationToken = default) => ValueTask.FromResult(true);
    }

    private sealed class RecordingHandler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        public int CallCount { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            CallCount++;
            return Task.FromResult(response(request));
        }
    }
}
