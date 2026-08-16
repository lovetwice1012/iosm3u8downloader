using System.Net;

namespace HLSDownloader.Core.Tests;

public sealed class BrowserCookieImporterTests
{
    [Fact]
    public void CookieDiagnosticRepresentationIsRedacted()
    {
        var source = CreateCookie(
            new Uri("https://page.example.test/watch?auth=query-marker"),
            "page.example.test",
            isDomainCookie: false);

        Assert.Equal("BrowserSessionCookie { redacted }", source.ToString());
    }

    [Fact]
    public void HostOnlyCookieRemainsBoundToCapturedHost()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://page.example.test/watch"),
            "page.example.test",
            isDomainCookie: false);

        Assert.True(BrowserCookieImporter.TryImport(cookies, source));
        Assert.True(ContainsCookie(cookies, new Uri("https://page.example.test/next")));
        Assert.False(ContainsCookie(cookies, new Uri("https://child.page.example.test/next")));
        Assert.False(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
    }

    [Fact]
    public void DomainCookieMayReachDeclaredDomainAndItsSubdomains()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            ".example.test",
            isDomainCookie: true);

        Assert.True(BrowserCookieImporter.TryImport(cookies, source));
        Assert.True(ContainsCookie(cookies, new Uri("https://example.test/next")));
        Assert.True(ContainsCookie(cookies, new Uri("https://cdn.example.test/next")));
        Assert.False(ContainsCookie(cookies, new Uri("https://notexample.test/next")));
    }

    [Fact]
    public void HostOnlyCookieForAnotherCapturedHostIsRejected()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            "page.example.test",
            isDomainCookie: false);

        Assert.False(BrowserCookieImporter.TryImport(cookies, source));
        Assert.False(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
        Assert.False(ContainsCookie(cookies, new Uri("https://page.example.test/next")));
    }

    [Theory]
    [InlineData(".example.test", false)]
    [InlineData("example.test", true)]
    [InlineData(".example.test", true)]
    public void CookieCannotWidenScopeUsingInconsistentOrUnrelatedDomain(
        string domain,
        bool isDomainCookie)
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://evil-example.test/watch"),
            domain,
            isDomainCookie);

        Assert.False(BrowserCookieImporter.TryImport(cookies, source));
        Assert.False(ContainsCookie(cookies, new Uri("https://example.test/next")));
    }

    [Theory]
    [InlineData(BrowserCookieSameSite.Lax)]
    [InlineData(BrowserCookieSameSite.Strict)]
    public void ContextBoundCookieIsRejectedForCrossHostCandidate(BrowserCookieSameSite sameSite)
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            "media.example.test",
            isDomainCookie: false,
            siteContextUri: new Uri("https://page.example.test/watch"),
            sameSite: sameSite);

        Assert.False(BrowserCookieImporter.TryImport(cookies, source));
        Assert.False(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
    }

    [Theory]
    [InlineData(BrowserCookieSameSite.Lax)]
    [InlineData(BrowserCookieSameSite.Strict)]
    public void ContextBoundCookieIsAllowedForExactPageHost(BrowserCookieSameSite sameSite)
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://page.example.test/master.m3u8"),
            "page.example.test",
            isDomainCookie: false,
            sameSite: sameSite);

        Assert.True(BrowserCookieImporter.TryImport(cookies, source));
        Assert.True(ContainsCookie(cookies, new Uri("https://page.example.test/next")));
    }

    [Theory]
    [InlineData(BrowserCookieSameSite.Lax)]
    [InlineData(BrowserCookieSameSite.Strict)]
    public void ContextBoundDomainCookieMayCrossSiblingHostsInsideDeclaredDomain(
        BrowserCookieSameSite sameSite)
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            ".example.test",
            isDomainCookie: true,
            siteContextUri: new Uri("https://page.example.test/watch"),
            sameSite: sameSite);

        Assert.True(BrowserCookieImporter.TryImport(cookies, source));
        Assert.True(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
    }

    [Fact]
    public void ContextBoundDomainCookieRejectsLookalikeSiteContext()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            ".example.test",
            isDomainCookie: true,
            siteContextUri: new Uri("https://evil-example.test/watch"),
            sameSite: BrowserCookieSameSite.Lax);

        Assert.False(BrowserCookieImporter.TryImport(cookies, source));
        Assert.False(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
    }

    [Fact]
    public void SameSiteNoneCookieRequiresSecureTransport()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("http://page.example.test/master.m3u8"),
            "page.example.test",
            isDomainCookie: false,
            siteContextUri: new Uri("http://page.example.test/watch"),
            isSecure: false);

        Assert.False(BrowserCookieImporter.TryImport(cookies, source));
        Assert.False(ContainsCookie(cookies, new Uri("http://page.example.test/next")));
    }

    [Fact]
    public void SecureSameSiteNoneCookieMayBeImportedForCrossHostCandidate()
    {
        var cookies = new CookieContainer();
        var source = CreateCookie(
            new Uri("https://media.example.test/master.m3u8"),
            "media.example.test",
            isDomainCookie: false,
            siteContextUri: new Uri("https://page.example.test/watch"));

        Assert.True(BrowserCookieImporter.TryImport(cookies, source));
        Assert.True(ContainsCookie(cookies, new Uri("https://media.example.test/next")));
    }

    [Fact]
    public void SnapshotExpiresCookieMissingFromSameScope()
    {
        var cookies = new CookieContainer();
        var synchronizer = new BrowserCookieSnapshotSynchronizer();
        var scope = new Uri("https://page.example.test/watch");
        synchronizer.Replace(cookies, new BrowserCookieSnapshot(
            [scope],
            [CreateCookie(scope, "page.example.test", isDomainCookie: false)]));
        Assert.True(ContainsCookie(cookies, new Uri("https://page.example.test/next")));

        synchronizer.Replace(cookies, new BrowserCookieSnapshot([scope], []));

        Assert.False(ContainsCookie(cookies, new Uri("https://page.example.test/next")));
    }

    [Fact]
    public void ReplacementSnapshotExpiresCookieFromPreviousCandidate()
    {
        var cookies = new CookieContainer();
        var synchronizer = new BrowserCookieSnapshotSynchronizer();
        var pageScope = new Uri("https://page.example.test/watch");
        synchronizer.Replace(cookies, new BrowserCookieSnapshot(
            [pageScope],
            [CreateCookie(pageScope, "page.example.test", isDomainCookie: false)]));

        synchronizer.Replace(cookies, new BrowserCookieSnapshot(
            [new Uri("https://media.example.test/master.m3u8")],
            []));

        Assert.False(ContainsCookie(cookies, new Uri("https://page.example.test/next")));
    }

    [Fact]
    public void FreshCandidateContainerDoesNotInheritImportedOrResponseCookies()
    {
        var scope = new Uri("https://page.example.test/watch");
        var firstJobCookies = new CookieContainer();
        new BrowserCookieSnapshotSynchronizer().Replace(
            firstJobCookies,
            new BrowserCookieSnapshot(
                [scope],
                [CreateCookie(scope, "page.example.test", isDomainCookie: false)]));
        firstJobCookies.SetCookies(scope, "server_session=response-only; Path=/; Secure; HttpOnly");

        var secondJobCookies = new CookieContainer();
        new BrowserCookieSnapshotSynchronizer().Replace(secondJobCookies, null);

        Assert.Equal(2, firstJobCookies.GetCookies(scope).Count);
        Assert.Empty(secondJobCookies.GetCookies(scope).Cast<Cookie>());
    }

    [Fact]
    public void AnalysisSnapshotKeepsApplicableAttributesAndNarrowsDomainToCandidateHost()
    {
        var source = new CookieContainer();
        var candidateUri = new Uri("https://media.example.test/video/master.m3u8");
        var expiry = DateTimeOffset.UtcNow.AddHours(1);
        source.Add(new Cookie("analysis_auth", "opaque", "/video", ".example.test")
        {
            Secure = true,
            HttpOnly = true,
            Expires = expiry.UtcDateTime
        });
        source.Add(new Cookie("wrong_path", "opaque", "/account", ".example.test")
        {
            Secure = true
        });

        BrowserCookieSnapshot snapshot = BrowserCookieImporter.CaptureHostOnlySnapshot(
            source,
            [candidateUri]);
        var destination = new CookieContainer();
        new BrowserCookieSnapshotSynchronizer().Replace(destination, snapshot);

        Cookie imported = Assert.Single(destination.GetCookies(
            new Uri("https://media.example.test/video/segment.m4s")).Cast<Cookie>());
        Assert.Equal("analysis_auth", imported.Name);
        Assert.Equal("/video", imported.Path);
        Assert.True(imported.Secure);
        Assert.True(imported.HttpOnly);
        Assert.InRange(imported.Expires.ToUniversalTime(), expiry.UtcDateTime.AddSeconds(-1), expiry.UtcDateTime.AddSeconds(1));
        Assert.Empty(destination.GetCookies(new Uri("https://other.example.test/video/segment.m4s")).Cast<Cookie>());
        Assert.Empty(destination.GetCookies(new Uri("https://media.example.test/account")).Cast<Cookie>());
        Assert.Empty(destination.GetCookies(new Uri("http://media.example.test/video/segment.m4s")).Cast<Cookie>());
    }

    [Fact]
    public void AnalysisSnapshotContainsOnlyCookiesApplicableToCapturedCandidateScope()
    {
        var source = new CookieContainer();
        source.SetCookies(
            new Uri("https://media.example.test/"),
            "root_cookie=one; Path=/; Secure; HttpOnly");
        source.SetCookies(
            new Uri("https://media.example.test/account"),
            "account_cookie=two; Path=/account; Secure; HttpOnly");

        BrowserCookieSnapshot snapshot = BrowserCookieImporter.CaptureHostOnlySnapshot(
            source,
            [new Uri("https://media.example.test/video/master.m3u8")]);

        BrowserSessionCookie cookie = Assert.Single(snapshot.Cookies);
        Assert.Equal("root_cookie", cookie.Name);
        Assert.Equal("media.example.test", cookie.Domain);
        Assert.False(cookie.IsDomainCookie);
        Assert.Equal("BrowserCookieSnapshot { redacted }", snapshot.ToString());
    }

    private static BrowserSessionCookie CreateCookie(
        Uri capturedForUri,
        string domain,
        bool isDomainCookie,
        Uri? siteContextUri = null,
        BrowserCookieSameSite sameSite = BrowserCookieSameSite.None,
        bool isSecure = true)
        => new(
            [capturedForUri],
            siteContextUri ?? capturedForUri,
            "scope_test",
            "opaque-test-value",
            domain,
            isDomainCookie,
            "/",
            IsSecure: isSecure,
            IsHttpOnly: true,
            SameSite: sameSite);

    private static bool ContainsCookie(CookieContainer cookies, Uri uri)
        => cookies.GetCookies(uri).Cast<Cookie>().Any(cookie => cookie.Name == "scope_test");
}
