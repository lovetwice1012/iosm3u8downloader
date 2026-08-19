using HLSDownloader.Core;

namespace HLSDownloader.Media;

public enum ProgressiveMediaContainer
{
    IsoBaseMedia,
    MpegTransportStream,
    WebM,
    AdtsAac,
    Mp3,
    Ogg
}

public sealed record ProgressiveMediaOptions(
    long MaximumBytes = 20L * 1024 * 1024 * 1024,
    TimeSpan? TransferTimeout = null,
    TimeSpan? ProbeTimeout = null,
    string? TemporaryRoot = null)
{
    internal TimeSpan EffectiveTransferTimeout => TransferTimeout ?? TimeSpan.FromHours(2);
    internal TimeSpan EffectiveProbeTimeout => ProbeTimeout ?? TimeSpan.FromMinutes(2);

    internal void Validate()
    {
        if (MaximumBytes is < 1024 or > 2L * 1024 * 1024 * 1024 * 1024 ||
            EffectiveTransferTimeout < TimeSpan.FromSeconds(1) || EffectiveTransferTimeout > TimeSpan.FromHours(12) ||
            EffectiveProbeTimeout < TimeSpan.FromSeconds(1) || EffectiveProbeTimeout > TimeSpan.FromMinutes(10))
        {
            throw new ArgumentOutOfRangeException(nameof(ProgressiveMediaOptions));
        }
    }
}

/// <summary>
/// Downloads or consumes a complete progressive media file, verifies its real
/// container and tracks, then publishes video as MP4/WebM or audio-only as WAV.
/// URL extensions and MIME types are hints only and never authorize a format.
/// </summary>
public sealed class ProgressiveMediaProcessor
{
    private readonly IStreamingResourceDownloader? _downloader;
    private readonly IMediaTrackProbe _probe;
    private readonly IMediaComposer _composer;
    private readonly ProgressiveMediaOptions _options;

    public ProgressiveMediaProcessor(
        IMediaTrackProbe probe,
        IMediaComposer composer,
        IStreamingResourceDownloader? downloader = null,
        ProgressiveMediaOptions? options = null)
    {
        _probe = probe ?? throw new ArgumentNullException(nameof(probe));
        _composer = composer ?? throw new ArgumentNullException(nameof(composer));
        _downloader = downloader;
        _options = options ?? new ProgressiveMediaOptions();
        _options.Validate();
    }

    public async Task<MediaComposeResult> DownloadAsync(
        MediaCandidate candidate,
        string outputBasePath,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputBasePath);
        if (candidate.Kind != MediaCandidateKind.Progressive)
            throw new ArgumentException("A progressive media candidate is required.", nameof(candidate));
        if (_downloader is null)
            throw new NotSupportedException("No streaming HTTP downloader is configured.");

        Uri requested = candidate.RequestedUri ?? candidate.Uri;
        if (!UriUtilities.IsHttp(requested) || !UriUtilities.IsHttp(candidate.Uri) ||
            !string.IsNullOrEmpty(requested.UserInfo) || !string.IsNullOrEmpty(candidate.Uri.UserInfo))
        {
            throw new UnsafeNetworkTargetException("Progressive downloads require credential-free HTTP(S) URLs.");
        }

