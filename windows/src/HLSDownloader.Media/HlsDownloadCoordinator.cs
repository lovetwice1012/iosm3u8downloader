using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using HLSDownloader.Core;

namespace HLSDownloader.Media;

public sealed record HlsMediaDownloadOptions(
    int MaximumConcurrentRequests = 2,
    long MaximumTotalBytes = 20L * 1024 * 1024 * 1024,
    TimeSpan? ComposeTimeout = null,
    string? TemporaryRoot = null)
{
    internal void Validate()
    {
        if (MaximumConcurrentRequests is < 1 or > 16 || MaximumTotalBytes is < 1024 or > 2L * 1024 * 1024 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(nameof(HlsMediaDownloadOptions));
        }
    }
}

public sealed class HlsDownloadCoordinator
{
    private readonly IDownloadPlanBuilder _planBuilder;
    private readonly IResourceDownloader _downloader;
    private readonly IMediaComposer _composer;
    private readonly IWidevineL3MediaProvider _widevineProvider;
    private readonly ProgressiveMediaProcessor? _progressiveProcessor;
    private readonly HlsMediaDownloadOptions _options;

    public HlsDownloadCoordinator(
        IDownloadPlanBuilder planBuilder,
        IResourceDownloader downloader,
        IMediaComposer composer,
        IWidevineL3MediaProvider? widevineProvider = null,
        HlsMediaDownloadOptions? options = null,
        ProgressiveMediaProcessor? progressiveProcessor = null)
    {
        _planBuilder = planBuilder ?? throw new ArgumentNullException(nameof(planBuilder));
        _downloader = downloader ?? throw new ArgumentNullException(nameof(downloader));
        _composer = composer ?? throw new ArgumentNullException(nameof(composer));
        _widevineProvider = widevineProvider ?? new UnavailableWidevineL3MediaProvider();
        _progressiveProcessor = progressiveProcessor;
        _options = options ?? new HlsMediaDownloadOptions();
        _options.Validate();
    }

    public async Task<MediaComposeResult> DownloadAsync(
        MediaCandidate candidate,
        string outputBasePath,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentException.ThrowIfNullOrWhiteSpace(outputBasePath);
        if (candidate.Kind == MediaCandidateKind.Progressive)
        {
            if (_progressiveProcessor is null)
                throw new NotSupportedException("Progressive media downloading is not configured.");
            return await _progressiveProcessor.DownloadAsync(
                candidate,
                outputBasePath,
                progress,
                cancellationToken).ConfigureAwait(false);
        }
        if (candidate.Kind == MediaCandidateKind.WidevineDash)
        {
            progress?.Report(new DownloadProgress(
                DownloadPhase.Resolving,
                0,
                0,
                "Widevine MPDとライセンス条件を検証しています"));
            Uri requestedManifestUri = candidate.RequestedUri ?? candidate.Uri;
            if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(requestedManifestUri) ||
                !WidevineDownloadPolicy.IsDownloadableWidevineDomain(candidate.Uri))
            {
                throw new WidevineL3ProviderUnavailableException(
                    "Widevine playback may be available, but decrypted download is not permitted for this manifest host.");
            }

            if (!_widevineProvider.IsConfigured)
            {
                throw new WidevineL3ProviderUnavailableException(
                    "Widevine download is disabled because no authorized Windows WVD/L3 provider is configured.");
            }

            var request = new WidevineL3DownloadRequest(
                requestedManifestUri,
                candidate.Uri,
                outputBasePath,
                WidevineDownloadPolicy.IsDownloadableWidevineDomain,
                candidate.ObservedWidevineLicenseUri);
            if (!request.IsPermittedManifestUri(request.RequestedManifestUri) ||
                !request.IsPermittedManifestUri(request.InitialEffectiveManifestUri))
            {
                throw new WidevineL3ProviderUnavailableException("The Widevine manifest host failed the final download policy check.");
            }

            MediaComposeResult result = await _widevineProvider
                .DownloadAndComposeAsync(request, cancellationToken)
                .ConfigureAwait(false);
            progress?.Report(new DownloadProgress(
                DownloadPhase.Completed,
                1,
                1,
                result.OutputFormat == MediaOutputFormat.Wav
                    ? "復号済みWAVを保存しました"
                    : "復号済みMP4を保存しました"));
            return result;
        }

        progress?.Report(new DownloadProgress(DownloadPhase.Resolving, 0, 0, "HLSプレイリストを解析しています"));
        DownloadPlan plan = await _planBuilder.BuildAsync(candidate, cancellationToken).ConfigureAwait(false);
        if (plan.MainPlaylist is null)
        {
            throw new InvalidDataException("The HLS plan does not contain a main media playlist.");
        }
        ValidateSampleAesDownloadPolicy(candidate, plan);

