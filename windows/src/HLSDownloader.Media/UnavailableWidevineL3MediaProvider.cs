namespace HLSDownloader.Media;

public sealed class UnavailableWidevineL3MediaProvider : IWidevineL3MediaProvider
{
    public bool IsConfigured => false;

    public Task<MediaComposeResult> DownloadAndComposeAsync(
        WidevineL3DownloadRequest request,
        CancellationToken cancellationToken = default) =>
        Task.FromException<MediaComposeResult>(new WidevineL3ProviderUnavailableException(
            "Widevine L3 export requires an explicitly configured, authorized provider. Native WebView playback does not expose clear media files."));
}