        string root = Path.GetFullPath(_options.TemporaryRoot ??
            Path.Combine(Path.GetTempPath(), "HLSDownloader", "ProgressiveJobs"));
        Directory.CreateDirectory(root);
        string jobDirectory = Path.Combine(root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(jobDirectory);
        string inputPath = Path.Combine(jobDirectory, "source.media");
        try
        {
            progress?.Report(new DownloadProgress(DownloadPhase.Downloading, 0, 1, "メディアを取得しています"));
            StreamedHttpResource response = await _downloader.DownloadToFileAsync(
                requested,
                inputPath,
                candidate.PageUri,
                _options.MaximumBytes,
                _options.EffectiveTransferTimeout,
                cancellationToken).ConfigureAwait(false);
            if (!UriUtilities.IsHttp(response.EffectiveUri) || !string.IsNullOrEmpty(response.EffectiveUri.UserInfo))
                throw new UnsafeNetworkTargetException("The effective progressive media URL is unsafe.");

            progress?.Report(new DownloadProgress(DownloadPhase.Downloading, 1, 1, "メディアを検証しています"));
            return await ProcessLocalAsync(
                inputPath,
                outputBasePath,
                response.MediaType,
                progress,
                cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            ProtectedPlaylistLease.TryDeleteDirectory(jobDirectory);
        }
    }

    public async Task<MediaComposeResult> ProcessLocalAsync(
        string capturedPath,
        string outputBasePath,
        string? declaredMediaType = null,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(capturedPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputBasePath);
        string inputPath = Path.GetFullPath(capturedPath);
        FileInfo input = new(inputPath);
        input.Refresh();
        if (!input.Exists || input.Length <= 0 || input.Length > _options.MaximumBytes ||
            (input.Attributes & FileAttributes.ReparsePoint) != 0)
        {
            throw new InvalidDataException("The captured progressive media file is missing, unsafe, empty, or too large.");
        }

        ProgressiveMediaContainer container = await DetectContainerAsync(
            inputPath,
            declaredMediaType,
            cancellationToken).ConfigureAwait(false);
        RejectEncryptedContainer(inputPath, container, cancellationToken);
        MediaTrackInfo tracks = await _probe.ProbeAsync(
            inputPath,
            _options.EffectiveProbeTimeout,
            cancellationToken).ConfigureAwait(false);
        if (!tracks.HasVideo && !tracks.HasAudio)
            throw new InvalidDataException("The progressive input contains no playable audio or video track.");
        if (tracks.HasVideo && container is ProgressiveMediaContainer.AdtsAac or ProgressiveMediaContainer.Mp3 or ProgressiveMediaContainer.Ogg)
            throw new NotSupportedException("Video in this progressive container is not supported without transcoding.");

        string anticipatedOutputPath = Path.ChangeExtension(
            outputBasePath,
            tracks.HasVideo ? ".mp4" : ".wav");
        MediaOutputBudget.EnsureFits(anticipatedOutputPath, input.Length, _options.MaximumBytes);

        progress?.Report(new DownloadProgress(DownloadPhase.Composing, 1, 1, "出力ファイルを作成しています"));
        if (container == ProgressiveMediaContainer.WebM && tracks.HasVideo)
        {
            string outputPath = Path.ChangeExtension(outputBasePath, ".webm");
            string? outputDirectory = Path.GetDirectoryName(Path.GetFullPath(outputPath));
            Directory.CreateDirectory(outputDirectory!);
            string partial = outputPath + ".part";
            File.Delete(partial);
            long outputLimit = MediaOutputBudget.LimitForPath(partial, _options.MaximumBytes);
            try
            {
                await CopyBoundedAsync(inputPath, partial, outputLimit, cancellationToken).ConfigureAwait(false);
                MediaOutputBudget.EnsureBelowLimit(partial, outputLimit);
                MediaOutputValidator.Validate(partial, MediaOutputFormat.WebM);
                File.Move(partial, outputPath, overwrite: true);
                MediaOutputValidator.Validate(outputPath, MediaOutputFormat.WebM);
                var result = new MediaComposeResult(outputPath, MediaOutputFormat.WebM, tracks);
                progress?.Report(new DownloadProgress(DownloadPhase.Completed, 1, 1, outputPath));
                return result;
            }
            finally
            {
                File.Delete(partial);
            }
        }

        MediaComposeResult composed = await _composer.ComposeAsync(
            new MediaComposeRequest(
                inputPath,
                outputBasePath,
                MaximumOutputBytes: _options.MaximumBytes),
            cancellationToken).ConfigureAwait(false);
        try
        {
            if (tracks.HasVideo && composed.OutputFormat != MediaOutputFormat.Mp4 ||
                !tracks.HasVideo && composed.OutputFormat != MediaOutputFormat.Wav)
            {
                throw new InvalidDataException("The progressive media output format does not match its verified tracks.");
            }

            if (composed.OutputFormat == MediaOutputFormat.Mp4)
            {
                // The composer may have stream-copied the input. Recheck the
                // exact published bytes so residual CENC/CBCS/PIFF metadata can
                // never leave the progressive pipeline as a clear MP4.
                WidevineFmp4EncryptionValidator.ValidateClearOutput(composed.OutputPath);
            }

            MediaTrackInfo outputTracks = await _probe.ProbeAsync(
                composed.OutputPath,
                _options.EffectiveProbeTimeout,
                cancellationToken).ConfigureAwait(false);
            bool validOutputTracks = composed.OutputFormat switch
            {
                MediaOutputFormat.Mp4 => outputTracks.HasVideo &&
                    (!tracks.HasAudio || outputTracks.HasAudio),
                MediaOutputFormat.Wav => !outputTracks.HasVideo && outputTracks.HasAudio,
                _ => false
            };
            if (!validOutputTracks)
                throw new InvalidDataException("The completed progressive output track layout is invalid.");

            composed = composed with { Tracks = outputTracks };
        }
        catch
        {
            TryDeleteFile(composed.OutputPath);
            throw;
        }

        progress?.Report(new DownloadProgress(DownloadPhase.Completed, 1, 1, composed.OutputPath));
        return composed;
    }

    public void CleanupAbandonedJobs(TimeSpan olderThan)
    {
        string root = Path.GetFullPath(_options.TemporaryRoot ??
            Path.Combine(Path.GetTempPath(), "HLSDownloader", "ProgressiveJobs"));
        if (olderThan < TimeSpan.Zero || !Directory.Exists(root)) return;
        DateTime threshold = DateTime.UtcNow - olderThan;
        foreach (string directory in Directory.EnumerateDirectories(root))
        {
            if (Guid.TryParseExact(Path.GetFileName(directory), "N", out _) &&
                Directory.GetLastWriteTimeUtc(directory) < threshold)
            {
                ProtectedPlaylistLease.TryDeleteDirectory(directory);
            }
        }
    }

    internal static async Task<ProgressiveMediaContainer> DetectContainerAsync(
        string path,
        string? declaredMediaType,
        CancellationToken cancellationToken)
    {
        RejectClearlyNonMediaMime(declaredMediaType);
        byte[] prefix = new byte[Math.Min(1024 * 1024, checked((int)Math.Min(new FileInfo(path).Length, int.MaxValue)))];
        await using (FileStream stream = new(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            64 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan))
        {
            int offset = 0;
            while (offset < prefix.Length)
            {
                int count = await stream.ReadAsync(prefix.AsMemory(offset), cancellationToken).ConfigureAwait(false);
                if (count == 0) break;
                offset += count;
            }
            if (offset != prefix.Length) Array.Resize(ref prefix, offset);
        }

        return DetectContainer(prefix);
    }

    private static ProgressiveMediaContainer DetectContainer(byte[] prefix)
    {
        ReadOnlySpan<byte> data = prefix;
        if (data.Length >= 12 && data[4..8].SequenceEqual("ftyp"u8)) return ProgressiveMediaContainer.IsoBaseMedia;
        ReadOnlySpan<byte> ebmlHeader = [0x1A, 0x45, 0xDF, 0xA3];
        if (data.StartsWith(ebmlHeader)) return ProgressiveMediaContainer.WebM;
        if (data.StartsWith("OggS"u8)) return ProgressiveMediaContainer.Ogg;
        if (LooksLikeTransportStream(data)) return ProgressiveMediaContainer.MpegTransportStream;
        if (data.Length >= 2 && data[0] == 0xFF && (data[1] & 0xF6) == 0xF0) return ProgressiveMediaContainer.AdtsAac;
        if (data.StartsWith("ID3"u8) || data.Length >= 2 && data[0] == 0xFF && (data[1] & 0xE0) == 0xE0)
            return ProgressiveMediaContainer.Mp3;
        throw new InvalidDataException("The progressive response is not a supported MP4, TS, WebM, AAC, MP3, or Ogg file.");
    }

    private static void RejectClearlyNonMediaMime(string? mediaType)
    {
        if (string.IsNullOrWhiteSpace(mediaType)) return;
        string normalized = mediaType.Split(';', 2)[0].Trim().ToLowerInvariant();
        if (normalized is "text/html" or "application/xhtml+xml" or "application/json" or "text/json" or
            "application/xml" or "text/xml" or "application/dash+xml" or "application/vnd.apple.mpegurl" or
            "application/x-mpegurl")
        {
            throw new InvalidDataException("The response MIME type is not a complete progressive media file.");
        }
    }

    private static bool LooksLikeTransportStream(ReadOnlySpan<byte> data)
    {
        if (data.Length < 188 * 3) return false;
        for (int offset = 0; offset < 188; offset++)
        {
            if (data[offset] == 0x47 && data[offset + 188] == 0x47 && data[offset + 376] == 0x47)
                return true;
        }
        return false;
    }

    private static void RejectEncryptedContainer(
        string path,
        ProgressiveMediaContainer container,
        CancellationToken cancellationToken)
    {
        if (container is ProgressiveMediaContainer.MpegTransportStream or ProgressiveMediaContainer.AdtsAac)
        {
            // Standalone TS/ADTS carries no manifest/key declaration. SAMPLE-AES
            // leaves enough headers and clear sample bytes for ffprobe and even
            // a warning-only FFmpeg conversion to appear successful, so accepting
            // it could publish encrypted or partial output. Both remain supported
            // through HLS, where encryption metadata and keys are verified.
            throw new NotSupportedException(
                "Standalone MPEG-TS/ADTS requires the HLS manifest-based validation path.");
        }

        if (container == ProgressiveMediaContainer.WebM)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (!WebMMediaValidator.TryInspect(path, out WebMMediaInspection inspection))
                throw new InvalidDataException("The WebM container is invalid or contains no media samples.");
            if (inspection.IsEncrypted)
                throw new NotSupportedException("Encrypted progressive media must use the existing DRM-specific pipeline.");
            return;
        }

        if (container != ProgressiveMediaContainer.IsoBaseMedia) return;
        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            WidevineFmp4EncryptionValidator.ValidateClearOutput(path);
        }
        catch (InvalidDataException error)
        {
            throw new NotSupportedException(
                "Encrypted or structurally invalid ISO-BMFF progressive media cannot use the clear-file pipeline.",
                error);
        }
        cancellationToken.ThrowIfCancellationRequested();
    }

    private static void TryDeleteFile(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static async Task CopyBoundedAsync(
        string sourcePath,
        string destinationPath,
        long maximumBytes,
        CancellationToken cancellationToken)
    {
        await using FileStream source = new(
            sourcePath,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using FileStream destination = new(
            destinationPath,
            FileMode.CreateNew,
            FileAccess.Write,
            FileShare.None,
            128 * 1024,
            FileOptions.Asynchronous | FileOptions.SequentialScan);
        byte[] buffer = new byte[128 * 1024];
        long written = 0;
        while (true)
        {
            int count = await source.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            written = checked(written + count);
            if (written > maximumBytes) throw new InvalidDataException("The progressive media file exceeded its size limit.");
            await destination.WriteAsync(buffer.AsMemory(0, count), cancellationToken).ConfigureAwait(false);
        }
        await destination.FlushAsync(cancellationToken).ConfigureAwait(false);
    }
}
