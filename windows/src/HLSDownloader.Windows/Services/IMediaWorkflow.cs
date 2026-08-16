using HLSDownloader.Core;

namespace HLSDownloader.Windows.Services;

public sealed record CompletedMedia(string FilePath, MediaOutputFormat Format);

public sealed record BrowserSessionCookie(
    string Name,
    string Value,
    string Domain,
    string Path,
    bool IsSecure,
    bool IsHttpOnly,
    DateTimeOffset? Expires = null);

public interface IMediaWorkflow
{
    bool CanDownload(MediaCandidate candidate, out string reason);

    void ImportBrowserCookies(Uri scope, IReadOnlyList<BrowserSessionCookie> cookies);

    Task<CompletedMedia?> ResumeLatestBackgroundJobAsync(
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken);

    Task<bool> CancelActiveBackgroundJobAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<MediaCandidate>> AnalyzeAsync(Uri input, CancellationToken cancellationToken);

    Task<CompletedMedia> DownloadAsync(
        MediaCandidate candidate,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken);
}
