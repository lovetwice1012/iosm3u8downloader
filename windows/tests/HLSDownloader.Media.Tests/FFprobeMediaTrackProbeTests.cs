namespace HLSDownloader.Media.Tests;

public sealed class FFprobeMediaTrackProbeTests
{
    [Fact]
    public async Task ReadsActualVideoAndAudioStreamsFromJson()
    {
        var runner = new JsonRunner("""
            {"streams":[{"codec_type":"video"},{"codec_type":"audio","sample_rate":"44100","channels":2}]}
            """);
        var probe = new FFprobeMediaTrackProbe("ffprobe", runner);

        MediaTrackInfo result = await probe.ProbeAsync("fixture.mp4", TimeSpan.FromSeconds(1));

        Assert.True(result.HasVideo);
        Assert.True(result.HasAudio);
        Assert.Equal(44100, result.AudioSampleRate);
        Assert.Equal(2, result.AudioChannels);
    }

    [Fact]
    public async Task RestrictsLocalPlaylistProtocolsToFileAndCrypto()
    {
        var runner = new JsonRunner("{\"streams\":[{\"codec_type\":\"audio\"}]}");
        var probe = new FFprobeMediaTrackProbe("ffprobe", runner);

        await probe.ProbeAsync(Path.GetFullPath("fixture.m3u8"), TimeSpan.FromSeconds(1));

        int option = runner.Invocation!.Arguments.ToList().IndexOf("-protocol_whitelist");
        Assert.True(option >= 0);
        Assert.Equal("file,crypto", runner.Invocation.Arguments[option + 1]);
        int extensions = runner.Invocation.Arguments.ToList().IndexOf("-allowed_extensions");
        Assert.True(extensions >= 0);
        Assert.DoesNotContain("ALL", runner.Invocation.Arguments[extensions + 1], StringComparison.OrdinalIgnoreCase);
        Assert.Contains("key", runner.Invocation.Arguments[extensions + 1], StringComparison.Ordinal);
    }

    private sealed class JsonRunner(string json) : IExternalToolRunner
    {
        public ExternalToolInvocation? Invocation { get; private set; }

        public Task<ExternalToolResult> RunAsync(ExternalToolInvocation invocation, CancellationToken cancellationToken = default)
        {
            Invocation = invocation;
            return Task.FromResult(new ExternalToolResult(0, json, string.Empty));
        }
    }
}
