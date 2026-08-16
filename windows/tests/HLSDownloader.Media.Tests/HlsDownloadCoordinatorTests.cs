using System.Net;
using HLSDownloader.Core;

namespace HLSDownloader.Media.Tests;

public sealed class HlsDownloadCoordinatorTests
{
    [Fact]
    public async Task DownloadsMainAndExternalAudioThenPassesLocalPlaylistsToComposer()
    {
        using var scope = new TestFileScope();
        Uri page = new("https://media.example/watch");
        Uri mainUri = new("https://media.example/video/segment.ts");
        Uri audioUri = new("https://media.example/audio/segment.aac");
        var candidate = new MediaCandidate(new Uri("https://media.example/master.m3u8"), MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, page);
        var main = new HlsMediaPlaylist(
            new Uri("https://media.example/video/index.m3u8"),
            [new HlsSegment(0, 0, 2, mainUri, null, null, null, false)],
            true,
            page);
        var audio = new HlsMediaPlaylist(
            new Uri("https://media.example/audio/index.m3u8"),
            [new HlsSegment(0, 0, 2, audioUri, null, null, null, false)],
            true,
            page);
        var composer = new InspectingComposer(scope.PathFor("finished.mp4"));
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(new DownloadPlan(candidate, main, audio, HLSDownloader.Core.MediaOutputFormat.Mp4)),
            new StubDownloader(new Dictionary<Uri, byte[]> { [mainUri] = [1, 2], [audioUri] = [3, 4] }),
            composer,
            options: new HlsMediaDownloadOptions(TemporaryRoot: scope.PathFor("jobs")));

        MediaComposeResult result = await coordinator.DownloadAsync(candidate, scope.PathFor("output"));

