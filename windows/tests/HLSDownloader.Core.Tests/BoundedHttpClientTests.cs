using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace HLSDownloader.Core.Tests;

public sealed class BoundedHttpClientTests
{
    [Fact]
    public void CookiePersistenceCanBeDisabledForStatelessWorkers()
    {
        var options = new BoundedHttpOptions(UseCookies: false);
        Assert.False(options.UseCookies);
        Assert.True(new BoundedHttpOptions().UseCookies);
    }

    [Fact]
    public async Task FollowsBoundedRedirectAndReturnsEffectiveUri()
    {
        var handler = new StubHandler(request => request.RequestUri!.Host == "a.example"
            ? Response(HttpStatusCode.Redirect, location: "https://b.example/final")
            : Response(HttpStatusCode.OK, "hello"));
        using var client = new BoundedHttpClient(handler, new(MaximumResponseBytes: 1024), new AlwaysAllowPolicy());
        var result = await client.FetchAsync(new Uri("https://a.example/start"), new Uri("https://a.example/page"));
        Assert.Equal("hello", Encoding.UTF8.GetString(result.Data));
        Assert.Equal(new Uri("https://b.example/final"), result.EffectiveUri);
        Assert.Equal("https://a.example/", handler.Referrers.Last());
    }

    [Fact]
    public async Task BlocksHttpsDowngrade()
    {
        var handler = new StubHandler(_ => Response(HttpStatusCode.Redirect, location: "http://public.example/final"));
        using var client = new BoundedHttpClient(handler, uriPolicy: new AlwaysAllowPolicy());
        await Assert.ThrowsAsync<UnsafeNetworkTargetException>(() =>
            client.FetchAsync(new Uri("https://public.example/start")));
    }

    [Fact]
    public async Task RejectsOversizedStreamingBody()
    {
        var handler = new StubHandler(_ => Response(HttpStatusCode.OK, new string('a', 2048), includeLength: false));
        using var client = new BoundedHttpClient(handler, new(MaximumResponseBytes: 1024), new AlwaysAllowPolicy());
        await Assert.ThrowsAsync<CoreException>(() => client.FetchAsync(new Uri("https://public.example/data")));
    }

    [Fact]
    public async Task AppliesByteRangeHeader()
    {
        var handler = new StubHandler(_ => Response(
            HttpStatusCode.PartialContent, "1234", contentRange: new ContentRangeHeaderValue(10, 13)));
        using var client = new BoundedHttpClient(handler, uriPolicy: new AlwaysAllowPolicy());
        await client.FetchAsync(new Uri("https://public.example/data"), rangeOffset: 10, rangeLength: 4);
        Assert.Equal("bytes=10-13", handler.Ranges.Single());
    }

    [Fact]
    public async Task SlicesBodyWhenServerIgnoresRange()
    {
        var handler = new StubHandler(_ => Response(HttpStatusCode.OK, "0123456789"));
        using var client = new BoundedHttpClient(handler, uriPolicy: new AlwaysAllowPolicy());
        var result = await client.FetchAsync(new Uri("https://public.example/data"), rangeOffset: 3, rangeLength: 4);
        Assert.Equal("3456", Encoding.UTF8.GetString(result.Data));
    }

    [Fact]
    public async Task CrossOriginRefererIsOriginOnly()
    {
        var handler = new StubHandler(_ => Response(HttpStatusCode.OK, "ok"));
        using var client = new BoundedHttpClient(handler, uriPolicy: new AlwaysAllowPolicy());
        await client.FetchAsync(new Uri("https://cdn.example/data"), new Uri("https://page.example/private?q=secret#fragment"));
        Assert.Equal("https://page.example/", handler.Referrers.Single());
    }

    [Fact]
    public async Task PolicyRunsForRedirectDestination()
    {
        var policy = new SelectivePolicy(uri => uri.Host != "private.example");
        var handler = new StubHandler(_ => Response(HttpStatusCode.Redirect, location: "https://private.example/final"));
        using var client = new BoundedHttpClient(handler, uriPolicy: policy);
        await Assert.ThrowsAsync<UnsafeNetworkTargetException>(() => client.FetchAsync(new Uri("https://public.example/start")));
        Assert.Contains(policy.Seen, x => x.Host == "private.example");
    }

    [Fact]
    public async Task WidevinePolicyRejectsCrossHostRedirectBeforeSecondRequest()
    {
        var handler = new StubHandler(_ => Response(
            HttpStatusCode.Redirect,
            location: "https://example.com/stolen.mpd"));
        using var client = new BoundedHttpClient(
            handler,
            uriPolicy: new DownloadableWidevineUriPolicy(new AlwaysAllowPolicy()));

        await Assert.ThrowsAsync<UnsafeNetworkTargetException>(() =>
            client.FetchAsync(new Uri("https://widevine.sprink.cloud/video/manifest.mpd")));

        Assert.Single(handler.Referrers);
    }

    private static HttpResponseMessage Response(
        HttpStatusCode status, string body = "", string? location = null, bool includeLength = true,
        ContentRangeHeaderValue? contentRange = null)
    {
        var response = new HttpResponseMessage(status);
        if (location is not null) response.Headers.Location = new Uri(location);
        var bytes = Encoding.UTF8.GetBytes(body);
        var content = new ByteArrayContent(bytes);
        if (!includeLength) content.Headers.ContentLength = null;
        if (contentRange is not null) content.Headers.ContentRange = contentRange;
        response.Content = content;
        return response;
    }

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) : HttpMessageHandler
    {
        public List<string?> Referrers { get; } = [];
        public List<string?> Ranges { get; } = [];
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Referrers.Add(request.Headers.Referrer?.AbsoluteUri);
            Ranges.Add(request.Headers.Range?.ToString());
            return Task.FromResult(responder(request));
        }
    }

    private sealed class AlwaysAllowPolicy : IOutboundUriPolicy
    {
        public ValueTask<bool> IsAllowedAsync(Uri uri, CancellationToken cancellationToken = default) => ValueTask.FromResult(true);
    }

    private sealed class SelectivePolicy(Func<Uri, bool> predicate) : IOutboundUriPolicy
    {
        public List<Uri> Seen { get; } = [];
        public ValueTask<bool> IsAllowedAsync(Uri uri, CancellationToken cancellationToken = default)
        {
            Seen.Add(uri);
            return ValueTask.FromResult(predicate(uri));
        }
    }
}
