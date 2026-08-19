namespace HLSDownloader.Media;

public sealed class FFmpegMediaComposer : IMediaComposer
{
    private readonly string _ffmpegPath;
    private readonly IMediaTrackProbe _probe;
    private readonly IExternalToolRunner _runner;

    public FFmpegMediaComposer(string ffmpegPath, IMediaTrackProbe probe, IExternalToolRunner runner)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ffmpegPath);
        _ffmpegPath = ffmpegPath;
        _probe = probe ?? throw new ArgumentNullException(nameof(probe));
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
    }

    public async Task<MediaComposeResult> ComposeAsync(
        MediaComposeRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request.InputPath);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.OutputBasePath);
        TimeSpan timeout = request.Timeout ?? TimeSpan.FromMinutes(30);
        MediaTrackInfo primaryTracks = await _probe.ProbeAsync(request.InputPath, TimeSpan.FromMinutes(2), cancellationToken).ConfigureAwait(false);
        MediaTrackInfo? secondaryTracks = request.SecondaryAudioInputPath is null
            ? null
            : await _probe.ProbeAsync(request.SecondaryAudioInputPath, TimeSpan.FromMinutes(2), cancellationToken).ConfigureAwait(false);
        MediaTrackInfo tracks = new(
            primaryTracks.HasVideo,
            primaryTracks.HasAudio || secondaryTracks?.HasAudio == true,
            secondaryTracks?.AudioSampleRate ?? primaryTracks.AudioSampleRate,
            secondaryTracks?.AudioChannels ?? primaryTracks.AudioChannels);
        if (!tracks.HasVideo && !tracks.HasAudio)
        {
            throw new InvalidDataException("The input contains neither a video track nor an audio track.");
        }

        MediaOutputFormat format = tracks.OutputFormat;
        string outputPath = Path.ChangeExtension(request.OutputBasePath, format == MediaOutputFormat.Mp4 ? ".mp4" : ".wav");
        string? outputDirectory = Path.GetDirectoryName(Path.GetFullPath(outputPath));
        Directory.CreateDirectory(outputDirectory!);
        string partialPath = outputPath + ".part";
        File.Delete(partialPath);
        long outputLimit = MediaOutputBudget.LimitForPath(
            partialPath,
            request.MaximumOutputBytes ?? MediaOutputBudget.AbsoluteMaximumBytes);

        var arguments = new List<string> { "-y", "-nostdin", "-hide_banner", "-loglevel", "warning" };
        bool requiresStrictDecode = request.RedactedValues is { Count: > 0 };
        if (requiresStrictDecode)
        {
            arguments.AddRange(["-xerror", "-err_detect", "explode"]);
        }
        FFprobeMediaTrackProbe.AddLocalPlaylistProtocolPolicy(arguments, request.InputPath);
        arguments.AddRange(["-i", request.InputPath]);
        if (request.SecondaryAudioInputPath is not null)
        {
            FFprobeMediaTrackProbe.AddLocalPlaylistProtocolPolicy(arguments, request.SecondaryAudioInputPath);
            arguments.AddRange(["-i", request.SecondaryAudioInputPath]);
        }

        if (format == MediaOutputFormat.Mp4)
        {
            string audioMap = secondaryTracks?.HasAudio == true ? "1:a:0" : "0:a?";
            arguments.AddRange(["-map", "0:v:0", "-map", audioMap, "-c", "copy", "-movflags", "+faststart", "-f", "mp4",
                "-fs", outputLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), partialPath]);
        }
        else
        {
            string audioMap = secondaryTracks?.HasAudio == true ? "1:a:0" : "0:a:0";
            arguments.AddRange(["-map", audioMap, "-vn", "-c:a", "pcm_s16le", "-rf64", "auto", "-f", "wav",
                "-fs", outputLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), partialPath]);
        }

        try
        {
            ExternalToolResult result = await _runner.RunAsync(
                new ExternalToolInvocation(_ffmpegPath, arguments, timeout, request.RedactedValues),
                cancellationToken).ConfigureAwait(false);
            if (result.ExitCode != 0)
            {
                throw new ExternalToolException($"ffmpeg failed: {result.StandardError}", result.ExitCode);
            }

            MediaOutputBudget.EnsureBelowLimit(partialPath, outputLimit);
            MediaOutputValidator.Validate(partialPath, format);
            if (requiresStrictDecode)
            {
                await ValidateDecodeIntegrityAsync(
                    partialPath,
                    tracks,
                    timeout,
                    request.RedactedValues,
                    cancellationToken).ConfigureAwait(false);
            }
            File.Move(partialPath, outputPath, overwrite: true);
            MediaOutputValidator.Validate(outputPath, format);
            return new MediaComposeResult(outputPath, format, tracks);
        }
        finally
        {
            File.Delete(partialPath);
        }
    }

    private async Task ValidateDecodeIntegrityAsync(
        string outputPath,
        MediaTrackInfo expectedTracks,
        TimeSpan timeout,
        IReadOnlyCollection<string>? redactedValues,
        CancellationToken cancellationToken)
    {
        var arguments = new List<string>
        {
            "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror",
            "-err_detect", "explode", "-abort_on", "empty_output+empty_output_stream",
            "-i", outputPath
        };
        if (expectedTracks.HasVideo)
        {
            arguments.AddRange(["-map", "0:v:0"]);
            if (expectedTracks.HasAudio)
            {
                arguments.AddRange(["-map", "0:a:0"]);
            }
            else
            {
                arguments.Add("-an");
            }
        }
        else
        {
            arguments.AddRange(["-map", "0:a:0", "-vn"]);
        }
        arguments.AddRange(["-sn", "-dn", "-f", "null", "-"]);

        ExternalToolResult result = await _runner.RunAsync(
            new ExternalToolInvocation(_ffmpegPath, arguments, timeout, redactedValues),
            cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new ExternalToolException(
                $"ffmpeg decode integrity validation failed: {result.StandardError}",
                result.ExitCode);
        }
    }
}
