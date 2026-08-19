using System.Net;
using HLSDownloader.Core;

namespace HLSDownloader.Media.Tests;

public sealed class ProgressiveMediaProcessorTests
{
    [Fact]
    public async Task CompleteAudioFileIsConvertedToPcm16Wav()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("source.bin");
        await File.WriteAllBytesAsync(source, "ID3fixture-audio"u8.ToArray());
        var processor = new ProgressiveMediaProcessor(
            new StaticProbe(new MediaTrackInfo(false, true, 48_000, 2)),
            new CreatingComposer(MediaOutputFormat.Wav));

        MediaComposeResult result = await processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "audio/mpeg");

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.EndsWith(".wav", result.OutputPath, StringComparison.OrdinalIgnoreCase);
        Assert.True(MediaOutputValidator.IsValidPcm16Wav(result.OutputPath));
    }

    [Fact]
    public async Task WebMVideoIsPreservedWithoutTranscoding()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("generated.blob");
        TestFileScope.WriteMinimalWebM(source);
        var composer = new RejectingComposer();
        var processor = new ProgressiveMediaProcessor(
            new StaticProbe(new MediaTrackInfo(true, true)),
            composer);

        MediaComposeResult result = await processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/webm");

        Assert.Equal(MediaOutputFormat.WebM, result.OutputFormat);
        Assert.EndsWith(".webm", result.OutputPath, StringComparison.OrdinalIgnoreCase);
        Assert.True(MediaOutputValidator.IsValidWebM(result.OutputPath));
        Assert.Equal(0, composer.CallCount);
    }

    [Fact]
    public async Task EmptyWebMClusterIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("empty.webm");
        TestFileScope.WriteMinimalWebM(source, includeMediaSample: false);
        var probe = new CountingProbe(new MediaTrackInfo(true, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<InvalidDataException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/webm"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task EncryptedWebMBlockIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("encrypted.webm");
        TestFileScope.WriteMinimalWebM(source, encryptedBlock: true);
        var probe = new CountingProbe(new MediaTrackInfo(true, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<NotSupportedException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/webm"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task EncryptedIsoBmffIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("encrypted.bin");
        TestFileScope.WriteMinimalMp4(source, Mp4Box("pssh", new byte[24]));
        var probe = new CountingProbe(new MediaTrackInfo(true, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<NotSupportedException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/mp4"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task PiffUuidIsoBmffIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("piff-encrypted.bin");
        byte[] piffPayload =
        [
            0xA2, 0x39, 0x4F, 0x52, 0x5A, 0x9B, 0x4F, 0x14,
            0xA2, 0x44, 0x6C, 0x42, 0x7C, 0x64, 0x8D, 0xF4,
            0, 0, 0, 0
        ];
        TestFileScope.WriteMinimalMp4(source, Mp4Box("uuid", piffPayload));
        var probe = new CountingProbe(new MediaTrackInfo(true, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<NotSupportedException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/mp4"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task ResidualCencOutputIsDeletedBeforeCompletion()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("clear.mp4");
        TestFileScope.WriteMinimalMp4(source);
        string outputBase = scope.PathFor("saved");
        var processor = new ProgressiveMediaProcessor(
            new StaticProbe(new MediaTrackInfo(true, false)),
            new CreatingComposer(MediaOutputFormat.Mp4, Mp4Box("senc", new byte[24])));

        await Assert.ThrowsAsync<InvalidDataException>(() => processor.ProcessLocalAsync(
            source,
            outputBase,
            "video/mp4"));

        Assert.False(File.Exists(outputBase + ".mp4"));
    }

    [Fact]
    public async Task TracklessCompletedMp4IsDeletedBeforeCompletion()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("clear.mp4");
        TestFileScope.WriteMinimalMp4(source);
        string outputBase = scope.PathFor("saved");
        var probe = new SequenceProbe(
            new MediaTrackInfo(true, false),
            new MediaTrackInfo(false, false));
        var processor = new ProgressiveMediaProcessor(
            probe,
            new CreatingComposer(MediaOutputFormat.Mp4));

        await Assert.ThrowsAsync<InvalidDataException>(() => processor.ProcessLocalAsync(
            source,
            outputBase,
            "video/mp4"));

        Assert.Equal(2, probe.CallCount);
        Assert.Equal(outputBase + ".mp4", probe.LastInputPath);
        Assert.False(File.Exists(outputBase + ".mp4"));
    }

    [Fact]
    public async Task StandaloneTransportStreamIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("standalone.ts");
        byte[] bytes = new byte[188 * 3];
        bytes[0] = bytes[188] = bytes[376] = 0x47;
        await File.WriteAllBytesAsync(source, bytes);
        var probe = new CountingProbe(new MediaTrackInfo(true, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<NotSupportedException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "video/mp2t"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task StandaloneAdtsAacIsRejectedBeforeTrackProbe()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("standalone.aac");
        await File.WriteAllBytesAsync(source, [0xff, 0xf1, 0x50, 0x80, 0x02, 0x1f, 0xfc, 0x00]);
        var probe = new CountingProbe(new MediaTrackInfo(false, true));
        var processor = new ProgressiveMediaProcessor(probe, new RejectingComposer());

        await Assert.ThrowsAsync<NotSupportedException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "audio/aac"));

        Assert.Equal(0, probe.CallCount);
    }

    [Fact]
    public async Task HttpCandidateUsesStreamingDownloaderAndSameLocalValidation()
    {
        using var scope = new TestFileScope();
        var downloader = new FileCreatingDownloader("ID3network-audio"u8.ToArray(), "audio/mpeg");
        var processor = new ProgressiveMediaProcessor(
            new StaticProbe(new MediaTrackInfo(false, true, 44_100, 2)),
            new CreatingComposer(MediaOutputFormat.Wav),
            downloader,
            new ProgressiveMediaOptions(TemporaryRoot: scope.PathFor("jobs")));
        var candidate = new MediaCandidate(
            new Uri("https://media.example/file?id=secret"),
            MediaCandidateKind.Progressive,
            MediaCandidateOrigin.Video,
            new Uri("https://page.example/watch"));

        MediaComposeResult result = await processor.DownloadAsync(candidate, scope.PathFor("saved"));

        Assert.Equal(MediaOutputFormat.Wav, result.OutputFormat);
        Assert.Equal(candidate.Uri, downloader.LastRequestedUri);
        Assert.Equal(candidate.PageUri, downloader.LastReferer);
        Assert.Empty(Directory.EnumerateDirectories(scope.PathFor("jobs")));
    }

    [Fact]
    public async Task HtmlResponseIsRejectedEvenWhenItsUrlLooksLikeMedia()
    {
        using var scope = new TestFileScope();
        string source = scope.PathFor("video.mp4");
        await File.WriteAllTextAsync(source, "<html>not media</html>");
        var processor = new ProgressiveMediaProcessor(
            new StaticProbe(new MediaTrackInfo(true, true)),
            new RejectingComposer());

        await Assert.ThrowsAsync<InvalidDataException>(() => processor.ProcessLocalAsync(
            source,
            scope.PathFor("saved"),
            "text/html"));
    }

    private sealed class StaticProbe(MediaTrackInfo result) : IMediaTrackProbe
    {
        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default) =>
            Task.FromResult(result);
    }

    private sealed class CountingProbe(MediaTrackInfo result) : IMediaTrackProbe
    {
        public int CallCount { get; private set; }
        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default)
        {
            CallCount++;
            return Task.FromResult(result);
        }
    }

    private sealed class SequenceProbe(params MediaTrackInfo[] results) : IMediaTrackProbe
    {
        private int _index;
        public int CallCount { get; private set; }
        public string? LastInputPath { get; private set; }

        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default)
        {
            LastInputPath = inputPath;
            CallCount++;
            if (_index >= results.Length) throw new InvalidOperationException("Unexpected probe call.");
            return Task.FromResult(results[_index++]);
        }
    }

    private sealed class RejectingComposer : IMediaComposer
    {
        public int CallCount { get; private set; }
        public Task<MediaComposeResult> ComposeAsync(MediaComposeRequest request, CancellationToken cancellationToken = default)
        {
            CallCount++;
            throw new InvalidOperationException("The composer should not be called.");
        }
    }

    private sealed class CreatingComposer(MediaOutputFormat format, byte[]? mp4MoovPayload = null) : IMediaComposer
    {
        public Task<MediaComposeResult> ComposeAsync(MediaComposeRequest request, CancellationToken cancellationToken = default)
        {
            string output = Path.ChangeExtension(request.OutputBasePath, format == MediaOutputFormat.Mp4 ? ".mp4" : ".wav");
            if (format == MediaOutputFormat.Mp4) TestFileScope.WriteMinimalMp4(output, mp4MoovPayload);
            else TestFileScope.WritePcm16Wav(output);
            var tracks = format == MediaOutputFormat.Mp4
                ? new MediaTrackInfo(true, true)
                : new MediaTrackInfo(false, true, 48_000, 2);
            return Task.FromResult(new MediaComposeResult(output, format, tracks));
        }
    }

    private static byte[] Mp4Box(string type, byte[] payload)
    {
        byte[] box = new byte[8 + payload.Length];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(box, checked((uint)box.Length));
        System.Text.Encoding.ASCII.GetBytes(type).CopyTo(box, 4);
        payload.CopyTo(box, 8);
        return box;
    }

    private sealed class FileCreatingDownloader(byte[] data, string mediaType) : IStreamingResourceDownloader
    {
        public Uri? LastRequestedUri { get; private set; }
        public Uri? LastReferer { get; private set; }

        public async Task<StreamedHttpResource> DownloadToFileAsync(
            Uri uri,
            string destinationPath,
            Uri? referer = null,
            long maximumBytes = 20L * 1024 * 1024 * 1024,
            TimeSpan? transferTimeout = null,
            CancellationToken cancellationToken = default)
        {
            LastRequestedUri = uri;
            LastReferer = referer;
            await File.WriteAllBytesAsync(destinationPath, data, cancellationToken);
            return new StreamedHttpResource(uri, uri, HttpStatusCode.OK, mediaType, data.Length);
        }
    }
}
