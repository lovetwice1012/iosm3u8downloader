namespace HLSDownloader.Core;

public sealed record HlsPlanningOptions(int MaximumSegments = 100_000)
{
    internal void Validate()
    {
        if (MaximumSegments is < 1 or > 1_000_000) throw new ArgumentOutOfRangeException(nameof(MaximumSegments));
    }
}

public sealed class HlsDownloadPlanBuilder(
    ITextResourceFetcher fetcher,
    HlsPlanningOptions? options = null) : IDownloadPlanBuilder
{
    private readonly HlsPlanningOptions _options = options ?? new();

    public async Task<DownloadPlan> BuildAsync(
        MediaCandidate candidate,
        CancellationToken cancellationToken = default)
    {
        _options.Validate();
        if (candidate.Kind != MediaCandidateKind.Hls)
            throw new CoreException("The HLS plan builder only accepts HLS candidates.");
        var root = await FetchPlaylistAsync(candidate.Uri, candidate.PageUri, cancellationToken).ConfigureAwait(false);
        if (root.Playlist is HlsMediaPlaylist direct)
        {
            ValidateMedia(candidate.RequestedUri ?? candidate.Uri, root.EffectiveUri, direct);
            return new(candidate, direct, null, MediaOutputFormat.Mp4);
        }

        var master = (HlsMasterPlaylist)root.Playlist;
        var variant = master.Variants.OrderByDescending(x => x.AverageBandwidth ?? x.Bandwidth).First();
        var mainResult = await FetchPlaylistAsync(variant.Uri, master.EffectiveUri, cancellationToken).ConfigureAwait(false);
        if (mainResult.Playlist is not HlsMediaPlaylist main)
            throw new PlaylistException("A selected master variant resolved to another master playlist.");
        ValidateMedia(variant.Uri, mainResult.EffectiveUri, main);

        HlsMediaPlaylist? audio = null;
        if (!string.IsNullOrEmpty(variant.AudioGroupId))
        {
            var rendition = master.Renditions
                .Where(x => x.Type == "AUDIO" && x.GroupId == variant.AudioGroupId && x.Uri is not null)
                .OrderByDescending(x => x.IsDefault).ThenByDescending(x => x.IsAutoSelect).FirstOrDefault();
            if (rendition?.Uri is { } audioUri)
            {
                var audioResult = await FetchPlaylistAsync(audioUri, master.EffectiveUri, cancellationToken).ConfigureAwait(false);
                audio = audioResult.Playlist as HlsMediaPlaylist ??
                    throw new PlaylistException("The selected audio rendition is not a media playlist.");
                ValidateMedia(audioUri, audioResult.EffectiveUri, audio);
            }
        }
        if (audio is not null && main.UsesSampleAes != audio.UsesSampleAes)
            throw new PlaylistException("Mixed SAMPLE-AES and clear/AES-128 renditions are unsupported.");

        // The media layer probes real tracks and changes this to WAV when no video track exists.
        return new(candidate, main, audio, MediaOutputFormat.Mp4);

        void ValidateMedia(Uri requested, Uri effective, HlsMediaPlaylist playlist)
        {
            if (playlist.Segments.Count > _options.MaximumSegments)
                throw new PlaylistException("The playlist exceeds the segment limit.");
            if (playlist.UsesSampleAes &&
                (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(requested) ||
                 !WidevineDownloadPolicy.IsDownloadableWidevineDomain(effective)))
                throw new PlaylistException("SAMPLE-AES is not permitted for this host.");
        }
    }

    private async Task<(HlsPlaylist Playlist, Uri EffectiveUri)> FetchPlaylistAsync(
        Uri uri, Uri referer, CancellationToken cancellationToken)
    {
        var result = await fetcher.FetchTextAsync(uri, referer, cancellationToken).ConfigureAwait(false);
        return (HlsPlaylistParser.Parse(result.Text, result.EffectiveUri, referer), result.EffectiveUri);
    }
}
