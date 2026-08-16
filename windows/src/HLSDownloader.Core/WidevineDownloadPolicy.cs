namespace HLSDownloader.Core;

public static class WidevineDownloadPolicy
{
    private static readonly HashSet<string> DownloadableHosts =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "widevine.sprink.cloud"
        };

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
