namespace HLSDownloader.Core;

public static class WidevineDownloadPolicy
{
    private static readonly IReadOnlyList<string> DownloadableHostValues =
        Array.AsReadOnly(["widevine.sprink.cloud"]);

    private static readonly HashSet<string> DownloadableHosts =
        new(DownloadableHostValues, StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The exact hosts used by non-.NET enforcement layers. The allowlist is
    /// defined here once; callers must not duplicate host literals.
    /// </summary>
    public static IReadOnlyList<string> DownloadableWidevineHosts => DownloadableHostValues;

    /// <summary>
    /// The only Widevine admission check. Callers must check both the requested
    /// manifest URI and its final URI after redirects.
    /// </summary>
    public static bool IsDownloadableWidevineDomain(Uri? uri)
    {
        if (uri is null || !uri.IsAbsoluteUri ||
            !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(uri.UserInfo))
        {
            return false;
        }

        return DownloadableHosts.Contains(uri.IdnHost);
    }
}

/// <summary>
/// Applies the shared exact-host Widevine gate before the ordinary public
/// network policy. BoundedHttpClient calls this policy before every request,
/// including each redirect hop, so a rejected redirect is never transmitted.
/// </summary>
public sealed class DownloadableWidevineUriPolicy : IOutboundUriPolicy
{
    private readonly IOutboundUriPolicy _networkPolicy;

    public DownloadableWidevineUriPolicy(IOutboundUriPolicy? networkPolicy = null)
    {
        _networkPolicy = networkPolicy ?? new PublicNetworkUriPolicy();
    }

    public async ValueTask<bool> IsAllowedAsync(
        Uri uri,
        CancellationToken cancellationToken = default)
    {
        if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(uri))
        {
            return false;
        }

        return await _networkPolicy.IsAllowedAsync(uri, cancellationToken).ConfigureAwait(false);
    }
}
