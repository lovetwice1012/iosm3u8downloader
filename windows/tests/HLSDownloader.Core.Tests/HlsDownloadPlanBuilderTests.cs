namespace HLSDownloader.Core.Tests;

public sealed class HlsDownloadPlanBuilderTests
{
    [Fact]
    public async Task SelectsHighestBandwidthAndDefaultAudio()
    {
        var root = new Uri("https://example.com/master.m3u8");
        var fetcher = new MapFetcher(new Dictionary<Uri, string>
        {
            [root] = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"ja\",DEFAULT=YES,URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=10,AUDIO=\"a\"\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=20,AUDIO=\"a\"\nhigh.m3u8",
            [new("https://example.com/high.m3u8")] = Media("high.ts"),
            [new("https://example.com/audio.m3u8")] = Media("audio.aac")
        });
        var candidate = new MediaCandidate(root, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, root);
        var plan = await new HlsDownloadPlanBuilder(fetcher).BuildAsync(candidate);
        Assert.EndsWith("high.ts", plan.MainPlaylist!.Segments.Single().Uri.AbsoluteUri, StringComparison.Ordinal);
        Assert.EndsWith("audio.aac", plan.AudioPlaylist!.Segments.Single().Uri.AbsoluteUri, StringComparison.Ordinal);
    }

    [Fact]
    public async Task UriLessDefaultAudioKeepsTheVariantsInBandAudio()
    {
        var root = new Uri("https://example.com/master.m3u8");
        var fetcher = new MapFetcher(new Dictionary<Uri, string>
        {
            [root] = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"main\",DEFAULT=YES,AUTOSELECT=YES\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"alternate\",DEFAULT=NO,AUTOSELECT=YES,URI=\"alternate.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=20,AUDIO=\"a\"\nmain.m3u8",
            [new("https://example.com/main.m3u8")] = Media("main.ts")
        });

        var plan = await new HlsDownloadPlanBuilder(fetcher)
            .BuildAsync(new(root, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, root));

        Assert.Null(plan.AudioPlaylist);
    }

    [Fact]
    public async Task AudioRenditionSelectionUsesDefaultThenAutoselectThenDeclarationOrder()
    {
        var root = new Uri("https://example.com/master.m3u8");
        var fetcher = new MapFetcher(new Dictionary<Uri, string>
        {
            [root] = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"first\",DEFAULT=NO,AUTOSELECT=YES,URI=\"first.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"second\",DEFAULT=NO,AUTOSELECT=YES,URI=\"second.m3u8\"\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"manual\",DEFAULT=NO,AUTOSELECT=NO,URI=\"manual.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=20,AUDIO=\"a\"\nmain.m3u8",
            [new("https://example.com/main.m3u8")] = Media("main.ts"),
            [new("https://example.com/first.m3u8")] = Media("first.aac")
        });

        var plan = await new HlsDownloadPlanBuilder(fetcher)
            .BuildAsync(new(root, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, root));

        Assert.EndsWith("first.aac", plan.AudioPlaylist!.Segments.Single().Uri.AbsoluteUri, StringComparison.Ordinal);
    }

    [Fact]
    public async Task ClearHlsIsNotRestrictedByWidevineDomain()
    {
        var uri = new Uri("https://example.com/media.m3u8");
        var plan = await new HlsDownloadPlanBuilder(new MapFetcher(new Dictionary<Uri, string> { [uri] = Media("one.ts") }))
            .BuildAsync(new(uri, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, uri));
        Assert.False(plan.MainPlaylist!.UsesSampleAes);
    }

    [Fact]
    public async Task SampleAesRequiresRequestedAndEffectiveExactHost()
    {
        const string sample = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n#EXTINF:1,\none.ts";
        var blocked = new Uri("https://example.com/media.m3u8");
        await Assert.ThrowsAsync<PlaylistException>(() =>
            new HlsDownloadPlanBuilder(new MapFetcher(new Dictionary<Uri, string> { [blocked] = sample }))
                .BuildAsync(new(blocked, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, blocked)));

        var allowed = new Uri("https://widevine.sprink.cloud/media.m3u8");
        var plan = await new HlsDownloadPlanBuilder(new MapFetcher(new Dictionary<Uri, string> { [allowed] = sample }))
            .BuildAsync(new(allowed, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, allowed));
        Assert.True(plan.MainPlaylist!.UsesSampleAes);
    }

    [Fact]
    public async Task SampleAesRejectsARequestRedirectedFromAnotherHost()
    {
        const string sample = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n#EXTINF:1,\none.ts";
        var effective = new Uri("https://widevine.sprink.cloud/media.m3u8");
        var candidate = new MediaCandidate(effective, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct,
            effective, RequestedUri: new Uri("https://example.com/redirect"));
        await Assert.ThrowsAsync<PlaylistException>(() =>
            new HlsDownloadPlanBuilder(new MapFetcher(new Dictionary<Uri, string> { [effective] = sample }))
                .BuildAsync(candidate));
    }

    [Fact]
    public async Task RejectsMixedSampleAesAndClearAudioRenditions()
    {
        var root = new Uri("https://widevine.sprink.cloud/master.m3u8");
        var fetcher = new MapFetcher(new Dictionary<Uri, string>
        {
            [root] = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"ja\",URI=\"audio.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=20,AUDIO=\"a\"\nmain.m3u8",
            [new("https://widevine.sprink.cloud/main.m3u8")] = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n#EXTINF:1,\none.ts",
            [new("https://widevine.sprink.cloud/audio.m3u8")] = Media("audio.aac")
        });
        await Assert.ThrowsAsync<PlaylistException>(() => new HlsDownloadPlanBuilder(fetcher)
            .BuildAsync(new(root, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, root)));
    }

    private static string Media(string segment) => $"#EXTM3U\n#EXTINF:1,\n{segment}\n#EXT-X-ENDLIST";

    private sealed class MapFetcher(IReadOnlyDictionary<Uri, string> values) : ITextResourceFetcher
    {
        public Task<TextFetchResult> FetchTextAsync(Uri uri, Uri? referer = null, CancellationToken cancellationToken = default) =>
            Task.FromResult(new TextFetchResult(values[uri], uri, "application/vnd.apple.mpegurl"));
    }
}