        string temporaryRoot = Path.GetFullPath(_options.TemporaryRoot ?? Path.Combine(Path.GetTempPath(), "HLSDownloader", "DownloadJobs"));
        Directory.CreateDirectory(temporaryRoot);
        string jobDirectory = Path.Combine(temporaryRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(jobDirectory);
        try
        {
            long stagingLimit = MediaOutputBudget.LimitForPath(
                Path.Combine(jobDirectory, ".staging-budget"),
                _options.MaximumTotalBytes);
            HlsLocalPlaylistBuild[] builds = plan.AudioPlaylist is null
                ? [new(plan.MainPlaylist, "main")]
                : [new(plan.MainPlaylist, "main"), new(plan.AudioPlaylist, "audio")];
            int totalResources = builds.Sum(build => CountResources(build.Playlist));
            var completed = new StrongBox<int>();
            var totalBytes = new StrongBox<long>();
            var redactions = new ConcurrentDictionary<string, byte>(StringComparer.OrdinalIgnoreCase);

            foreach (HlsLocalPlaylistBuild build in builds)
            {
                build.PlaylistPath = await StagePlaylistAsync(
                    build.Playlist,
                    Path.Combine(jobDirectory, build.Name),
                    totalResources,
                    completed,
                    totalBytes,
                    stagingLimit,
                    redactions,
                    progress,
                    cancellationToken).ConfigureAwait(false);
            }

            ValidateSampleAesDownloadPolicy(candidate, plan);
            progress?.Report(new DownloadProgress(DownloadPhase.Composing, totalResources, totalResources, "実際の映像・音声トラックを確認しています"));
            MediaOutputBudget.EnsureFits(
                Path.ChangeExtension(outputBasePath, ".mp4"),
                totalBytes.Value,
                _options.MaximumTotalBytes);
            MediaComposeResult result = await _composer.ComposeAsync(
                new MediaComposeRequest(
                    builds[0].PlaylistPath!,
                    outputBasePath,
                    _options.ComposeTimeout,
                    redactions.Keys.ToArray(),
                    builds.Length > 1 ? builds[1].PlaylistPath : null,
                    _options.MaximumTotalBytes),
                cancellationToken).ConfigureAwait(false);
            progress?.Report(new DownloadProgress(DownloadPhase.Completed, totalResources, totalResources, result.OutputPath));
            return result;
        }
        finally
        {
            ProtectedPlaylistLease.TryDeleteDirectory(jobDirectory);
        }
    }

    public void CleanupAbandonedJobs(TimeSpan olderThan)
    {
        string root = Path.GetFullPath(_options.TemporaryRoot ?? Path.Combine(Path.GetTempPath(), "HLSDownloader", "DownloadJobs"));
        if (olderThan < TimeSpan.Zero || !Directory.Exists(root))
        {
            return;
        }

        DateTime threshold = DateTime.UtcNow - olderThan;
        foreach (string directory in Directory.EnumerateDirectories(root))
        {
            if (Guid.TryParseExact(Path.GetFileName(directory), "N", out _) && Directory.GetLastWriteTimeUtc(directory) < threshold)
            {
                ProtectedPlaylistLease.TryDeleteDirectory(directory);
            }
        }
    }

