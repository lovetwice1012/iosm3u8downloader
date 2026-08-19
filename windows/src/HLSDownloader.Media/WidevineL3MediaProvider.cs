using System.Security.Cryptography;
using HLSDownloader.Core;

namespace HLSDownloader.Media;

public sealed record WidevineL3MediaOptions(
    int MaximumConcurrentRequests = 3,
    int MaximumResourceBytes = 48 * 1024 * 1024,
    long MaximumTotalBytes = 16L * 1024 * 1024 * 1024,
    TimeSpan? ComposeTimeout = null,
    string? TemporaryRoot = null)
{
    internal void Validate()
    {
        if (MaximumConcurrentRequests is < 1 or > 6 ||
            MaximumResourceBytes is < 1024 or > 256 * 1024 * 1024 ||
            MaximumTotalBytes is < 1024 or > 64L * 1024 * 1024 * 1024 ||
            (ComposeTimeout ?? TimeSpan.FromMinutes(30)) is var timeout &&
            (timeout < TimeSpan.FromSeconds(1) || timeout > TimeSpan.FromHours(6)))
            throw new ArgumentOutOfRangeException(nameof(WidevineL3MediaOptions));
    }
}

/// <summary>
/// Authorized exact-host Widevine L3 exporter for static single-Period MPDs.
/// It supports one CENC/CBCS key per selected video/audio representation,
/// SegmentTemplate/SegmentTimeline/SegmentList, raw binary offline licenses,
/// FFmpeg decryption/muxing, and audio-only PCM16 WAV output.
/// </summary>
public sealed class WidevineL3MediaProvider : IWidevineL3MediaProvider
{
    private static readonly TimeSpan AbandonedJobMaximumAge = TimeSpan.FromHours(24);
    private readonly IResourceDownloader _manifestDownloader;
    private readonly IResourceDownloader _segmentDownloader;
    private readonly IWidevineCredentialSource _credentialSource;
    private readonly IWidevineRawLicenseTransport _licenseTransport;
    private readonly string _ffmpegPath;
    private readonly IMediaTrackProbe _trackProbe;
    private readonly IExternalToolRunner _toolRunner;
    private readonly WidevineL3MediaOptions _options;

    public WidevineL3MediaProvider(
        IResourceDownloader manifestDownloader,
        IResourceDownloader segmentDownloader,
        IWidevineCredentialSource credentialSource,
        IWidevineRawLicenseTransport licenseTransport,
        string ffmpegPath,
        IMediaTrackProbe trackProbe,
        IExternalToolRunner toolRunner,
        WidevineL3MediaOptions? options = null)
    {
        _manifestDownloader = manifestDownloader ?? throw new ArgumentNullException(nameof(manifestDownloader));
        _segmentDownloader = segmentDownloader ?? throw new ArgumentNullException(nameof(segmentDownloader));
        _credentialSource = credentialSource ?? throw new ArgumentNullException(nameof(credentialSource));
        _licenseTransport = licenseTransport ?? throw new ArgumentNullException(nameof(licenseTransport));
        ArgumentException.ThrowIfNullOrWhiteSpace(ffmpegPath);
        _ffmpegPath = ffmpegPath;
        _trackProbe = trackProbe ?? throw new ArgumentNullException(nameof(trackProbe));
        _toolRunner = toolRunner ?? throw new ArgumentNullException(nameof(toolRunner));
        _options = options ?? new();
        _options.Validate();
    }

    public bool IsConfigured => _credentialSource.IsAvailable && File.Exists(_ffmpegPath);

    public async Task<MediaComposeResult> DownloadAndComposeAsync(
        WidevineL3DownloadRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.OutputBasePath);
        if (!IsConfigured)
            throw new WidevineL3ProviderUnavailableException("A valid WVD credential and FFmpeg are required for Widevine L3 export.");
        bool IsPermitted(Uri uri) =>
            request.IsPermittedManifestUri(uri) && WidevineDownloadPolicy.IsDownloadableWidevineDomain(uri);
        EnsurePermitted(request.RequestedManifestUri, IsPermitted, "requested manifest");
        EnsurePermitted(request.InitialEffectiveManifestUri, IsPermitted, "initial manifest");
        if (request.ObservedLicenseUri is { } observedLicenseUri)
            EnsurePermitted(observedLicenseUri, IsPermitted, "observed license");

