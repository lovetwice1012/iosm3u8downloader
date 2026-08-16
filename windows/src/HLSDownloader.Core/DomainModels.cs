namespace HLSDownloader.Core;

public enum MediaCandidateKind
{
    Hls,
    WidevineDash
}

public enum MediaCandidateOrigin
{
    Direct,
    Video,
    Source,
    DataAttribute,
    InlineScript,
    Iframe
}

public enum MediaOutputFormat
{
    Mp4,
    Wav
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

public sealed record MediaCandidate(
    Uri Uri,
    MediaCandidateKind Kind,
    MediaCandidateOrigin Origin,
    Uri PageUri,
    int IframeDepth = 0,
    Uri? PosterUri = null,
    string? Title = null,
    Uri? RequestedUri = null)
{
    public bool CanDownload => Kind == MediaCandidateKind.Hls ||
        (WidevineDownloadPolicy.IsDownloadableWidevineDomain(RequestedUri ?? Uri) &&
         WidevineDownloadPolicy.IsDownloadableWidevineDomain(Uri));
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
