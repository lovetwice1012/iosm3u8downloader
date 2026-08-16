using System.Net;

namespace HLSDownloader.Core;

public enum BrowserCookieSameSite
{
    None,
    Lax,
    Strict,
    Unknown
}

/// <summary>
/// A browser cookie together with the URIs whose cookie scopes were queried.
/// The original domain form is retained so a host-only cookie cannot be
/// widened into a domain cookie while importing it into <see cref="CookieContainer"/>.
/// </summary>
public sealed record BrowserSessionCookie(
    IReadOnlyList<Uri> CapturedForUris,
    Uri SiteContextUri,
    string Name,
    string Value,
    string Domain,
    bool IsDomainCookie,
    string Path,
    bool IsSecure,
    bool IsHttpOnly,
    BrowserCookieSameSite SameSite,
    DateTimeOffset? Expires = null)
{
    public override string ToString() => $"{nameof(BrowserSessionCookie)} {{ redacted }}";
}

public sealed record BrowserCookieSnapshot(
    IReadOnlyList<Uri> CapturedScopes,
    IReadOnlyList<BrowserSessionCookie> Cookies)
{
    public override string ToString() => $"{nameof(BrowserCookieSnapshot)} {{ redacted }}";
}

internal sealed record BrowserCookieIdentity(
    string Name,
    string Domain,
    string Path,
    bool IsDomainCookie);

public static class BrowserCookieImporter
{
    public static bool TryImport(CookieContainer destination, BrowserSessionCookie source)
    {
        ArgumentNullException.ThrowIfNull(destination);
        ArgumentNullException.ThrowIfNull(source);

        if (!TryCreateIdentity(source, out var identity) || identity is null)
        {
            return false;
        }

        try
        {
            var cookie = source.IsDomainCookie
                ? new Cookie(source.Name, source.Value, source.Path, "." + identity.Domain)
                : new Cookie(source.Name, source.Value, source.Path);
            cookie.Secure = source.IsSecure;
            cookie.HttpOnly = source.IsHttpOnly;
            if (source.Expires is { } expires)
            {
                cookie.Expires = expires.UtcDateTime;
            }

            if (source.IsDomainCookie)
            {
                destination.Add(cookie);
            }
            else
            {
                // The Uri overload creates an implicit-domain cookie. Unlike assigning
                // Cookie.Domain, it remains bound to the exact host and is not sent to
                // child or sibling hosts.
                destination.Add(source.CapturedForUris[0], cookie);
            }

            return true;
        }
        catch (CookieException)
        {
            // Browser-profile data is optional. Never include the cookie value in errors.
            return false;
        }
    }

