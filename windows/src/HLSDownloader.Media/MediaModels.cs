namespace HLSDownloader.Media;

public enum MediaOutputFormat
{
    Mp4,
    Wav
}

public sealed record MediaTrackInfo(
    bool HasVideo,
    bool HasAudio,
    int? AudioSampleRate = null,
    int? AudioChannels = null)
{
    public MediaOutputFormat OutputFormat => HasVideo ? MediaOutputFormat.Mp4 : MediaOutputFormat.Wav;
}

public sealed record MediaComposeRequest(
    string InputPath,
    string OutputBasePath,
    TimeSpan? Timeout = null,
    IReadOnlyCollection<string>? RedactedValues = null,
    string? SecondaryAudioInputPath = null);

public sealed record MediaComposeResult(
    string OutputPath,
    MediaOutputFormat OutputFormat,
    MediaTrackInfo Tracks);

public interface IMediaTrackProbe
{
    Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default);
}

public interface IMediaComposer
{
    Task<MediaComposeResult> ComposeAsync(MediaComposeRequest request, CancellationToken cancellationToken = default);
}

public sealed record WidevineL3DownloadRequest(
    Uri RequestedManifestUri,
    Uri InitialEffectiveManifestUri,
    string OutputBasePath,
    Func<Uri, bool> IsPermittedManifestUri);

/// <summary>
/// Optional boundary for an authorized Widevine L3 implementation. Implementations must invoke
/// <see cref="WidevineL3DownloadRequest.IsPermittedManifestUri"/> for the requested manifest and
/// <see cref="WidevineL3DownloadRequest.InitialEffectiveManifestUri"/>, every later effective
/// manifest URI after redirects, and again immediately before producing output.
/// </summary>
public interface IWidevineL3MediaProvider
{
    bool IsConfigured { get; }

    Task<MediaComposeResult> DownloadAndComposeAsync(
        WidevineL3DownloadRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WidevineL3ProviderUnavailableException(string message) : NotSupportedException(message);
