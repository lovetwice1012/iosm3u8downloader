namespace HLSDownloader.Media.Tests;

public sealed class FFmpegMediaComposerTests
{
    [Fact]
    public async Task AudioOnlyInputProducesPcm16Wav()
    {
        using var scope = new TestFileScope();
        string input = scope.PathFor("audio.ts");
        await File.WriteAllTextAsync(input, "fixture");
        var runner = new OutputCreatingRunner(MediaOutputFormat.Wav);
        var composer = new FFmpegMediaComposer("ffmpeg", new StubProbe(new MediaTrackInfo(false, true, 48000, 1)), runner);

        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(input, scope.PathFor("output")));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.EndsWith(".wav", result.OutputPath, StringComparison.OrdinalIgnoreCase);
        Assert.True(MediaOutputValidator.IsValidPcm16Wav(result.OutputPath));
        Assert.Contains("pcm_s16le", runner.LastInvocation!.Arguments);
    }

    [Fact]
    public async Task VideoInputProducesMp4WithOptionalAudio()
    {
        using var scope = new TestFileScope();
        string input = scope.PathFor("video.ts");
        await File.WriteAllTextAsync(input, "fixture");
        var runner = new OutputCreatingRunner(MediaOutputFormat.Mp4);
        var composer = new FFmpegMediaComposer("ffmpeg", new StubProbe(new MediaTrackInfo(true, true)), runner);

        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(input, scope.PathFor("output")));

        Assert.Equal(MediaOutputFormat.Mp4, result.OutputFormat);
        Assert.True(MediaOutputValidator.IsValidMp4(result.OutputPath));
        Assert.Contains("0:a?", runner.LastInvocation!.Arguments);
    }

    [Fact]
    public async Task AudioOnlyPrimaryWithExternalAudioUsesTheSelectedExternalRendition()
    {
        using var scope = new TestFileScope();
        string primary = scope.PathFor("primary.ts");
        string secondary = scope.PathFor("selected-audio.ts");
        await File.WriteAllTextAsync(primary, "primary fixture");
        await File.WriteAllTextAsync(secondary, "secondary fixture");
        var runner = new OutputCreatingRunner(MediaOutputFormat.Wav);
        var probe = new PathProbe(new Dictionary<string, MediaTrackInfo>(StringComparer.OrdinalIgnoreCase)
        {
            [primary] = new(false, true, 44_100, 2),
            [secondary] = new(false, true, 48_000, 1)
        });
        var composer = new FFmpegMediaComposer("ffmpeg", probe, runner);

        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(
            primary,
            scope.PathFor("output"),
            SecondaryAudioInputPath: secondary));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.Equal(48_000, result.Tracks.AudioSampleRate);
        Assert.Equal(1, result.Tracks.AudioChannels);
        int mapIndex = runner.LastInvocation!.Arguments.ToList().IndexOf("-map");
        Assert.Equal("1:a:0", runner.LastInvocation.Arguments[mapIndex + 1]);
    }

    private sealed class StubProbe(MediaTrackInfo result) : IMediaTrackProbe
    {
        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default) =>
            Task.FromResult(result);
    }

    private sealed class PathProbe(IReadOnlyDictionary<string, MediaTrackInfo> results) : IMediaTrackProbe
    {
        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default) =>
            Task.FromResult(results[inputPath]);
    }

    private sealed class OutputCreatingRunner(MediaOutputFormat format) : IExternalToolRunner
    {
        public ExternalToolInvocation? LastInvocation { get; private set; }

        public Task<ExternalToolResult> RunAsync(ExternalToolInvocation invocation, CancellationToken cancellationToken = default)
        {
            LastInvocation = invocation;
            string output = invocation.Arguments[^1];
            if (format == MediaOutputFormat.Wav)
            {
                TestFileScope.WritePcm16Wav(output);
            }
            else
            {
                TestFileScope.WriteMinimalMp4(output);
            }

            return Task.FromResult(new ExternalToolResult(0, string.Empty, string.Empty));
        }
    }
}
