using System.Net;
using System.Net.Http.Headers;
using HLSDownloader.Core;

namespace HLSDownloader.Media;

/// <summary>
/// Bounded raw-binary Widevine transport. Redirects are disabled so a signed
/// challenge and browser cookies cannot be forwarded to a different endpoint.
/// </summary>
public sealed class WidevineRawLicenseTransport : IWidevineRawLicenseTransport, IDisposable
{
    public const int MaximumResponseBytes = 16 * 1024 * 1024;
    private readonly HttpClient _client;
    private readonly IOutboundUriPolicy _networkPolicy;
    private bool _disposed;

    public WidevineRawLicenseTransport(
        CookieContainer? cookies = null,
        IOutboundUriPolicy? networkPolicy = null)
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            UseCookies = true,
            CookieContainer = cookies ?? new CookieContainer(),
            MaxConnectionsPerServer = 2
        };
        _client = new HttpClient(handler, disposeHandler: true)
        {
            Timeout = Timeout.InfiniteTimeSpan
        };
        _networkPolicy = networkPolicy ?? new PublicNetworkUriPolicy();
    }

    internal WidevineRawLicenseTransport(HttpMessageHandler handler, IOutboundUriPolicy? networkPolicy = null)
    {
        _client = new HttpClient(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };
        _networkPolicy = networkPolicy ?? new PublicNetworkUriPolicy();
    }

    public async Task<byte[]> SendAsync(
        Uri licenseUri,
        ReadOnlyMemory<byte> challenge,
        Uri? referer,
        Func<Uri, bool> isPermittedUri,
        CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        ArgumentNullException.ThrowIfNull(licenseUri);
        ArgumentNullException.ThrowIfNull(isPermittedUri);
        if (challenge.IsEmpty || challenge.Length > 4 * 1024 * 1024)
            throw new WidevineL3ClientException("The Widevine license challenge size is invalid.");
        if (!isPermittedUri(licenseUri) ||
            !await _networkPolicy.IsAllowedAsync(licenseUri, cancellationToken).ConfigureAwait(false))
            throw new WidevineL3ClientException("The Widevine license endpoint is not a permitted public HTTPS target.");

        using var request = new HttpRequestMessage(HttpMethod.Post, licenseUri);
        request.Headers.UserAgent.ParseAdd("HLSDownloader-Windows/1.0");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/octet-stream"));
        if (referer is not null && isPermittedUri(referer)) request.Headers.Referrer = referer;
        request.Content = new ReadOnlyMemoryContent(challenge);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        using HttpResponseMessage response = await _client.SendAsync(
            request,
            HttpCompletionOption.ResponseHeadersRead,
            timeout.Token).ConfigureAwait(false);
        if ((int)response.StatusCode is >= 300 and < 400)
            throw new WidevineL3ClientException("Widevine license redirects are blocked.");
        if (!response.IsSuccessStatusCode)
            throw new HttpRequestException(
                $"Widevine license HTTP {(int)response.StatusCode} from {licenseUri.IdnHost}.",
                null,
                response.StatusCode);
        if (response.Content.Headers.ContentLength > MaximumResponseBytes)
            throw new WidevineL3ClientException("The Widevine license response exceeds the size limit.");
        await using Stream source = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
        using var destination = new MemoryStream(Math.Min(MaximumResponseBytes, 64 * 1024));
        byte[] buffer = new byte[64 * 1024];
        while (true)
        {
            int count = await source.ReadAsync(buffer, timeout.Token).ConfigureAwait(false);
            if (count == 0) break;
            if (destination.Length + count > MaximumResponseBytes)
                throw new WidevineL3ClientException("The Widevine license response exceeds the size limit.");
            await destination.WriteAsync(buffer.AsMemory(0, count), timeout.Token).ConfigureAwait(false);
        }
        if (destination.Length == 0) throw new WidevineL3ClientException("The Widevine license response is empty.");
        return destination.ToArray();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _client.Dispose();
    }
}