        HttpResource manifestResource = await _manifestDownloader.FetchAsync(
            request.InitialEffectiveManifestUri,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        EnsurePermitted(manifestResource.RequestedUri, IsPermitted, "manifest request");
        EnsurePermitted(manifestResource.EffectiveUri, IsPermitted, "redirected manifest");
        WidevineDashDownloadPlan plan = WidevineDashManifestParser.Parse(
            manifestResource.Data,
            manifestResource.EffectiveUri,
            IsPermitted,
            request.ObservedLicenseUri);
        EnsurePermitted(plan.LicenseUri, IsPermitted, "license");

        Dictionary<byte[], byte[]> keys = await AcquireKeysAsync(
            plan,
            manifestResource.EffectiveUri,
            IsPermitted,
            cancellationToken).ConfigureAwait(false);
        string? temporaryRoot = null;
        string? jobDirectory = null;
        try
        {
            temporaryRoot = Path.GetFullPath(
                _options.TemporaryRoot ?? Path.Combine(Path.GetTempPath(), "HLSDownloader", "WidevineJobs"));
            Directory.CreateDirectory(temporaryRoot);
            CleanupAbandonedJobs(temporaryRoot, AbandonedJobMaximumAge);
            jobDirectory = Path.Combine(temporaryRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(jobDirectory);
            var observedEffectiveUris = new List<Uri>();
            long stagingLimit = MediaOutputBudget.LimitForPath(
                Path.Combine(jobDirectory, ".staging-budget"),
                _options.MaximumTotalBytes);
            var byteBudget = new DownloadByteBudget(stagingLimit);
            string? videoPath = plan.Video is null ? null : await DownloadTrackAsync(
                plan.Video,
                Path.Combine(jobDirectory, "video"),
                IsPermitted,
                observedEffectiveUris,
                byteBudget,
                cancellationToken).ConfigureAwait(false);
            string? audioPath = plan.Audio is null ? null : await DownloadTrackAsync(
                plan.Audio,
                Path.Combine(jobDirectory, "audio"),
                IsPermitted,
                observedEffectiveUris,
                byteBudget,
                cancellationToken).ConfigureAwait(false);

            WidevineFmp4EncryptionValidator.Validate(plan.Video, videoPath);
            WidevineFmp4EncryptionValidator.Validate(plan.Audio, audioPath);
            string clearOutput = Path.Combine(jobDirectory, plan.OutputFormat == MediaOutputFormat.Mp4 ? "clear.mp4" : "clear.wav");
            long encryptedInputBytes = (videoPath is null ? 0 : new FileInfo(videoPath).Length) +
                (audioPath is null ? 0 : new FileInfo(audioPath).Length);
            MediaOutputBudget.EnsureFits(clearOutput, encryptedInputBytes, _options.MaximumTotalBytes);
            await DecryptAndComposeAsync(
                plan,
                videoPath,
                audioPath,
                keys,
                clearOutput,
                cancellationToken).ConfigureAwait(false);
            ValidateClearOutput(clearOutput, plan.OutputFormat);

            // Final fail-closed policy checkpoint immediately before any clear
            // media enters the caller-selected output location.
            EnsurePermitted(request.RequestedManifestUri, IsPermitted, "final requested manifest");
            EnsurePermitted(manifestResource.EffectiveUri, IsPermitted, "final effective manifest");
            EnsurePermitted(plan.LicenseUri, IsPermitted, "final license");
            if (request.ObservedLicenseUri is { } finalObservedLicenseUri)
                EnsurePermitted(finalObservedLicenseUri, IsPermitted, "final observed license");
            foreach (Uri uri in observedEffectiveUris) EnsurePermitted(uri, IsPermitted, "final segment");

            string outputPath = Path.ChangeExtension(request.OutputBasePath, plan.OutputFormat == MediaOutputFormat.Mp4 ? ".mp4" : ".wav");
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outputPath))!);
            string partialPath = outputPath + ".part";
            File.Delete(partialPath);
            MediaOutputBudget.EnsureFits(partialPath, new FileInfo(clearOutput).Length, _options.MaximumTotalBytes);
            bool published = false;
            try
            {
                File.Copy(clearOutput, partialPath, overwrite: true);
                ValidateClearOutput(partialPath, plan.OutputFormat);

                // Probe the exact bytes that will be atomically published. A
                // successful container scan alone does not prove that ffmpeg
                // can expose the expected playable track layout.
                MediaTrackInfo tracks = await _trackProbe.ProbeAsync(
                    partialPath,
                    TimeSpan.FromMinutes(2),
                    cancellationToken).ConfigureAwait(false);
                ValidateTrackLayout(plan, tracks);
                await ValidateDecodeIntegrityAsync(
                    plan,
                    tracks,
                    partialPath,
                    cancellationToken).ConfigureAwait(false);

                // The source and destination share a directory, so Move is an
                // atomic rename. Do not mark the destination as ours before a
                // successful move: a failed overwrite must preserve an older
                // user file at the same path.
                File.Move(partialPath, outputPath, overwrite: true);
                published = true;
                ValidateClearOutput(outputPath, plan.OutputFormat);

                return new MediaComposeResult(outputPath, plan.OutputFormat, tracks);
            }
            catch
            {
                if (published) TryDeleteFile(outputPath);
                throw;
            }
            finally
            {
                TryDeleteFile(partialPath);
            }
        }
        finally
        {
            foreach ((byte[] id, byte[] value) in keys)
            {
                CryptographicOperations.ZeroMemory(id);
                CryptographicOperations.ZeroMemory(value);
            }
            if (jobDirectory is not null && temporaryRoot is not null)
            {
                TryDeleteJobDirectory(jobDirectory, temporaryRoot);
            }
        }
    }

    private async Task<Dictionary<byte[], byte[]>> AcquireKeysAsync(
        WidevineDashDownloadPlan plan,
        Uri referer,
        Func<Uri, bool> policy,
        CancellationToken cancellationToken)
    {
        using WidevineCredentialLease lease = await _credentialSource.LoadAsync(cancellationToken).ConfigureAwait(false);
        using var client = new WidevineL3Client(lease.Credential);
        var expected = plan.Tracks.Select(track => track.KeyId).ToHashSet(ByteArrayComparer.Instance);
        var result = new Dictionary<byte[], byte[]>(ByteArrayComparer.Instance);
        var psshValues = plan.Tracks.SelectMany(track => track.PsshData)
            .Distinct(ByteArrayComparer.Instance)
            .ToArray();
        try
        {
            foreach (byte[] pssh in psshValues)
            {
                cancellationToken.ThrowIfCancellationRequested();
                using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(pssh, WidevineLicenseType.Offline);
                byte[] response = await _licenseTransport.SendAsync(
                    plan.LicenseUri,
                    challenge.RequestData,
                    referer,
                    policy,
                    cancellationToken).ConfigureAwait(false);
                IReadOnlyList<WidevineContentKey> acquired;
                try
                {
                    acquired = client.ParseLicense(response, challenge);
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(response);
                }
                try
                {
                    foreach (WidevineContentKey key in acquired)
                    {
                        if (!expected.Contains(key.Id))
                            throw new WidevineL3ClientException("The Widevine license returned an unexpected content key.");
                        byte[] value = key.CopyValue();
                        if (result.TryGetValue(key.Id, out byte[]? existing))
                        {
                            bool equal = CryptographicOperations.FixedTimeEquals(existing, value);
                            CryptographicOperations.ZeroMemory(value);
                            if (!equal) throw new WidevineL3ClientException("Conflicting Widevine content keys were returned for one key ID.");
                        }
                        else
                        {
                            result.Add(key.Id.ToArray(), value);
                        }
                    }
                }
                finally
                {
                    foreach (WidevineContentKey key in acquired) key.Dispose();
                }
            }
            if (!expected.All(id => result.ContainsKey(id)))
                throw new WidevineL3ClientException("The Widevine license did not return every selected track key.");
            return result;
        }
        catch
        {
            foreach ((byte[] id, byte[] value) in result)
            {
                CryptographicOperations.ZeroMemory(id);
                CryptographicOperations.ZeroMemory(value);
            }
            throw;
        }
    }

    private async Task<string> DownloadTrackAsync(
        WidevineDashTrackPlan track,
        string directory,
        Func<Uri, bool> policy,
        ICollection<Uri> observedEffectiveUris,
        DownloadByteBudget byteBudget,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(directory);
        WidevineDashSegmentReference[] references = new[] { track.Initialization }.Concat(track.Segments).ToArray();
        string[] paths = new string[references.Length];
        object observedLock = new();
        await Parallel.ForEachAsync(
            Enumerable.Range(0, references.Length),
            new ParallelOptions
            {
                MaxDegreeOfParallelism = _options.MaximumConcurrentRequests,
                CancellationToken = cancellationToken
            },
            async (index, token) =>
            {
                WidevineDashSegmentReference reference = references[index];
                EnsurePermitted(reference.Uri, policy, "segment request");
                HttpResource resource = await _segmentDownloader.FetchAsync(
                    reference.Uri,
                    reference.Referer,
                    reference.RangeOffset,
                    reference.RangeLength,
                    token).ConfigureAwait(false);
                EnsurePermitted(resource.RequestedUri, policy, "segment requested URI");
                EnsurePermitted(resource.EffectiveUri, policy, "segment effective URI");
                if (resource.Data.Length is <= 0 || resource.Data.Length > _options.MaximumResourceBytes)
                    throw new InvalidDataException("A Widevine media object exceeded its bounded size.");
                byteBudget.Add(resource.Data.LongLength);
                lock (observedLock) observedEffectiveUris.Add(resource.EffectiveUri);
                string path = Path.Combine(directory, $"{index:D6}.part");
                string incomplete = path + ".download";
                await File.WriteAllBytesAsync(incomplete, resource.Data, token).ConfigureAwait(false);
                File.Move(incomplete, path, overwrite: true);
                paths[index] = path;
            }).ConfigureAwait(false);

        string combined = Path.Combine(directory, "encrypted.mp4");
        long combinedBytes = paths.Sum(path => new FileInfo(path).Length);
        byteBudget.Add(combinedBytes);
        await using (var output = new FileStream(combined, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1024 * 1024, useAsync: true))
        {
            foreach (string path in paths)
            {
                await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1024 * 1024, useAsync: true);
                await input.CopyToAsync(output, 1024 * 1024, cancellationToken).ConfigureAwait(false);
            }
        }
        return combined;
    }

    private async Task DecryptAndComposeAsync(
        WidevineDashDownloadPlan plan,
        string? videoPath,
        string? audioPath,
        IReadOnlyDictionary<byte[], byte[]> keys,
        string outputPath,
        CancellationToken cancellationToken)
    {
        long outputLimit = MediaOutputBudget.LimitForPath(outputPath, _options.MaximumTotalBytes);
        var arguments = new List<string> { "-y", "-nostdin", "-hide_banner", "-loglevel", "warning" };
        if (plan.OutputFormat == MediaOutputFormat.Wav)
        {
            // Audio-only export decodes the encrypted samples during this
            // compose step. The later PCM gate cannot distinguish silence or
            // partial audio produced with a wrong key, so decode errors must
            // be fatal before the WAV is accepted.
            arguments.AddRange(["-xerror", "-err_detect", "explode"]);
        }
        var redactions = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (plan.Video is { } video)
        {
            if (videoPath is null || !keys.TryGetValue(video.KeyId, out byte[]? videoKey)) throw new InvalidDataException("The selected Widevine video key is missing.");
            string hex = Convert.ToHexString(videoKey).ToLowerInvariant();
            redactions.Add(hex); redactions.Add(hex.ToUpperInvariant());
            arguments.AddRange(["-decryption_key", hex, "-i", videoPath]);
        }
        if (plan.Audio is { } audio)
        {
            if (audioPath is null || !keys.TryGetValue(audio.KeyId, out byte[]? audioKey)) throw new InvalidDataException("The selected Widevine audio key is missing.");
            string hex = Convert.ToHexString(audioKey).ToLowerInvariant();
            redactions.Add(hex); redactions.Add(hex.ToUpperInvariant());
            arguments.AddRange(["-decryption_key", hex, "-i", audioPath]);
        }

        if (plan.OutputFormat == MediaOutputFormat.Mp4)
        {
            arguments.AddRange(["-map", "0:v:0"]);
            arguments.AddRange(plan.Audio is null ? ["-map", "0:a?"] : ["-map", "1:a:0"]);
            arguments.AddRange(["-c", "copy", "-movflags", "+faststart", "-f", "mp4",
                "-fs", outputLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), outputPath]);
        }
        else
        {
            arguments.AddRange(["-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-rf64", "auto", "-f", "wav",
                "-fs", outputLimit.ToString(System.Globalization.CultureInfo.InvariantCulture), outputPath]);
        }

        ExternalToolResult result = await _toolRunner.RunAsync(
            new ExternalToolInvocation(
                _ffmpegPath,
                arguments,
                _options.ComposeTimeout ?? TimeSpan.FromMinutes(30),
                redactions),
            cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            File.Delete(outputPath);
            throw new ExternalToolException($"ffmpeg Widevine compose failed: {result.StandardError}", result.ExitCode);
        }
        MediaOutputBudget.EnsureBelowLimit(outputPath, outputLimit);
    }

    private async Task ValidateDecodeIntegrityAsync(
        WidevineDashDownloadPlan plan,
        MediaTrackInfo tracks,
        string inputPath,
        CancellationToken cancellationToken)
    {
        var arguments = new List<string>
        {
            "-nostdin", "-hide_banner", "-v", "error", "-xerror",
            "-err_detect", "explode", "-abort_on", "empty_output+empty_output_stream",
            "-i", inputPath
        };
        if (plan.OutputFormat == MediaOutputFormat.Mp4)
        {
            arguments.AddRange(["-map", "0:v:0"]);
            if (tracks.HasAudio) arguments.AddRange(["-map", "0:a:0"]);
        }
        else
        {
            arguments.AddRange(["-map", "0:a:0", "-vn"]);
        }
        arguments.AddRange(["-sn", "-dn", "-f", "null", "-"]);

        ExternalToolResult result = await _toolRunner.RunAsync(
            new ExternalToolInvocation(
                _ffmpegPath,
                arguments,
                _options.ComposeTimeout ?? TimeSpan.FromMinutes(30)),
            cancellationToken).ConfigureAwait(false);
        if (result.ExitCode != 0)
        {
            throw new ExternalToolException(
                $"ffmpeg Widevine decode integrity validation failed: {result.StandardError}",
                result.ExitCode);
        }
    }

    private static void EnsurePermitted(Uri uri, Func<Uri, bool> policy, string description)
    {
        if (!policy(uri)) throw new WidevineL3ProviderUnavailableException($"The {description} failed the common Widevine exact-host policy.");
    }

    private static void ValidateClearOutput(string path, MediaOutputFormat format)
    {
        MediaOutputValidator.Validate(path, format);
        if (format == MediaOutputFormat.Mp4)
            WidevineFmp4EncryptionValidator.ValidateClearOutput(path);
    }

    private static void ValidateTrackLayout(WidevineDashDownloadPlan plan, MediaTrackInfo tracks)
    {
        bool valid = plan.OutputFormat switch
        {
            MediaOutputFormat.Mp4 => plan.Video is not null && tracks.HasVideo &&
                (plan.Audio is null || tracks.HasAudio),
            MediaOutputFormat.Wav => plan.Video is null && plan.Audio is not null &&
                !tracks.HasVideo && tracks.HasAudio,
            _ => false
        };
        if (!valid)
            throw new InvalidDataException("The Widevine output track layout is invalid.");
    }

    private static void TryDeleteFile(string path)
    {
        try { File.Delete(path); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static void CleanupAbandonedJobs(string temporaryRoot, TimeSpan olderThan)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(temporaryRoot);
        if (olderThan < TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(olderThan));
        string root = Path.GetFullPath(temporaryRoot);
        var rootInfo = new DirectoryInfo(root);
        rootInfo.Refresh();
        if (!rootInfo.Exists) return;
        if ((rootInfo.Attributes & FileAttributes.ReparsePoint) != 0 || rootInfo.LinkTarget is not null)
            throw new InvalidDataException("The Widevine temporary root cannot be a reparse point or symbolic link.");

        DateTime threshold = DateTime.UtcNow - olderThan;
        foreach (string candidate in Directory.EnumerateDirectories(root, "*", SearchOption.TopDirectoryOnly))
        {
            try
            {
                var info = new DirectoryInfo(candidate);
                info.Refresh();
                if (!info.Exists ||
                    !IsSafeJobDirectory(root, info.FullName, info.Attributes, info.LinkTarget is not null) ||
                    info.LastWriteTimeUtc >= threshold)
                {
                    continue;
                }
                TryDeleteJobDirectory(info.FullName, root);
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    internal static bool IsSafeJobDirectory(
        string temporaryRoot,
        string candidate,
        FileAttributes attributes,
        bool hasLinkTarget)
    {
        try
        {
            string root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(temporaryRoot));
            string full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(candidate));
            string? parent = Path.GetDirectoryName(full);
            StringComparison comparison = OperatingSystem.IsWindows()
                ? StringComparison.OrdinalIgnoreCase
                : StringComparison.Ordinal;
            return parent is not null &&
                string.Equals(Path.TrimEndingDirectorySeparator(parent), root, comparison) &&
                Guid.TryParseExact(Path.GetFileName(full), "N", out _) &&
                (attributes & FileAttributes.Directory) != 0 &&
                (attributes & FileAttributes.ReparsePoint) == 0 &&
                !hasLinkTarget;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            return false;
        }
    }

    private static void TryDeleteJobDirectory(string path, string temporaryRoot)
    {
        try
        {
            var info = new DirectoryInfo(Path.GetFullPath(path));
            info.Refresh();
            if (info.Exists &&
                IsSafeJobDirectory(temporaryRoot, info.FullName, info.Attributes, info.LinkTarget is not null))
            {
                Directory.Delete(info.FullName, recursive: true);
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private sealed class ByteArrayComparer : IEqualityComparer<byte[]>
    {
        public static ByteArrayComparer Instance { get; } = new();
        public bool Equals(byte[]? left, byte[]? right) => ReferenceEquals(left, right) || left is not null && right is not null && left.AsSpan().SequenceEqual(right);
        public int GetHashCode(byte[] value)
        {
            var hash = new HashCode();
            foreach (byte item in value) hash.Add(item);
            return hash.ToHashCode();
        }
    }

    private sealed class DownloadByteBudget(long maximumBytes)
    {
        private long _usedBytes;
        public void Add(long count)
        {
            long updated = Interlocked.Add(ref _usedBytes, count);
            if (count <= 0 || updated < 0 || updated > maximumBytes)
                throw new InvalidDataException("The Widevine media download exceeded its total byte limit.");
        }
    }
}
