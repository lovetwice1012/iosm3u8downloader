using HLSDownloader.Core;

namespace HLSDownloader.Windows.Services;

public sealed record CompletedMedia(string FilePath, MediaOutputFormat Format);

public interface IMediaWorkflow
{
    bool CanDownload(MediaCandidate candidate, out string reason);

    void RememberBrowserCookies(
        Uri candidateUri,
        BrowserCookieSnapshot snapshot,
        string? browserSourceId = null);

    void RememberObservedWidevineLicense(
        Uri manifestUri,
        Uri licenseUri,
        BrowserCookieSnapshot snapshot);

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
