using System.Net;
using System.Net.Sockets;

namespace HLSDownloader.Core;

public static class UriUtilities
{
    public static bool IsHttp(Uri? uri) => uri is { IsAbsoluteUri: true } &&
        (uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
         uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase));

    public static bool IsSecureHttp(Uri? uri) => uri is { IsAbsoluteUri: true } &&
        uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
        string.IsNullOrEmpty(uri.UserInfo);

    public static bool IsSameOrigin(Uri left, Uri right) =>
        left.Scheme.Equals(right.Scheme, StringComparison.OrdinalIgnoreCase) &&
        left.IdnHost.Equals(right.IdnHost, StringComparison.OrdinalIgnoreCase) &&
        EffectivePort(left) == EffectivePort(right);

    public static bool IsHttpsDowngrade(Uri source, Uri target) =>
        source.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) &&
        !target.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase);

    public static bool IsPublicAddress(IPAddress address)
    {
        if (IPAddress.IsLoopback(address)) return false;
        if (address.AddressFamily == AddressFamily.InterNetwork)
        {
            var b = address.GetAddressBytes();
            return !(b[0] == 0 || b[0] == 10 || b[0] == 127 ||
                     (b[0] == 100 && b[1] is >= 64 and <= 127) ||
                     (b[0] == 169 && b[1] == 254) ||
                     (b[0] == 172 && b[1] is >= 16 and <= 31) ||
                     (b[0] == 192 && b[1] == 0 && b[2] == 0) ||
                     (b[0] == 192 && b[1] == 0 && b[2] == 2) ||
                     (b[0] == 192 && b[1] == 168) ||
                     (b[0] == 192 && b[1] == 88 && b[2] == 99) ||
                     (b[0] == 198 && b[1] is 18 or 19) ||
                     (b[0] == 198 && b[1] == 51 && b[2] == 100) ||
                     (b[0] == 203 && b[1] == 0 && b[2] == 113) ||
                     b[0] >= 224);
        }

        if (address.AddressFamily == AddressFamily.InterNetworkV6)
        {
            if (address.IsIPv4MappedToIPv6) return IsPublicAddress(address.MapToIPv4());
            if (address.Equals(IPAddress.IPv6Any) || address.Equals(IPAddress.IPv6None) ||
                address.IsIPv6LinkLocal || address.IsIPv6Multicast || address.IsIPv6SiteLocal)
            {
                return false;
            }
            var b = address.GetAddressBytes();
            // Only global-unicast 2000::/3 is eligible. Documentation space is
            // excluded within it; transition/local address families stay blocked.
            return (b[0] & 0xe0) == 0x20 &&
                   !(b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8);
        }

        return false;
    }

    public static async ValueTask<bool> IsPublicHttpTargetAsync(
        Uri? uri,
        CancellationToken cancellationToken = default)
    {
        if (!IsHttp(uri) || !string.IsNullOrEmpty(uri!.UserInfo) || string.IsNullOrWhiteSpace(uri.IdnHost))
        {
            return false;
        }

        if (IPAddress.TryParse(uri.IdnHost, out var literal)) return IsPublicAddress(literal);
        if (uri.IdnHost.Equals("localhost", StringComparison.OrdinalIgnoreCase) ||
            uri.IdnHost.EndsWith(".localhost", StringComparison.OrdinalIgnoreCase)) return false;

        try
        {
            var addresses = await Dns.GetHostAddressesAsync(uri.IdnHost, cancellationToken).ConfigureAwait(false);
            return addresses.Length > 0 && addresses.All(IsPublicAddress);
        }
        catch (SocketException)
        {
            return false;
        }
    }

    public static Uri Resolve(Uri baseUri, string raw)
    {
        var decoded = System.Net.WebUtility.HtmlDecode(raw.Trim())
            .Replace("\\/", "/", StringComparison.Ordinal)
            .Replace("\\u0026", "&", StringComparison.OrdinalIgnoreCase)
            .Replace("\\x26", "&", StringComparison.OrdinalIgnoreCase);
        if (!Uri.TryCreate(baseUri, decoded, out var result) || !IsHttp(result) ||
            !string.IsNullOrEmpty(result.UserInfo))
        {
            throw new CoreException("Invalid or unsupported media URI.");
        }
        return result;
    }

    private static int EffectivePort(Uri uri) => uri.IsDefaultPort
        ? uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ? 443 : 80
        : uri.Port;
}
