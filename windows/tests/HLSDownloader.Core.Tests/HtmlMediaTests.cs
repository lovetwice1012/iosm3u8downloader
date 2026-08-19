namespace HLSDownloader.Core.Tests;

public sealed class HtmlMediaTests
{
    [Fact]
    public void ExtractsVideoSourceDataScriptFramesAndPosters()
    {
        var html = """
            <html><head>
              <base href="https://example.com/assets/">
              <meta property="og:title" content="Example Player">
              <meta property="og:image" content="thumb.jpg">
            </head><body>
              <video poster="poster.jpg" data-hls-src="main.m3u8"><source src="audio.m3u8" type="audio/mpegurl"></video>
              <div data-mpd="https://widevine.sprink.cloud/v/manifest.mpd"></div>
              <script>const url = "\/fallback\/stream.m3u8?token=abc";</script>
              <iframe data-src="frame/player.html" title="Frame"></iframe>
              <iframe srcdoc="&lt;video src='nested.m3u8'&gt;&lt;/video&gt;"></iframe>
            </body></html>
            """;
        var result = HtmlMediaExtractor.Extract(html, new Uri("https://example.com/page/index.html"));
        Assert.Equal(new Uri("https://example.com/assets/"), result.BaseUri);
        Assert.Equal("Example Player", result.Title);
        Assert.Equal(4, result.Media.Count);
        Assert.Contains(result.Media, x => x.Uri == new Uri("https://example.com/assets/main.m3u8") &&
                                           x.Origin == MediaCandidateOrigin.Video &&
                                           x.PosterUri == new Uri("https://example.com/assets/poster.jpg"));
        Assert.Contains(result.Media, x => x.Kind == MediaCandidateKind.WidevineDash);
        Assert.Equal(2, result.Frames.Count);
        Assert.Contains(result.Frames, x => x.Uri == new Uri("https://example.com/assets/frame/player.html"));
        Assert.Contains(result.Frames, x => x.SourceDocument is not null &&
                                            x.SourceDocument.Contains("nested.m3u8", StringComparison.Ordinal));
    }

    [Fact]
    public void ExtractsProgressiveMediaAndIgnoresUnsafeSchemes()
    {
        var html = "<video src='movie.mp4'><source src='javascript:alert(1)'><source src='audio' type='audio/ogg'></video>";
        var result = HtmlMediaExtractor.Extract(html, new Uri("https://example.com/"));
        Assert.Equal(2, result.Media.Count);
        Assert.All(result.Media, media => Assert.Equal(MediaCandidateKind.Progressive, media.Kind));
        Assert.Contains(result.Media, media => media.Uri == new Uri("https://example.com/movie.mp4"));
        Assert.Contains(result.Media, media => media.Uri == new Uri("https://example.com/audio"));
    }

    [Fact]
    public async Task DiscoveryRecursesOnlyWithinRootOriginAndHonorsBounds()
    {
        var root = new Uri("https://example.com/index.html");
        var fetcher = new DictionaryFetcher(new Dictionary<Uri, string>
        {
            [new("https://example.com/a.html")] = "<video src='/a.m3u8'></video><iframe src='/deep.html'></iframe>",
            [new("https://example.com/deep.html")] = "<video src='/deep.m3u8'></video>"
        });
        var discovery = new HtmlMediaDiscovery(fetcher, new(MaximumDepth: 1, MaximumDocuments: 4, MaximumResults: 10));
        var html = """
            <video src="root.m3u8"></video>
            <iframe src="/a.html"></iframe>
            <iframe src="https://other.example/x.html"></iframe>
            <iframe srcdoc="<source src='/srcdoc.m3u8' type='application/vnd.apple.mpegurl'>"></iframe>
            """;
        var results = await discovery.DiscoverAsync(html, root);
        Assert.Contains(results, x => x.Uri == new Uri("https://example.com/root.m3u8") && x.IframeDepth == 0);
        Assert.Contains(results, x => x.Uri == new Uri("https://example.com/a.m3u8") && x.IframeDepth == 1);
        Assert.Contains(results, x => x.Uri == new Uri("https://example.com/srcdoc.m3u8") && x.IframeDepth == 1);
        Assert.DoesNotContain(results, x => x.Uri.AbsolutePath == "/deep.m3u8");
        Assert.DoesNotContain(fetcher.Requests, x => x.Host == "other.example");
    }

    [Fact]
    public async Task DiscoveryRejectsNonAllowlistedWidevineButKeepsClearHls()
    {
        var html = """
            <video src="https://example.com/clear.m3u8"></video>
            <source src="https://example.com/blocked.mpd" type="application/dash+xml">
            <source src="https://widevine.sprink.cloud/allowed.mpd" type="application/dash+xml">
            """;
        var discovery = new HtmlMediaDiscovery(new DictionaryFetcher(new Dictionary<Uri, string>()));
        var result = await discovery.DiscoverAsync(html, new Uri("https://example.com/page"));
        Assert.Equal(2, result.Count);
        Assert.Contains(result, x => x.Kind == MediaCandidateKind.Hls);
        Assert.Contains(result, x => x.Uri.Host == "widevine.sprink.cloud");
    }

    private sealed class DictionaryFetcher(IReadOnlyDictionary<Uri, string> pages) : ITextResourceFetcher
    {
        public List<Uri> Requests { get; } = [];
        public Task<TextFetchResult> FetchTextAsync(Uri uri, Uri? referer = null, CancellationToken cancellationToken = default)
        {
            Requests.Add(uri);
            if (!pages.TryGetValue(uri, out var text)) throw new HttpRequestException("missing");
            return Task.FromResult(new TextFetchResult(text, uri, "text/html"));
        }
    }
}
