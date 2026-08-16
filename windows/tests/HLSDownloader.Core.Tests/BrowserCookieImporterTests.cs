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
