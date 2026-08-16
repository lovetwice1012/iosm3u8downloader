using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace HLSDownloader.Core;

public interface IOutboundUriPolicy
{
    ValueTask<bool> IsAllowedAsync(Uri uri, CancellationToken cancellationToken = default);
}

public sealed class PublicNetworkUriPolicy : IOutboundUriPolicy
{
    public ValueTask<bool> IsAllowedAsync(Uri uri, CancellationToken cancellationToken = default) =>
        UriUtilities.IsPublicHttpTargetAsync(uri, cancellationToken);
}

public sealed record BoundedHttpOptions(
    int MaximumResponseBytes = 8 * 1024 * 1024,
    int MaximumRedirects = 5,
    TimeSpan? RequestTimeout = null,
    string UserAgent = "HLSDownloader-Windows/1.0")
{
    internal TimeSpan EffectiveTimeout => RequestTimeout ?? TimeSpan.FromSeconds(30);
    internal void Validate()
    {
        if (MaximumResponseBytes is < 1024 or > 256 * 1024 * 1024 || MaximumRedirects is < 0 or > 10 ||
            EffectiveTimeout < TimeSpan.FromSeconds(1) || EffectiveTimeout > TimeSpan.FromMinutes(5))
            throw new ArgumentOutOfRangeException(nameof(BoundedHttpOptions));
    }
}

public sealed record HttpResource(
    byte[] Data,
    Uri RequestedUri,
    Uri EffectiveUri,
    HttpStatusCode StatusCode,
    string? MediaType);

public interface IResourceDownloader
{
    Task<HttpResource> FetchAsync(
        Uri uri,
        Uri? referer = null,
        long? rangeOffset = null,
        long? rangeLength = null,
        CancellationToken cancellationToken = default);
}

public sealed class BoundedHttpClient : IResourceDownloader, ITextResourceFetcher, IDisposable
{
    private readonly HttpClient _client;
    private readonly IOutboundUriPolicy _uriPolicy;
    private readonly BoundedHttpOptions _options;
    private readonly bool _ownsClient;

