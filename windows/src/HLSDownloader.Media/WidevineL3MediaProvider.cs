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
        string? jobDirectory = null;
        try
        {
            string temporaryRoot = Path.GetFullPath(
                _options.TemporaryRoot ?? Path.Combine(Path.GetTempPath(), "HLSDownloader", "WidevineJobs"));
            Directory.CreateDirectory(temporaryRoot);
            jobDirectory = Path.Combine(temporaryRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(jobDirectory);
            var observedEffectiveUris = new List<Uri>();
            var byteBudget = new DownloadByteBudget(_options.MaximumTotalBytes);
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
            await DecryptAndComposeAsync(
                plan,
                videoPath,
                audioPath,
                keys,
                clearOutput,
                cancellationToken).ConfigureAwait(false);
            MediaOutputValidator.Validate(clearOutput, plan.OutputFormat);

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
            try
            {
                File.Copy(clearOutput, partialPath, overwrite: true);
                MediaOutputValidator.Validate(partialPath, plan.OutputFormat);
                File.Move(partialPath, outputPath, overwrite: true);
                MediaOutputValidator.Validate(outputPath, plan.OutputFormat);
            }
            finally
            {
                File.Delete(partialPath);
            }

            MediaTrackInfo tracks = await _trackProbe.ProbeAsync(
                outputPath,
                TimeSpan.FromMinutes(2),
                cancellationToken).ConfigureAwait(false);
            if ((plan.OutputFormat == MediaOutputFormat.Mp4 && !tracks.HasVideo) ||
                (plan.OutputFormat == MediaOutputFormat.Wav && (tracks.HasVideo || !tracks.HasAudio)))
            {
                File.Delete(outputPath);
                throw new InvalidDataException("The Widevine output track layout is invalid.");
            }
            return new MediaComposeResult(outputPath, plan.OutputFormat, tracks);
        }
        finally
        {
            foreach ((byte[] id, byte[] value) in keys)
            {
                CryptographicOperations.ZeroMemory(id);
                CryptographicOperations.ZeroMemory(value);
            }
            if (jobDirectory is not null)
            {
                TryDeleteDirectory(jobDirectory);
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
        var arguments = new List<string> { "-y", "-nostdin", "-hide_banner", "-loglevel", "warning" };
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
            arguments.AddRange(["-c", "copy", "-movflags", "+faststart", "-f", "mp4", outputPath]);
        }
        else
        {
            arguments.AddRange(["-map", "0:a:0", "-vn", "-c:a", "pcm_s16le", "-rf64", "auto", "-f", "wav", outputPath]);
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
    }

    private static void EnsurePermitted(Uri uri, Func<Uri, bool> policy, string description)
    {
        if (!policy(uri)) throw new WidevineL3ProviderUnavailableException($"The {description} failed the common Widevine exact-host policy.");
    }

    private static void TryDeleteDirectory(string path)
    {
        try
        {
            string full = Path.GetFullPath(path);
            if (Directory.Exists(full) && Guid.TryParseExact(Path.GetFileName(full), "N", out _)) Directory.Delete(full, recursive: true);
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
