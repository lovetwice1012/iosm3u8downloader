namespace HLSDownloader.Core.Tests;

public sealed class MediaSourceResolverTests
{
    [Fact]
    public async Task SniffsDirectHlsWithoutExtension()
    {
        var requested = new Uri("https://example.com/play?id=1");
        var effective = new Uri("https://cdn.example.com/session/stream");
        var resolver = new MediaSourceResolver(new SingleFetcher(
            new("#EXTM3U\n#EXTINF:1,\none.ts", effective, "application/octet-stream")));
        var result = await resolver.ResolveAsync(requested);
        Assert.True(result.WasDirectManifest);
        Assert.Equal(effective, result.Candidates.Single().Uri);
        Assert.Equal(MediaCandidateKind.Hls, result.Candidates.Single().Kind);
    }

    [Fact]
    public async Task SniffsDirectAllowedDashByContentType()
    {
        var uri = new Uri("https://widevine.sprink.cloud/play?id=1");
        var resolver = new MediaSourceResolver(new SingleFetcher(
            new("<?xml version='1.0'?><MPD></MPD>", uri, "application/dash+xml")));
        var result = await resolver.ResolveAsync(uri);
        Assert.Equal(MediaCandidateKind.WidevineDash, result.Candidates.Single().Kind);
    }

    [Fact]
    public async Task RejectsDirectDashOnOtherHost()
    {
        var uri = new Uri("https://example.com/play");
        var resolver = new MediaSourceResolver(new SingleFetcher(
            new("<MPD xmlns='urn:mpeg:dash:schema:mpd:2011'></MPD>", uri, "application/dash+xml")));
        await Assert.ThrowsAsync<CoreException>(() => resolver.ResolveAsync(uri));
    }

    [Fact]
    public async Task FallsBackToHtmlExtraction()
    {
        var uri = new Uri("https://example.com/page");
        var resolver = new MediaSourceResolver(new SingleFetcher(
            new("<video src='stream.m3u8'></video>", uri, "text/html")));
        var result = await resolver.ResolveAsync(uri);
        Assert.False(result.WasDirectManifest);
        Assert.Equal(new Uri("https://example.com/stream.m3u8"), result.Candidates.Single().Uri);
    }

    [Fact]
    public async Task PrefixProbeDetectsLargeProgressiveMp4WithoutFetchingItAsText()
    {
        var requested = new Uri("https://example.com/download?id=1");
        var effective = new Uri("https://cdn.example.com/video/final");
        byte[] prefix = new byte[32];
        "ftyp"u8.CopyTo(prefix.AsSpan(4));
        var fetcher = new PrefixFetcher(
            new(prefix, requested, effective, System.Net.HttpStatusCode.PartialContent, "application/octet-stream"));

        var result = await new MediaSourceResolver(fetcher).ResolveAsync(requested);

        var candidate = Assert.Single(result.Candidates);
        Assert.Equal(MediaCandidateKind.Progressive, candidate.Kind);
        Assert.Equal(requested, candidate.RequestedUri);
        Assert.Equal(effective, candidate.Uri);
        Assert.Equal(0, fetcher.TextFetchCount);
    }

    [Fact]
    public async Task ProgressiveExtensionDoesNotOverrideNonMediaMagic()
    {
        var uri = new Uri("https://example.com/not-really.mp4");
        var html = new TextFetchResult("<video src='real.webm'></video>", uri, "text/html");
        var fetcher = new PrefixFetcher(
            new("<html>"u8.ToArray(), uri, uri, System.Net.HttpStatusCode.OK, "text/html"),
            html);

        var result = await new MediaSourceResolver(fetcher).ResolveAsync(uri);

        var candidate = Assert.Single(result.Candidates);
        Assert.Equal(MediaCandidateKind.Progressive, candidate.Kind);
        Assert.Equal(new Uri("https://example.com/real.webm"), candidate.Uri);
        Assert.Equal(1, fetcher.TextFetchCount);
    }

    private sealed class SingleFetcher(TextFetchResult result) : ITextResourceFetcher
    {
        public Task<TextFetchResult> FetchTextAsync(Uri uri, Uri? referer = null, CancellationToken cancellationToken = default) =>
            Task.FromResult(result);
    }

    private sealed class PrefixFetcher(
        HttpPrefixResource prefix,
        TextFetchResult? text = null) : ITextResourceFetcher, IHttpPrefixProbe
    {
        public int TextFetchCount { get; private set; }

        public Task<HttpPrefixResource> ProbePrefixAsync(
            Uri uri,
            Uri? referer = null,
            int maximumPrefixBytes = 64 * 1024,
            CancellationToken cancellationToken = default)
            => Task.FromResult(prefix);

        public Task<TextFetchResult> FetchTextAsync(
            Uri uri,
            Uri? referer = null,
            CancellationToken cancellationToken = default)
        {
            TextFetchCount++;
            return Task.FromResult(text ?? throw new InvalidOperationException("Text fetch was not expected."));
        }
    }
}