    private async Task<string> StagePlaylistAsync(
        HlsMediaPlaylist playlist,
        string directory,
        int totalResources,
        StrongBox<int> completed,
        StrongBox<long> totalBytes,
        long stagingLimit,
        ConcurrentDictionary<string, byte> redactions,
        IProgress<DownloadProgress>? progress,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        ValidateFmp4SampleAesRotation(playlist);
        Dictionary<string, ResourceSpec> resources = CreateResourceSpecs(playlist, directory);
        await Parallel.ForEachAsync(
            resources.Values,
            new ParallelOptions
            {
                MaxDegreeOfParallelism = _options.MaximumConcurrentRequests,
                CancellationToken = cancellationToken
            },
            async (resource, token) =>
            {
                HttpResource response = await _downloader.FetchAsync(
                    resource.Uri,
                    playlist.EffectiveUri,
                    resource.Range?.Offset,
                    resource.Range?.Length,
                    token).ConfigureAwait(false);
                long cumulative = Interlocked.Add(ref totalBytes.Value, response.Data.LongLength);
                if (cumulative >= stagingLimit)
                {
                    throw new InvalidDataException("The HLS download exceeded its bounded staging-space limit.");
                }

                if (resource.IsKey)
                {
                    if (response.Data.Length != 16)
                    {
                        throw new InvalidDataException("An identity HLS encryption key must contain exactly 16 bytes.");
                    }

                    redactions.TryAdd(Convert.ToHexString(response.Data), 0);
                    redactions.TryAdd(Convert.ToHexString(response.Data).ToLowerInvariant(), 0);
                }

                string partial = resource.LocalPath + ".part";
                await File.WriteAllBytesAsync(partial, response.Data, token).ConfigureAwait(false);
                File.Move(partial, resource.LocalPath, overwrite: true);
                int done = Interlocked.Increment(ref completed.Value);
                progress?.Report(new DownloadProgress(DownloadPhase.Downloading, done, totalResources, "HLSリソースを取得しています"));
            }).ConfigureAwait(false);

        string playlistPath = Path.Combine(directory, "local.m3u8");
        string content = RenderLocalPlaylist(playlist, resources);
        await File.WriteAllTextAsync(playlistPath, content, new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
        return playlistPath;
    }

    private static Dictionary<string, ResourceSpec> CreateResourceSpecs(HlsMediaPlaylist playlist, string directory)
    {
        var resources = new Dictionary<string, ResourceSpec>(StringComparer.Ordinal);
        foreach (HlsSegment segment in playlist.Segments)
        {
            AddKey(segment.Encryption);
            AddKey(segment.InitializationMap?.Encryption);
            if (segment.InitializationMap is { } map)
            {
                string identity = Identity("map", map.Uri, map.ByteRange);
                resources.TryAdd(identity, new ResourceSpec(
                    map.Uri,
                    map.ByteRange,
                    Path.Combine(directory, $"map-{resources.Count:D6}.mp4"),
                    false));
            }

            string extension = ChooseSegmentExtension(segment);
            string segmentIdentity = Identity($"segment-{segment.Ordinal}", segment.Uri, segment.ByteRange);
            resources[segmentIdentity] = new ResourceSpec(
                segment.Uri,
                segment.ByteRange,
                Path.Combine(directory, $"segment-{segment.Ordinal:D6}{extension}"),
                false);
        }

        return resources;

        void AddKey(HlsEncryption? encryption)
        {
            if (encryption is null)
            {
                return;
            }

            string identity = Identity("key", encryption.KeyUri, null);
            resources.TryAdd(identity, new ResourceSpec(
                encryption.KeyUri,
                null,
                Path.Combine(directory, $"key-{resources.Count:D6}.key"),
                true));
        }
    }

    private static string RenderLocalPlaylist(HlsMediaPlaylist playlist, IReadOnlyDictionary<string, ResourceSpec> resources)
    {
        var result = new StringBuilder("#EXTM3U\n#EXT-X-VERSION:7\n");
        result.Append("#EXT-X-TARGETDURATION:")
            .Append(Math.Max(1, (int)Math.Ceiling(playlist.Segments.Max(segment => segment.Duration))))
            .Append('\n');
        result.Append("#EXT-X-MEDIA-SEQUENCE:").Append(playlist.Segments[0].MediaSequence).Append('\n');
        HlsEncryption? activeEncryption = null;
        string? activeMapIdentity = null;
        foreach (HlsSegment segment in playlist.Segments)
        {
            if (segment.HasDiscontinuity)
            {
                result.Append("#EXT-X-DISCONTINUITY\n");
            }

            if (segment.InitializationMap is { } map)
            {
                string mapIdentity = Identity("map", map.Uri, map.ByteRange);
                if (!string.Equals(activeMapIdentity, mapIdentity, StringComparison.Ordinal))
                {
                    AppendEncryption(result, map.Encryption, activeEncryption, resources);
                    activeEncryption = map.Encryption;
                    result.Append("#EXT-X-MAP:URI=\"")
                        .Append(Path.GetFileName(resources[mapIdentity].LocalPath))
                        .Append("\"\n");
                    activeMapIdentity = mapIdentity;
                }
            }

            AppendEncryption(result, segment.Encryption, activeEncryption, resources);
            activeEncryption = segment.Encryption;
            string segmentIdentity = Identity($"segment-{segment.Ordinal}", segment.Uri, segment.ByteRange);
            result.Append("#EXTINF:")
                .Append(segment.Duration.ToString("0.######", CultureInfo.InvariantCulture))
                .Append(",\n")
                .Append(Path.GetFileName(resources[segmentIdentity].LocalPath))
                .Append('\n');
        }

        result.Append("#EXT-X-ENDLIST\n");
        return result.ToString();
    }

    private static void AppendEncryption(
        StringBuilder playlist,
        HlsEncryption? next,
        HlsEncryption? current,
        IReadOnlyDictionary<string, ResourceSpec> resources)
    {
        if (EncryptionsEqual(next, current))
        {
            return;
        }

        if (next is null)
        {
            playlist.Append("#EXT-X-KEY:METHOD=NONE\n");
            return;
        }

        string method = next.Method == HlsEncryptionMethod.Aes128 ? "AES-128" : "SAMPLE-AES";
        string keyIdentity = Identity("key", next.KeyUri, null);
        playlist.Append("#EXT-X-KEY:METHOD=").Append(method)
            .Append(",KEYFORMAT=\"identity\",URI=\"")
            .Append(Path.GetFileName(resources[keyIdentity].LocalPath))
            .Append('"');
        if (next.ExplicitIv is not null)
        {
            playlist.Append(",IV=0x").Append(Convert.ToHexString(next.ExplicitIv));
        }

        playlist.Append('\n');
    }

    private static bool EncryptionsEqual(HlsEncryption? left, HlsEncryption? right) =>
        ReferenceEquals(left, right) ||
        (left is not null && right is not null && left.Method == right.Method && left.KeyUri == right.KeyUri &&
         ((left.ExplicitIv is null && right.ExplicitIv is null) ||
          (left.ExplicitIv is not null && right.ExplicitIv is not null && left.ExplicitIv.AsSpan().SequenceEqual(right.ExplicitIv))));

    private static int CountResources(HlsMediaPlaylist playlist)
    {
        var identities = new HashSet<string>(StringComparer.Ordinal);
        foreach (HlsSegment segment in playlist.Segments)
        {
            identities.Add(Identity($"segment-{segment.Ordinal}", segment.Uri, segment.ByteRange));
            if (segment.Encryption is { } encryption)
            {
                identities.Add(Identity("key", encryption.KeyUri, null));
            }

            if (segment.InitializationMap is { } map)
            {
                identities.Add(Identity("map", map.Uri, map.ByteRange));
                if (map.Encryption is { } mapEncryption)
                {
                    identities.Add(Identity("key", mapEncryption.KeyUri, null));
                }
            }
        }

        return identities.Count;
    }

    private static void ValidateFmp4SampleAesRotation(HlsMediaPlaylist playlist)
    {
        if (!playlist.Segments.Any(segment => segment.InitializationMap is not null))
        {
            return;
        }

        int distinctKeys = playlist.Segments
            .Select(segment => segment.Encryption)
            .Where(encryption => encryption?.Method == HlsEncryptionMethod.SampleAes)
            .Select(encryption => encryption!.KeyUri.AbsoluteUri + (encryption.ExplicitIv is null ? string.Empty : Convert.ToHexString(encryption.ExplicitIv)))
            .Distinct(StringComparer.Ordinal)
            .Count();
        if (distinctKeys > 1)
        {
            throw new NotSupportedException("identity SAMPLE-AES key rotation for fMP4 is not supported by this Windows pipeline.");
        }
    }

    private static void ValidateSampleAesDownloadPolicy(MediaCandidate candidate, DownloadPlan plan)
    {
        HlsMediaPlaylist[] protectedPlaylists = new[] { plan.MainPlaylist, plan.AudioPlaylist }
            .Where(playlist => playlist?.UsesSampleAes == true)
            .Cast<HlsMediaPlaylist>()
            .ToArray();
        if (protectedPlaylists.Length == 0)
        {
            return;
        }

        Uri requested = candidate.RequestedUri ?? candidate.Uri;
        if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(requested) ||
            !WidevineDownloadPolicy.IsDownloadableWidevineDomain(candidate.Uri) ||
            protectedPlaylists.Any(playlist => !WidevineDownloadPolicy.IsDownloadableWidevineDomain(playlist.EffectiveUri)))
        {
            throw new InvalidDataException("identity SAMPLE-AES download is not permitted for the requested or effective playlist host.");
        }
    }

    private static string Identity(string kind, Uri uri, HlsByteRange? range) =>
        $"{kind}|{uri.AbsoluteUri}|{range?.Offset.ToString(CultureInfo.InvariantCulture)}|{range?.Length.ToString(CultureInfo.InvariantCulture)}";

    private static string ChooseSegmentExtension(HlsSegment segment)
    {
        string extension = Path.GetExtension(segment.Uri.AbsolutePath).ToLowerInvariant();
        return extension is ".ts" or ".m4s" or ".mp4" or ".aac" or ".ac3" or ".ec3"
            ? extension
            : segment.InitializationMap is null ? ".ts" : ".m4s";
    }

    private sealed record ResourceSpec(Uri Uri, HlsByteRange? Range, string LocalPath, bool IsKey);

    private sealed class HlsLocalPlaylistBuild(HlsMediaPlaylist playlist, string name)
    {
        public HlsMediaPlaylist Playlist { get; } = playlist;
        public string Name { get; } = name;
        public string? PlaylistPath { get; set; }
    }

    private sealed class StrongBox<T>
    {
        public T Value = default!;
    }
}
