namespace HLSDownloader.Core;

public sealed record MediaSourceResolution(
    Uri RequestedUri,
    Uri EffectiveUri,
    IReadOnlyList<MediaCandidate> Candidates,
    bool WasDirectManifest);

/// <summary>
/// Resolves a pasted URL by inspecting the response, so direct manifests work
/// even when the URL has no .m3u8/.mpd suffix or is returned behind redirects.
/// HTML responses are delegated to bounded same-origin iframe discovery.
/// </summary>
public sealed class MediaSourceResolver(
    ITextResourceFetcher fetcher,
    HtmlDiscoveryOptions? discoveryOptions = null)
{
    public async Task<MediaSourceResolution> ResolveAsync(
        Uri requestedUri,
        CancellationToken cancellationToken = default)
    {
        if (!UriUtilities.IsHttp(requestedUri) || !string.IsNullOrEmpty(requestedUri.UserInfo))
            throw new UnsafeNetworkTargetException("The source URI is not safe HTTP(S).");
        if (fetcher is IHttpPrefixProbe prefixProbe)
        {
            var prefix = await prefixProbe.ProbePrefixAsync(
                requestedUri,
                maximumPrefixBytes: 64 * 1024,
                cancellationToken: cancellationToken).ConfigureAwait(false);
            if (ProgressiveMediaHintClassifier.HasSupportedMagic(prefix.Prefix))
            {
                var candidate = new MediaCandidate(
                    prefix.EffectiveUri,
                    MediaCandidateKind.Progressive,
                    MediaCandidateOrigin.Direct,
                    prefix.EffectiveUri,
                    RequestedUri: requestedUri);
                return new(requestedUri, prefix.EffectiveUri, [candidate], false);
            }
        }
        var payload = await fetcher.FetchTextAsync(requestedUri, cancellationToken: cancellationToken).ConfigureAwait(false);
        var text = payload.Text.TrimStart('\uFEFF', ' ', '\t', '\r', '\n');
        if (HlsPlaylistParser.IsPlaylist(text))
        {
            // Parse now rather than accepting a signature-only false positive.
            _ = HlsPlaylistParser.Parse(text, payload.EffectiveUri, requestedUri);
            var candidate = new MediaCandidate(payload.EffectiveUri, MediaCandidateKind.Hls,
                MediaCandidateOrigin.Direct, payload.EffectiveUri, RequestedUri: requestedUri);
            return new(requestedUri, payload.EffectiveUri, [candidate], true);
        }

        if (LooksLikeDash(text, payload.MediaType))
        {
            if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(requestedUri) ||
                !WidevineDownloadPolicy.IsDownloadableWidevineDomain(payload.EffectiveUri))
                throw new CoreException("Widevine manifests from this host are not permitted.");
            var candidate = new MediaCandidate(payload.EffectiveUri, MediaCandidateKind.WidevineDash,
                MediaCandidateOrigin.Direct, payload.EffectiveUri, RequestedUri: requestedUri);
            return new(requestedUri, payload.EffectiveUri, [candidate], true);
        }

        var discovery = new HtmlMediaDiscovery(fetcher, discoveryOptions);
        var candidates = await discovery.DiscoverAsync(payload.Text, payload.EffectiveUri, cancellationToken).ConfigureAwait(false);
        return new(requestedUri, payload.EffectiveUri, candidates, false);
    }

    private static bool LooksLikeDash(string text, string? mediaType)
    {
        if (mediaType?.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) == true) return true;
        if (!text.StartsWith('<')) return false;
        var start = text.Length <= 4096 ? text : text[..4096];
        return start.Contains("<MPD", StringComparison.OrdinalIgnoreCase) &&
               (start.Contains("urn:mpeg:dash", StringComparison.OrdinalIgnoreCase) ||
                start.Contains("ContentProtection", StringComparison.OrdinalIgnoreCase));
    }
}