    internal static bool TryCreateIdentity(
        BrowserSessionCookie source,
        out BrowserCookieIdentity? identity)
    {
        identity = null;
        if (source.CapturedForUris.Count is < 1 or > 8
            || !IsSafeHttpScope(source.SiteContextUri)
            || string.IsNullOrWhiteSpace(source.Name)
            || source.Name.Length > 256
            || source.Value.Length > 4096
            || source.Domain.Length is < 1 or > 255
            || source.Path.Length is < 1 or > 2048
            || !source.Path.StartsWith("/", StringComparison.Ordinal)
            || source.Name.Any(IsUnsafeCookieCharacter)
            || source.Value.Any(character => character is '\r' or '\n' or '\0')
            || source.SameSite == BrowserCookieSameSite.Unknown
            || source.SameSite == BrowserCookieSameSite.None && !source.IsSecure
            || source.Expires is { } expires && expires <= DateTimeOffset.UtcNow)
        {
            return false;
        }

        var rawDomain = source.Domain.Trim();
        var hasDomainAttribute = rawDomain.StartsWith(".", StringComparison.Ordinal);
        if (source.IsDomainCookie != hasDomainAttribute
            || rawDomain.Length != source.Domain.Length
            || rawDomain.StartsWith("..", StringComparison.Ordinal)
            || rawDomain.EndsWith(".", StringComparison.Ordinal))
        {
            return false;
        }

        var normalizedDomain = hasDomainAttribute ? rawDomain[1..] : rawDomain;
        if (normalizedDomain.Length == 0
            || normalizedDomain.Any(character => char.IsControl(character) || char.IsWhiteSpace(character)))
        {
            return false;
        }

        try
        {
            normalizedDomain = new System.Globalization.IdnMapping()
                .GetAscii(normalizedDomain)
                .ToLowerInvariant();
        }
        catch (ArgumentException)
        {
            return false;
        }

        foreach (var scope in source.CapturedForUris)
        {
            if (!IsSafeHttpScope(scope)
                || source.IsSecure && !scope.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            var capturedHost = scope.IdnHost;
            var domainMatches = source.IsDomainCookie
                ? capturedHost.Equals(normalizedDomain, StringComparison.OrdinalIgnoreCase)
                  || capturedHost.EndsWith("." + normalizedDomain, StringComparison.OrdinalIgnoreCase)
                : capturedHost.Equals(normalizedDomain, StringComparison.OrdinalIgnoreCase);
            if (!domainMatches)
            {
                return false;
            }

            // HttpClient has no browser request context or public-suffix list. For
            // Lax/Strict, exact-host is always safe. A declared Domain cookie may
            // also cross sibling hosts only when both are inside that declared
            // cookie domain. Host-only sibling-site cases remain fail-closed.
            if (source.SameSite is BrowserCookieSameSite.Lax or BrowserCookieSameSite.Strict
                && (!scope.Scheme.Equals(source.SiteContextUri.Scheme, StringComparison.OrdinalIgnoreCase)
                    || !(scope.IdnHost.Equals(source.SiteContextUri.IdnHost, StringComparison.OrdinalIgnoreCase)
                         || source.IsDomainCookie
                         && (source.SiteContextUri.IdnHost.Equals(
                                 normalizedDomain,
                                 StringComparison.OrdinalIgnoreCase)
                             || source.SiteContextUri.IdnHost.EndsWith(
                                 "." + normalizedDomain,
                                 StringComparison.OrdinalIgnoreCase)))))
            {
                return false;
            }
        }

        identity = new BrowserCookieIdentity(
            source.Name,
            normalizedDomain,
            source.Path,
            source.IsDomainCookie);
        return true;
    }

    internal static bool TryExpire(CookieContainer destination, BrowserCookieIdentity identity)
    {
        try
        {
            var expired = identity.IsDomainCookie
                ? new Cookie(identity.Name, string.Empty, identity.Path, "." + identity.Domain)
                : new Cookie(identity.Name, string.Empty, identity.Path);
            expired.Expired = true;
            if (identity.IsDomainCookie)
            {
                destination.Add(expired);
            }
            else
            {
                destination.Add(new UriBuilder(Uri.UriSchemeHttps, identity.Domain).Uri, expired);
            }

            return true;
        }
        catch (Exception exception) when (exception is CookieException or UriFormatException)
        {
            return false;
        }
    }

    private static bool IsSafeHttpScope(Uri scope)
        => scope.IsAbsoluteUri
           && (scope.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
               || scope.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
           && string.IsNullOrEmpty(scope.UserInfo);

    private static bool IsUnsafeCookieCharacter(char character)
        => char.IsControl(character) || character is '(' or ')' or '<' or '>' or '@' or ',' or ';' or ':'
            or '\\' or '"' or '/' or '[' or ']' or '?' or '=' or '{' or '}' or ' ' or '\t';
}

/// <summary>
/// Replaces browser-cookie observations without retaining cookie values in its index.
/// Every previously imported browser identity is expired before the new snapshot is applied.
/// </summary>
public sealed class BrowserCookieSnapshotSynchronizer
{
    private readonly object _gate = new();
    private readonly HashSet<BrowserCookieIdentity> _importedIdentities = [];

    public void Replace(CookieContainer destination, BrowserCookieSnapshot? snapshot)
    {
        ArgumentNullException.ThrowIfNull(destination);

        lock (_gate)
        {
            foreach (var identity in _importedIdentities)
            {
                _ = BrowserCookieImporter.TryExpire(destination, identity);
            }

            _importedIdentities.Clear();
            if (snapshot is null
                || snapshot.CapturedScopes.Count is < 1 or > 8
                || snapshot.Cookies.Count > 128)
            {
                return;
            }

            var scopeKeys = new HashSet<string>(StringComparer.Ordinal);
            foreach (var scope in snapshot.CapturedScopes)
            {
                if (!TryGetScopeKey(scope, out var key) || key is null)
                {
                    return;
                }

                scopeKeys.Add(key);
            }

            foreach (var source in snapshot.Cookies)
            {
                if (!BrowserCookieImporter.TryCreateIdentity(source, out var identity)
                    || identity is null
                    || source.CapturedForUris.Any(scope =>
                        !TryGetScopeKey(scope, out var key) || key is null || !scopeKeys.Contains(key))
                    || !BrowserCookieImporter.TryImport(destination, source))
                {
                    continue;
                }

                _importedIdentities.Add(identity);
            }
        }
    }

    private static bool TryGetScopeKey(Uri scope, out string? key)
    {
        key = null;
        if (!scope.IsAbsoluteUri
            || !(scope.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                 || scope.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            || !string.IsNullOrEmpty(scope.UserInfo))
        {
            return false;
        }

        key = $"{scope.Scheme.ToLowerInvariant()}://{scope.IdnHost.ToLowerInvariant()}:{scope.Port}{scope.AbsolutePath}";
        return true;
    }
}
