namespace HLSDownloader.Core;

public enum MediaCandidateKind
{
    Hls,
    WidevineDash,
    Progressive
}

public enum MediaCandidateOrigin
{
    Direct,
    Video,
    Source,
    DataAttribute,
    InlineScript,
    Iframe,
    BrowserBlob
}

public enum MediaOutputFormat
{
    Mp4,
    Wav,
    WebM
}

public enum DownloadPhase
{
    Idle,
    Resolving,
    Downloading,
    Composing,
    Completed
}

public sealed record DownloadProgress(
    DownloadPhase Phase,
    int CompletedItems,
    int TotalItems,
    string? Message = null)
{
    public double? Fraction => TotalItems <= 0
        ? null
        : Math.Clamp((double)CompletedItems / TotalItems, 0, 1);
}

[System.Diagnostics.DebuggerDisplay("MediaCandidate({Kind}, <redacted>)")]
public sealed record MediaCandidate(
    Uri Uri,
    MediaCandidateKind Kind,
    MediaCandidateOrigin Origin,
    Uri PageUri,
    int IframeDepth = 0,
    Uri? PosterUri = null,
    string? Title = null,
    Uri? RequestedUri = null,
    Uri? ObservedWidevineLicenseUri = null,
    string? BrowserSourceId = null)
{
    public bool CanDownload => Kind is MediaCandidateKind.Hls or MediaCandidateKind.Progressive ||
        (WidevineDownloadPolicy.IsDownloadableWidevineDomain(RequestedUri ?? Uri) &&
         WidevineDownloadPolicy.IsDownloadableWidevineDomain(Uri));

    public override string ToString() => $"MediaCandidate({Kind}, <redacted>)";
}

public sealed record DownloadPlan(
    MediaCandidate Candidate,
    HlsMediaPlaylist? MainPlaylist,
    HlsMediaPlaylist? AudioPlaylist,
    MediaOutputFormat OutputFormat);

public interface IDownloadPlanBuilder
{
    Task<DownloadPlan> BuildAsync(MediaCandidate candidate, CancellationToken cancellationToken = default);
}

public class CoreException(string message) : Exception(message);

public sealed class PlaylistException(string message) : CoreException(message);

public sealed class UnsafeNetworkTargetException(string message) : CoreException(message);