        Assert.Equal(scope.PathFor("finished.mp4"), result.OutputPath);
        Assert.NotNull(composer.Request);
        Assert.NotNull(composer.MainPlaylistText);
        Assert.Contains("segment-000000.ts", composer.MainPlaylistText);
        Assert.NotNull(composer.AudioPlaylistText);
        Assert.Contains("segment-000000.aac", composer.AudioPlaylistText);
        Assert.False(Directory.Exists(Path.GetDirectoryName(composer.Request!.InputPath)));
    }

    [Fact]
    public async Task StagesAes128KeyAndRedactsItsHexValue()
    {
        using var scope = new TestFileScope();
        Uri page = new("https://widevine.sprink.cloud/watch");
        Uri playlistUri = new("https://widevine.sprink.cloud/video/index.m3u8");
        Uri segmentUri = new("https://cdn.example/segment.ts");
        Uri keyUri = new("https://keys.example/key.bin");
        byte[] key = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        var encryption = new HlsEncryption(HlsEncryptionMethod.SampleAes, keyUri, new byte[16]);
        var main = new HlsMediaPlaylist(
            playlistUri,
            [new HlsSegment(0, 0, 2, segmentUri, null, encryption, null, false)],
            true,
            page);
        var candidate = new MediaCandidate(playlistUri, MediaCandidateKind.Hls, MediaCandidateOrigin.Direct, page);
        var composer = new InspectingComposer(scope.PathFor("finished.mp4"));
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(new DownloadPlan(candidate, main, null, HLSDownloader.Core.MediaOutputFormat.Mp4)),
            new StubDownloader(new Dictionary<Uri, byte[]> { [segmentUri] = [1, 2], [keyUri] = key }),
            composer,
            options: new HlsMediaDownloadOptions(TemporaryRoot: scope.PathFor("jobs")));

        await coordinator.DownloadAsync(candidate, scope.PathFor("output"));

        Assert.Contains("METHOD=SAMPLE-AES", composer.MainPlaylistText);
        Assert.Contains(Convert.ToHexString(key), composer.Request!.RedactedValues!);
        Assert.DoesNotContain(keyUri.AbsoluteUri, composer.MainPlaylistText);
    }

    [Fact]
    public async Task SampleAesRejectsDisallowedRequestedRedirectProvenanceBeforeDownload()
    {
        using var scope = new TestFileScope();
        Uri allowed = new("https://widevine.sprink.cloud/video/index.m3u8");
        Uri segment = new("https://cdn.example/segment.ts");
        Uri key = new("https://cdn.example/key.bin");
        var encryption = new HlsEncryption(HlsEncryptionMethod.SampleAes, key, null);
        var playlist = new HlsMediaPlaylist(
            allowed,
            [new HlsSegment(0, 0, 1, segment, null, encryption, null, false)],
            true);
        var candidate = new MediaCandidate(
            allowed,
            MediaCandidateKind.Hls,
            MediaCandidateOrigin.Direct,
            allowed,
            RequestedUri: new Uri("https://evil.example/redirect.m3u8"));
        var composer = new InspectingComposer(scope.PathFor("never.mp4"));
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(new DownloadPlan(candidate, playlist, null, HLSDownloader.Core.MediaOutputFormat.Mp4)),
            new StubDownloader(new Dictionary<Uri, byte[]>()),
            composer,
            options: new HlsMediaDownloadOptions(TemporaryRoot: scope.PathFor("jobs")));

        await Assert.ThrowsAsync<InvalidDataException>(() => coordinator.DownloadAsync(candidate, scope.PathFor("output")));
        Assert.Null(composer.Request);
    }

    [Fact]
    public async Task WidevineIsExplicitlyUnavailableWithoutProvider()
    {
        using var scope = new TestFileScope();
        Uri manifest = new("https://widevine.sprink.cloud/video/manifest.mpd");
        var candidate = new MediaCandidate(manifest, MediaCandidateKind.WidevineDash, MediaCandidateOrigin.Direct, manifest);
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(null),
            new StubDownloader(new Dictionary<Uri, byte[]>()),
            new InspectingComposer(scope.PathFor("unused.mp4")));

        await Assert.ThrowsAsync<WidevineL3ProviderUnavailableException>(() =>
            coordinator.DownloadAsync(candidate, scope.PathFor("output")));
    }

    [Fact]
    public async Task DisallowedRequestedWidevineHostNeverReachesConfiguredProvider()
    {
        using var scope = new TestFileScope();
        Uri effective = new("https://widevine.sprink.cloud/video/manifest.mpd");
        var candidate = new MediaCandidate(
            effective,
            MediaCandidateKind.WidevineDash,
            MediaCandidateOrigin.Direct,
            effective,
            RequestedUri: new Uri("https://evil.example/redirect.mpd"));
        var provider = new CapturingWidevineProvider(scope.PathFor("widevine.mp4"));
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(null),
            new StubDownloader(new Dictionary<Uri, byte[]>()),
            new InspectingComposer(scope.PathFor("unused.mp4")),
            provider);

        await Assert.ThrowsAsync<WidevineL3ProviderUnavailableException>(() =>
            coordinator.DownloadAsync(candidate, scope.PathFor("output")));
        Assert.Null(provider.Request);
    }

    [Fact]
    public async Task ConfiguredProviderReceivesCentralRedirectPolicy()
    {
        using var scope = new TestFileScope();
        Uri manifest = new("https://widevine.sprink.cloud/video/manifest.mpd");
        var candidate = new MediaCandidate(manifest, MediaCandidateKind.WidevineDash, MediaCandidateOrigin.Direct, manifest);
        var provider = new CapturingWidevineProvider(scope.PathFor("widevine.mp4"));
        var coordinator = new HlsDownloadCoordinator(
            new StubPlanBuilder(null),
            new StubDownloader(new Dictionary<Uri, byte[]>()),
            new InspectingComposer(scope.PathFor("unused.mp4")),
            provider);

        await coordinator.DownloadAsync(candidate, scope.PathFor("output"));

        Assert.NotNull(provider.Request);
        Assert.True(provider.Request!.IsPermittedManifestUri(manifest));
        Assert.False(provider.Request.IsPermittedManifestUri(new Uri("https://www.widevine.sprink.cloud/video/manifest.mpd")));
        Assert.False(provider.Request.IsPermittedManifestUri(new Uri("https://widevine.sprink.cloud.example.com/video/manifest.mpd")));
    }

    private sealed class StubPlanBuilder(DownloadPlan? plan) : IDownloadPlanBuilder
    {
        public Task<DownloadPlan> BuildAsync(MediaCandidate candidate, CancellationToken cancellationToken = default) =>
            Task.FromResult(plan ?? throw new InvalidOperationException("The plan builder should not be called."));
    }

    private sealed class StubDownloader(IReadOnlyDictionary<Uri, byte[]> responses) : IResourceDownloader
    {
        public Task<HttpResource> FetchAsync(
            Uri uri,
            Uri? referer = null,
            long? rangeOffset = null,
            long? rangeLength = null,
            CancellationToken cancellationToken = default)
        {
            byte[] data = responses[uri];
            if (rangeOffset is not null && rangeLength is not null)
            {
                data = data.AsSpan((int)rangeOffset.Value, (int)rangeLength.Value).ToArray();
            }

            return Task.FromResult(new HttpResource(data, uri, uri, HttpStatusCode.OK, null));
        }
    }

    private sealed class InspectingComposer(string resultPath) : IMediaComposer
    {
        public MediaComposeRequest? Request { get; private set; }
        public string? MainPlaylistText { get; private set; }
        public string? AudioPlaylistText { get; private set; }

        public async Task<MediaComposeResult> ComposeAsync(MediaComposeRequest request, CancellationToken cancellationToken = default)
        {
            Request = request;
            MainPlaylistText = await File.ReadAllTextAsync(request.InputPath, cancellationToken);
            AudioPlaylistText = request.SecondaryAudioInputPath is null
                ? null
                : await File.ReadAllTextAsync(request.SecondaryAudioInputPath, cancellationToken);
            return new MediaComposeResult(resultPath, MediaOutputFormat.Mp4, new MediaTrackInfo(true, true));
        }
    }

    private sealed class CapturingWidevineProvider(string resultPath) : IWidevineL3MediaProvider
    {
        public bool IsConfigured => true;
        public WidevineL3DownloadRequest? Request { get; private set; }

        public Task<MediaComposeResult> DownloadAndComposeAsync(
            WidevineL3DownloadRequest request,
            CancellationToken cancellationToken = default)
        {
            Request = request;
            return Task.FromResult(new MediaComposeResult(resultPath, MediaOutputFormat.Mp4, new MediaTrackInfo(true, true)));
        }
    }
}
