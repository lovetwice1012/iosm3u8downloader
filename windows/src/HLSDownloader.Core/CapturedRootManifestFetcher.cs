namespace HLSDownloader.Core;

/// <summary>
/// Supplies one already captured root manifest, then delegates child playlist
/// requests to the normal bounded, job-scoped HTTP fetcher.
/// </summary>
public sealed class CapturedRootManifestFetcher : ITextResourceFetcher
{
    private readonly string _manifestText;
    private readonly Uri _effectiveUri;
    private readonly ITextResourceFetcher _fallback;
    private int _served;

    public CapturedRootManifestFetcher(
        string manifestText,
        Uri effectiveUri,
        ITextResourceFetcher fallback)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(manifestText);
        ArgumentNullException.ThrowIfNull(effectiveUri);
        ArgumentNullException.ThrowIfNull(fallback);
        if (!UriUtilities.IsHttp(effectiveUri) || !string.IsNullOrEmpty(effectiveUri.UserInfo))
        {
            throw new UnsafeNetworkTargetException("The captured manifest base URI is not safe HTTP(S).");
        }

        _manifestText = manifestText;
        _effectiveUri = effectiveUri;
        _fallback = fallback;
    }

    public Task<TextFetchResult> FetchTextAsync(
        Uri uri,
        Uri? referer = null,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (Interlocked.Exchange(ref _served, 1) == 0)
        {
            return Task.FromResult(new TextFetchResult(
                _manifestText,
                _effectiveUri,
                "application/vnd.apple.mpegurl"));
        }

        return _fallback.FetchTextAsync(uri, referer, cancellationToken);
    }

    public override string ToString() => "CapturedRootManifestFetcher(<redacted>)";
}
