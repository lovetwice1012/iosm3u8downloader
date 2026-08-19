namespace HLSDownloader.Media.Tests;

public sealed class FFmpegIntegrationTests
{
    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealWebMWithMediaBlockPassesStructuralValidation()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var runner = new ExternalToolRunner();
        string output = scope.PathFor("real.webm");
        ExternalToolResult fixture = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
                "-t", "0.4", "-an", "-c:v", "libvpx-vp9", "-f", "webm", output
            ],
            TimeSpan.FromSeconds(30)));

        Assert.Equal(0, fixture.ExitCode);
        Assert.True(MediaOutputValidator.IsValidWebM(output));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealAudioOnlyHlsIsDetectedAndExportedAsPcm16Wav()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var runner = new ExternalToolRunner();
        string sourcePlaylist = scope.PathFor("audio.m3u8");
        ExternalToolResult fixture = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=1000:sample_rate=48000",
                "-t", "0.5", "-c:a", "aac", "-f", "hls",
                "-hls_time", "0.25", "-hls_playlist_type", "vod", sourcePlaylist
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, fixture.ExitCode);

        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(
            sourcePlaylist,
            scope.PathFor("result"),
            TimeSpan.FromSeconds(30)));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.False(result.Tracks.HasVideo);
        Assert.True(result.Tracks.HasAudio);
        Assert.True(MediaOutputValidator.IsValidPcm16Wav(result.OutputPath));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealIdentityAes128HlsIsDecryptedAndExportedAsWav()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var runner = new ExternalToolRunner();
        string clearSegment = scope.PathFor("clear.ts");
        ExternalToolResult fixture = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
                "-t", "0.5", "-c:a", "aac", "-f", "mpegts", clearSegment
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, fixture.ExitCode);

        byte[] key = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        byte[] iv = Aes128CbcDecryptor.CreateMediaSequenceInitializationVector(0);
        byte[] clear = await File.ReadAllBytesAsync(clearSegment);
        byte[] encrypted;
        using (System.Security.Cryptography.Aes aes = System.Security.Cryptography.Aes.Create())
        {
            aes.Key = key;
            aes.IV = iv;
            aes.Mode = System.Security.Cryptography.CipherMode.CBC;
            aes.Padding = System.Security.Cryptography.PaddingMode.PKCS7;
            using var encryptor = aes.CreateEncryptor();
            encrypted = encryptor.TransformFinalBlock(clear, 0, clear.Length);
        }

        await File.WriteAllBytesAsync(scope.PathFor("segment.ts"), encrypted);
        await File.WriteAllBytesAsync(scope.PathFor("key.key"), key);
        string playlist = scope.PathFor("encrypted.m3u8");
        await File.WriteAllTextAsync(playlist, """
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:1
            #EXT-X-MEDIA-SEQUENCE:0
            #EXT-X-KEY:METHOD=AES-128,URI="key.key",IV=0x00000000000000000000000000000000
            #EXTINF:0.5,
            segment.ts
            #EXT-X-ENDLIST

            """);

        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(
            playlist,
            scope.PathFor("decrypted"),
            TimeSpan.FromSeconds(30),
            [Convert.ToHexString(key)]));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.True(MediaOutputValidator.IsValidPcm16Wav(result.OutputPath));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealIdentitySampleAesAacIsDecryptedAndExportedAsWavWithoutLoggingTheKey()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var log = new List<string>();
        var runner = new ExternalToolRunner(log.Add);
        byte[] key = Enumerable.Range(0x30, 16).Select(value => (byte)value).ToArray();
        byte[] initializationVector = new byte[16];
        string protectedAac = await IdentitySampleAesFixture.CreateProtectedAacAsync(
            locator.ResolveFFmpeg(), runner, scope.DirectoryPath, key, initializationVector);

        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        var sampleAesComposer = new SampleAesMediaComposer(
            new SampleAesLocalPackageBuilder(scope.PathFor("sample-aes-jobs")),
            composer);
        MediaComposeResult result = await sampleAesComposer.ComposeAsync(
            new SampleAesPlaylistPackage([
                new SampleAesSegment(protectedAac, 0.6, new SampleAesKey(key, Convert.ToHexString(initializationVector)))
            ]),
            scope.PathFor("sample-aes-audio-result"),
            TimeSpan.FromSeconds(30));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.False(result.Tracks.HasVideo);
        Assert.True(result.Tracks.HasAudio);
        Assert.True(MediaOutputValidator.IsValidPcm16Wav(result.OutputPath));
        Assert.DoesNotContain(log, line => line.Contains(Convert.ToHexString(key), StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealIdentitySampleAesH264AndAacAreDecryptedAndExportedAsMp4()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var runner = new ExternalToolRunner();
        byte[] key = Enumerable.Range(0x50, 16).Select(value => (byte)value).ToArray();
        byte[] initializationVector = new byte[16];
        string protectedTransportStream = await IdentitySampleAesFixture.CreateProtectedAudioVideoTransportStreamAsync(
            locator.ResolveFFmpeg(), runner, scope.DirectoryPath, key, initializationVector);

        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        var sampleAesComposer = new SampleAesMediaComposer(
            new SampleAesLocalPackageBuilder(scope.PathFor("sample-aes-video-jobs")),
            composer);
        MediaComposeResult result = await sampleAesComposer.ComposeAsync(
            new SampleAesPlaylistPackage([
                new SampleAesSegment(protectedTransportStream, 2.4, new SampleAesKey(key, Convert.ToHexString(initializationVector)))
            ]),
            scope.PathFor("sample-aes-video-result"),
            TimeSpan.FromSeconds(30));

        Assert.Equal(MediaOutputFormat.Mp4, result.OutputFormat);
        Assert.True(result.Tracks.HasVideo);
        Assert.True(result.Tracks.HasAudio);
        Assert.True(MediaOutputValidator.IsValidMp4(result.OutputPath));
        MediaTrackInfo outputTracks = await probe.ProbeAsync(result.OutputPath, TimeSpan.FromSeconds(30));
        Assert.True(outputTracks.HasVideo);
        Assert.True(outputTracks.HasAudio);
        ExternalToolResult decodeResult = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror",
                "-i", result.OutputPath, "-map", "0:v:0", "-f", "null", "-"
            ],
            TimeSpan.FromSeconds(30)));
        Assert.True(decodeResult.ExitCode == 0, decodeResult.StandardError);
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task WrongIdentitySampleAesAudioKeyFailsWithoutPublishingPartialWav()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var log = new List<string>();
        var runner = new ExternalToolRunner(log.Add);
        byte[] encryptionKey = Enumerable.Range(0x20, 16).Select(value => (byte)value).ToArray();
        byte[] wrongKey = encryptionKey.Select(value => (byte)(value ^ 0xff)).ToArray();
        byte[] initializationVector = new byte[16];
        string protectedAac = await IdentitySampleAesFixture.CreateProtectedAacAsync(
            locator.ResolveFFmpeg(), runner, scope.DirectoryPath, encryptionKey, initializationVector);

        var composer = new SampleAesMediaComposer(
            new SampleAesLocalPackageBuilder(scope.PathFor("wrong-sample-aes-audio-jobs")),
            new FFmpegMediaComposer(
                locator.ResolveFFmpeg(),
                new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner),
                runner));
        string outputBase = scope.PathFor("wrong-sample-aes-audio-result");

        await Assert.ThrowsAnyAsync<Exception>(() => composer.ComposeAsync(
            new SampleAesPlaylistPackage([
                new SampleAesSegment(protectedAac, 0.6, new SampleAesKey(wrongKey, Convert.ToHexString(initializationVector)))
            ]),
            outputBase,
            TimeSpan.FromSeconds(30)));

        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".wav")));
        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".wav") + ".part"));
        Assert.Contains(log, line => line.Contains("-xerror", StringComparison.Ordinal) &&
            line.Contains("-err_detect explode", StringComparison.Ordinal));
        Assert.DoesNotContain(log, line => line.Contains(Convert.ToHexString(wrongKey), StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task WrongIdentitySampleAesVideoKeyFailsWithoutPublishingPartialMp4()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var log = new List<string>();
        var runner = new ExternalToolRunner(log.Add);
        byte[] encryptionKey = Enumerable.Range(0x60, 16).Select(value => (byte)value).ToArray();
        byte[] wrongKey = encryptionKey.Select(value => (byte)(value ^ 0xff)).ToArray();
        byte[] initializationVector = new byte[16];
        string protectedTransportStream = await IdentitySampleAesFixture.CreateProtectedAudioVideoTransportStreamAsync(
            locator.ResolveFFmpeg(), runner, scope.DirectoryPath, encryptionKey, initializationVector);

        var composer = new SampleAesMediaComposer(
            new SampleAesLocalPackageBuilder(scope.PathFor("wrong-sample-aes-video-jobs")),
            new FFmpegMediaComposer(
                locator.ResolveFFmpeg(),
                new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner),
                runner));
        string outputBase = scope.PathFor("wrong-sample-aes-video-result");

        await Assert.ThrowsAnyAsync<Exception>(() => composer.ComposeAsync(
            new SampleAesPlaylistPackage([
                new SampleAesSegment(protectedTransportStream, 2.4, new SampleAesKey(wrongKey, Convert.ToHexString(initializationVector)))
            ]),
            outputBase,
            TimeSpan.FromSeconds(30)));

        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".mp4")));
        Assert.False(File.Exists(Path.ChangeExtension(outputBase, ".mp4") + ".part"));
        Assert.Contains(log, line => line.Contains("-xerror", StringComparison.Ordinal) &&
            line.Contains("-err_detect explode", StringComparison.Ordinal));
        Assert.DoesNotContain(log, line => line.Contains(Convert.ToHexString(wrongKey), StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealExternalAudioRenditionIsMuxedWithVideoAsMp4()
    {
        using var scope = new TestFileScope();
        var locator = new FFmpegToolLocator();
        var runner = new ExternalToolRunner();
        string videoPlaylist = scope.PathFor("video.m3u8");
        string audioPlaylist = scope.PathFor("audio.m3u8");
        ExternalToolResult videoFixture = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
                "-t", "0.6", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                "-f", "hls", "-hls_time", "0.3", "-hls_playlist_type", "vod", videoPlaylist
            ],
            TimeSpan.FromSeconds(30)));
        ExternalToolResult audioFixture = await runner.RunAsync(new ExternalToolInvocation(
            locator.ResolveFFmpeg(),
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
                "-t", "0.6", "-vn", "-c:a", "aac",
                "-f", "hls", "-hls_time", "0.3", "-hls_playlist_type", "vod", audioPlaylist
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, videoFixture.ExitCode);
        Assert.Equal(0, audioFixture.ExitCode);

        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        MediaComposeResult result = await composer.ComposeAsync(new MediaComposeRequest(
            videoPlaylist,
            scope.PathFor("muxed"),
            TimeSpan.FromSeconds(30),
            SecondaryAudioInputPath: audioPlaylist));

        Assert.Equal(MediaOutputFormat.Mp4, result.OutputFormat);
        Assert.True(result.Tracks.HasVideo);
        Assert.True(result.Tracks.HasAudio);
        Assert.True(MediaOutputValidator.IsValidMp4(result.OutputPath));
        MediaTrackInfo outputTracks = await probe.ProbeAsync(result.OutputPath, TimeSpan.FromSeconds(30));
        Assert.True(outputTracks.HasVideo);
        Assert.True(outputTracks.HasAudio);
    }
}
