namespace HLSDownloader.Media.Tests;

public sealed class FFmpegMediaComposerTests
{
    [Fact]
    public void OutputBudgetPreservesReserveAndAbsoluteLimit()
    {
        Assert.Throws<IOException>(() => MediaOutputBudget.CalculateLimit(
            MediaOutputBudget.RequiredFreeSpaceReserveBytes));
        Assert.Equal(
            2L * 1024 * 1024,
            MediaOutputBudget.CalculateLimit(
                MediaOutputBudget.RequiredFreeSpaceReserveBytes + 8L * 1024 * 1024,
                2L * 1024 * 1024));
        Assert.Equal(
            MediaOutputBudget.AbsoluteMaximumBytes,
            MediaOutputBudget.CalculateLimit(long.MaxValue));
    }

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

    [Fact]
    public async Task ProtectedInputDecodeFailureNeverPublishesOutput()
    {
        using var scope = new TestFileScope();
        string input = scope.PathFor("protected.ts");
        await File.WriteAllTextAsync(input, "fixture");
        var runner = new DecodeRejectingRunner();
        var composer = new FFmpegMediaComposer("ffmpeg", new StubProbe(new MediaTrackInfo(true, true)), runner);
        string outputBase = scope.PathFor("protected-output");

        await Assert.ThrowsAsync<ExternalToolException>(() => composer.ComposeAsync(new MediaComposeRequest(
            input,
            outputBase,
            RedactedValues: ["00112233445566778899AABBCCDDEEFF"])));

        Assert.Equal(2, runner.Invocations.Count);
        Assert.Contains("-xerror", runner.Invocations[0].Arguments);
        Assert.Contains("-err_detect", runner.Invocations[0].Arguments);
        Assert.Equal("-", runner.Invocations[1].Arguments[^1]);
        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".mp4")));
        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".mp4") + ".part"));
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

    private sealed class DecodeRejectingRunner : IExternalToolRunner
    {
        public List<ExternalToolInvocation> Invocations { get; } = [];

        public Task<ExternalToolResult> RunAsync(ExternalToolInvocation invocation, CancellationToken cancellationToken = default)
        {
            Invocations.Add(invocation);
            if (Invocations.Count == 1)
            {
                TestFileScope.WriteMinimalMp4(invocation.Arguments[^1]);
                return Task.FromResult(new ExternalToolResult(0, string.Empty, string.Empty));
            }

            return Task.FromResult(new ExternalToolResult(1, string.Empty, "decode failed"));
        }
    }
}
