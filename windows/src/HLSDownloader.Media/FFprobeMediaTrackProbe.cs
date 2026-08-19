using System.Globalization;
using System.Text.Json;

namespace HLSDownloader.Media;

public sealed class FFprobeMediaTrackProbe : IMediaTrackProbe
{
    private readonly string _ffprobePath;
    private readonly IExternalToolRunner _runner;

    public FFprobeMediaTrackProbe(string ffprobePath, IExternalToolRunner runner)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(ffprobePath);
        _ffprobePath = ffprobePath;
        _runner = runner ?? throw new ArgumentNullException(nameof(runner));
    }

    public async Task<MediaTrackInfo> ProbeAsync(
        string inputPath,
        TimeSpan timeout,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(inputPath);
        var arguments = new List<string>
        {
            "-v", "error",
            "-show_entries", "stream=codec_type,sample_rate,channels:stream_disposition=attached_pic",
            "-of", "json"
        };
        AddLocalPlaylistProtocolPolicy(arguments, inputPath);
        arguments.Add(inputPath);

        ExternalToolResult result = await _runner.RunAsync(
            new ExternalToolInvocation(_ffprobePath, arguments, timeout), cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new ExternalToolException($"ffprobe failed: {result.StandardError}", result.ExitCode);
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(result.StandardOutput);
            JsonElement streams = document.RootElement.GetProperty("streams");
            bool hasVideo = false;
            bool hasAudio = false;
            int? sampleRate = null;
            int? channels = null;
            foreach (JsonElement stream in streams.EnumerateArray())
            {
                string? codecType = stream.TryGetProperty("codec_type", out JsonElement type) ? type.GetString() : null;
                bool attachedPicture = stream.TryGetProperty("disposition", out JsonElement disposition) &&
                    disposition.TryGetProperty("attached_pic", out JsonElement attached) &&
                    attached.TryGetInt32(out int attachedValue) && attachedValue != 0;
                hasVideo |= string.Equals(codecType, "video", StringComparison.Ordinal) && !attachedPicture;
                if (!string.Equals(codecType, "audio", StringComparison.Ordinal))
                {
                    continue;
                }

                hasAudio = true;
                if (sampleRate is null && stream.TryGetProperty("sample_rate", out JsonElement rate))
                {
                    string? rawRate = rate.ValueKind == JsonValueKind.String ? rate.GetString() : rate.GetRawText();
                    if (int.TryParse(rawRate, NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsedRate))
                    {
                        sampleRate = parsedRate;
                    }
                }

                if (channels is null && stream.TryGetProperty("channels", out JsonElement channelCount) && channelCount.TryGetInt32(out int parsedChannels))
                {
                    channels = parsedChannels;
                }
            }

            return new MediaTrackInfo(hasVideo, hasAudio, sampleRate, channels);
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException)
        {
            throw new InvalidDataException("ffprobe returned invalid stream metadata.", ex);
        }
    }

    internal static void AddLocalPlaylistProtocolPolicy(ICollection<string> arguments, string inputPath)
    {
        bool isPlaylist = Path.GetExtension(inputPath).Equals(".m3u8", StringComparison.OrdinalIgnoreCase);
        bool isLocal = !Uri.TryCreate(inputPath, UriKind.Absolute, out Uri? uri) || uri.IsFile;
        if (isPlaylist && isLocal)
        {
            arguments.Add("-protocol_whitelist");
            arguments.Add("file,crypto");
            arguments.Add("-allowed_extensions");
            arguments.Add("m3u8,ts,m4s,mp4,aac,ac3,ec3,key");
        }
    }
}