    public BoundedHttpClient(
        BoundedHttpOptions? options = null,
        IOutboundUriPolicy? uriPolicy = null,
        CookieContainer? cookies = null)
    {
        _options = options ?? new();
        _options.Validate();
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.All,
            UseCookies = true,
            CookieContainer = cookies ?? new CookieContainer(),
            MaxConnectionsPerServer = 6
        };
        _client = new HttpClient(handler, disposeHandler: true);
        _ownsClient = true;
        _uriPolicy = uriPolicy ?? new PublicNetworkUriPolicy();
    }

    public BoundedHttpClient(
        HttpMessageHandler handler,
        BoundedHttpOptions? options = null,
        IOutboundUriPolicy? uriPolicy = null)
    {
        ArgumentNullException.ThrowIfNull(handler);
        _options = options ?? new();
        _options.Validate();
        _client = new HttpClient(handler, disposeHandler: false);
        _ownsClient = true;
        _uriPolicy = uriPolicy ?? new PublicNetworkUriPolicy();
    }

    public async Task<HttpResource> FetchAsync(
        Uri uri,
        Uri? referer = null,
        long? rangeOffset = null,
        long? rangeLength = null,
        CancellationToken cancellationToken = default)
    {
        if (rangeOffset is < 0 || rangeLength is <= 0 || (rangeOffset is null) != (rangeLength is null))
            throw new ArgumentOutOfRangeException(nameof(rangeOffset));
        var requested = uri;
        var current = uri;
        for (var redirects = 0; ; redirects++)
        {
            await EnsureAllowedAsync(current, cancellationToken).ConfigureAwait(false);
            using var request = new HttpRequestMessage(HttpMethod.Get, current);
            request.Headers.UserAgent.ParseAdd(_options.UserAgent);
            request.Headers.AcceptLanguage.ParseAdd("ja, en-US;q=0.8, en;q=0.6");
            if (SanitizeReferer(referer, current) is { } safeReferer)
                request.Headers.Referrer = safeReferer;
            if (rangeOffset is { } offset && rangeLength is { } length)
                request.Headers.Range = new RangeHeaderValue(offset, checked(offset + length - 1));

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(_options.EffectiveTimeout);
            using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
            if (IsRedirect(response.StatusCode))
            {
                if (redirects >= _options.MaximumRedirects || response.Headers.Location is null)
                    throw new CoreException("The redirect limit was exceeded or Location was missing.");
                var next = response.Headers.Location.IsAbsoluteUri
                    ? response.Headers.Location
                    : new Uri(current, response.Headers.Location);
                if (UriUtilities.IsHttpsDowngrade(current, next))
                    throw new UnsafeNetworkTargetException("HTTPS to HTTP redirects are blocked.");
                await EnsureAllowedAsync(next, cancellationToken).ConfigureAwait(false);
                // Referrer is reduced to the origin when crossing origins.
                referer = UriUtilities.IsSameOrigin(current, next) ? referer : Origin(current);
                current = next;
                continue;
            }
            if (!response.IsSuccessStatusCode)
                throw new HttpRequestException($"HTTP {(int)response.StatusCode} from {current.IdnHost}.", null, response.StatusCode);
            if (response.Content.Headers.ContentLength > _options.MaximumResponseBytes)
                throw new CoreException("The HTTP response exceeds the configured byte limit.");
            var bytes = await ReadBoundedAsync(response.Content, _options.MaximumResponseBytes, timeout.Token).ConfigureAwait(false);
            if (rangeOffset is { } requestedOffset && rangeLength is { } requestedLength)
            {
                if (response.StatusCode == HttpStatusCode.OK)
                {
                    var end = checked(requestedOffset + requestedLength);
                    if (end > bytes.LongLength || end > int.MaxValue || requestedOffset > int.MaxValue)
                        throw new CoreException("The server ignored a byte range that cannot be sliced safely.");
                    bytes = bytes.AsSpan((int)requestedOffset, (int)requestedLength).ToArray();
                }
                else if (response.StatusCode == HttpStatusCode.PartialContent)
                {
                    var contentRange = response.Content.Headers.ContentRange;
                    if (contentRange?.From != requestedOffset ||
                        contentRange.To != checked(requestedOffset + requestedLength - 1) ||
                        bytes.LongLength != requestedLength)
                        throw new CoreException("The partial response does not match the requested byte range.");
                }
                else throw new CoreException("The server returned an invalid status for a byte range.");
            }
            return new(bytes, requested, current, response.StatusCode, response.Content.Headers.ContentType?.MediaType);
        }
    }

    public async Task<TextFetchResult> FetchTextAsync(
        Uri uri,
        Uri? referer = null,
        CancellationToken cancellationToken = default)
    {
        var result = await FetchAsync(uri, referer, cancellationToken: cancellationToken).ConfigureAwait(false);
        var encoding = Encoding.UTF8;
        var charset = result.MediaType; // Content-Type parameters are intentionally not trusted by the DTO.
        _ = charset;
        return new(encoding.GetString(result.Data), result.EffectiveUri, result.MediaType);
    }

    public void Dispose()
    {
        if (_ownsClient) _client.Dispose();
    }

    private async ValueTask EnsureAllowedAsync(Uri uri, CancellationToken cancellationToken)
    {
        if (!await _uriPolicy.IsAllowedAsync(uri, cancellationToken).ConfigureAwait(false))
            throw new UnsafeNetworkTargetException("The URI targets a blocked or non-public network address.");
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, int maximumBytes, CancellationToken ct)
    {
        await using var source = await content.ReadAsStreamAsync(ct).ConfigureAwait(false);
        using var destination = new MemoryStream(Math.Min(maximumBytes, 64 * 1024));
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var count = await source.ReadAsync(buffer, ct).ConfigureAwait(false);
            if (count == 0) break;
            if (destination.Length + count > maximumBytes)
                throw new CoreException("The HTTP response exceeds the configured byte limit.");
            await destination.WriteAsync(buffer.AsMemory(0, count), ct).ConfigureAwait(false);
        }
        return destination.ToArray();
    }

    private static bool IsRedirect(HttpStatusCode status) => status is
        HttpStatusCode.Moved or HttpStatusCode.Redirect or HttpStatusCode.RedirectMethod or
        HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect;

    private static Uri Origin(Uri uri) => new UriBuilder(uri.Scheme, uri.IdnHost, uri.IsDefaultPort ? -1 : uri.Port, "/").Uri;

    private static Uri? SanitizeReferer(Uri? referer, Uri target)
    {
        if (referer is null || !UriUtilities.IsHttp(referer) || !string.IsNullOrEmpty(referer.UserInfo) ||
            UriUtilities.IsHttpsDowngrade(referer, target)) return null;
        var builder = new UriBuilder(referer) { UserName = string.Empty, Password = string.Empty, Fragment = string.Empty };
        if (!UriUtilities.IsSameOrigin(referer, target))
        {
            builder.Path = "/";
            builder.Query = string.Empty;
        }
        return builder.Uri;
    }
}
