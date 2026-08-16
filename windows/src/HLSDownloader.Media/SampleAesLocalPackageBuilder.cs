using System.Security.Cryptography;
using System.Text;

namespace HLSDownloader.Media;

public sealed record SampleAesKey(byte[] Value, string? InitializationVectorHex = null)
{
    public byte[] Value { get; init; } = Value is { Length: 16 }
        ? Value.ToArray()
        : throw new ArgumentException("An identity SAMPLE-AES key must contain exactly 16 bytes.", nameof(Value));
}

public sealed record SampleAesSegment(string SourcePath, double DurationSeconds, SampleAesKey? Key);

public sealed record SampleAesPlaylistPackage(
    IReadOnlyList<SampleAesSegment> Segments,
    long MediaSequence = 0,
    string? InitializationSegmentPath = null);

public sealed class ProtectedPlaylistLease : IAsyncDisposable
{
    private int _disposed;

    internal ProtectedPlaylistLease(string directoryPath, string playlistPath, IReadOnlyCollection<string> redactedValues)
    {
        DirectoryPath = directoryPath;
        PlaylistPath = playlistPath;
        RedactedValues = redactedValues;
    }

    public string DirectoryPath { get; }

    public string PlaylistPath { get; }

    public IReadOnlyCollection<string> RedactedValues { get; }

    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            TryDeleteDirectory(DirectoryPath);
        }

        return ValueTask.CompletedTask;
    }

    internal static void TryDeleteDirectory(string path)
    {
        try
        {
            if (Directory.Exists(path))
            {
                Directory.Delete(path, recursive: true);
            }
        }
        catch (IOException)
        {
            // A subsequent startup cleanup can retry an in-use directory.
        }
        catch (UnauthorizedAccessException)
        {
            // A subsequent startup cleanup can retry after the handle is released.
        }
    }
}

public sealed class SampleAesLocalPackageBuilder
{
    private static readonly HashSet<string> AllowedSegmentExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".ts", ".m4s", ".mp4", ".aac", ".ac3", ".ec3"
    };

    private readonly string _jobRoot;

    public SampleAesLocalPackageBuilder(string? jobRoot = null)
    {
        _jobRoot = Path.GetFullPath(jobRoot ?? Path.Combine(Path.GetTempPath(), "HLSDownloader", "SampleAesJobs"));
    }

    public async Task<ProtectedPlaylistLease> BuildAsync(
        SampleAesPlaylistPackage package,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(package);
        if (package.Segments.Count == 0)
        {
            throw new ArgumentException("At least one SAMPLE-AES segment is required.", nameof(package));
        }

        Directory.CreateDirectory(_jobRoot);
        string directory = Path.Combine(_jobRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            ValidateFmp4KeyRotation(package);
            var playlist = new StringBuilder("#EXTM3U\n#EXT-X-VERSION:7\n");
            double maximumDuration = package.Segments.Max(segment => segment.DurationSeconds);
            playlist.Append("#EXT-X-TARGETDURATION:").Append(Math.Max(1, (int)Math.Ceiling(maximumDuration))).Append('\n');
            playlist.Append("#EXT-X-MEDIA-SEQUENCE:").Append(package.MediaSequence).Append('\n');

            var keyFiles = new Dictionary<string, string>(StringComparer.Ordinal);
            SampleAesKey? currentKey = null;
            if (package.InitializationSegmentPath is not null)
            {
                SampleAesKey? mapKey = package.Segments[0].Key;
                AppendKeyIfChanged(playlist, directory, mapKey, ref currentKey, keyFiles);
                string mapLeaf = await CopyProtectedResourceAsync(package.InitializationSegmentPath, directory, "init", cancellationToken).ConfigureAwait(false);
                playlist.Append("#EXT-X-MAP:URI=\"").Append(mapLeaf).Append("\"\n");
            }

            for (int index = 0; index < package.Segments.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                SampleAesSegment segment = package.Segments[index];
                if (segment.DurationSeconds <= 0 || double.IsNaN(segment.DurationSeconds) || double.IsInfinity(segment.DurationSeconds))
                {
                    throw new InvalidDataException("SAMPLE-AES segment durations must be finite and positive.");
                }

                AppendKeyIfChanged(playlist, directory, segment.Key, ref currentKey, keyFiles);
                string leaf = await CopyProtectedResourceAsync(segment.SourcePath, directory, $"segment-{index:D6}", cancellationToken).ConfigureAwait(false);
                playlist.Append("#EXTINF:").Append(segment.DurationSeconds.ToString("0.######", System.Globalization.CultureInfo.InvariantCulture)).Append(",\n");
                playlist.Append(leaf).Append('\n');
            }

            playlist.Append("#EXT-X-ENDLIST\n");
            string playlistPath = Path.Combine(directory, "local.m3u8");
            await File.WriteAllTextAsync(playlistPath, playlist.ToString(), new UTF8Encoding(false), cancellationToken).ConfigureAwait(false);
            IReadOnlyCollection<string> redactions = package.Segments
                .Where(segment => segment.Key is not null)
                .SelectMany(segment => new[]
                {
                    Convert.ToHexString(segment.Key!.Value),
                    Convert.ToHexString(segment.Key!.Value).ToLowerInvariant()
                })
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .ToArray();
            return new ProtectedPlaylistLease(directory, playlistPath, redactions);
        }
        catch
        {
            ProtectedPlaylistLease.TryDeleteDirectory(directory);
            throw;
        }
    }

    public void CleanupAbandonedJobs(TimeSpan olderThan)
    {
        if (olderThan < TimeSpan.Zero || !Directory.Exists(_jobRoot))
        {
            return;
        }

        DateTime threshold = DateTime.UtcNow - olderThan;
        foreach (string directory in Directory.EnumerateDirectories(_jobRoot))
        {
            string leaf = Path.GetFileName(directory);
            if (Guid.TryParseExact(leaf, "N", out _) && Directory.GetLastWriteTimeUtc(directory) < threshold)
            {
                ProtectedPlaylistLease.TryDeleteDirectory(directory);
            }
        }
    }

    private static async Task<string> CopyProtectedResourceAsync(
        string sourcePath,
        string destinationDirectory,
        string destinationStem,
        CancellationToken cancellationToken)
    {
        string extension = Path.GetExtension(sourcePath);
        if (!AllowedSegmentExtensions.Contains(extension))
        {
            throw new InvalidDataException($"Unsupported local media extension: {extension}");
        }

        string destinationLeaf = destinationStem + extension.ToLowerInvariant();
        string destination = Path.Combine(destinationDirectory, destinationLeaf);
        await using FileStream source = new(sourcePath, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await using FileStream target = new(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan);
        await source.CopyToAsync(target, cancellationToken).ConfigureAwait(false);
        return destinationLeaf;
    }

    private static void AppendKeyIfChanged(
        StringBuilder playlist,
        string directory,
        SampleAesKey? key,
        ref SampleAesKey? current,
        IDictionary<string, string> keyFiles)
    {
        if (KeysEqual(key, current))
        {
            return;
        }

        current = key;
        if (key is null)
        {
            playlist.Append("#EXT-X-KEY:METHOD=NONE\n");
            return;
        }

        string fingerprint = Convert.ToHexString(SHA256.HashData(key.Value));
        if (!keyFiles.TryGetValue(fingerprint, out string? leaf))
        {
            leaf = $"key-{keyFiles.Count:D3}.key";
            File.WriteAllBytes(Path.Combine(directory, leaf), key.Value);
            keyFiles[fingerprint] = leaf;
        }

        playlist.Append("#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"identity\",URI=\"").Append(leaf).Append('"');
        if (!string.IsNullOrWhiteSpace(key.InitializationVectorHex))
        {
            playlist.Append(",IV=").Append(NormalizeIv(key.InitializationVectorHex));
        }

        playlist.Append('\n');
    }

    private static bool KeysEqual(SampleAesKey? left, SampleAesKey? right) =>
        ReferenceEquals(left, right) ||
        (left is not null && right is not null &&
         left.Value.AsSpan().SequenceEqual(right.Value) &&
         string.Equals(NormalizeIv(left.InitializationVectorHex), NormalizeIv(right.InitializationVectorHex), StringComparison.Ordinal));

    private static string NormalizeIv(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return string.Empty;
        }

        string hex = value.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? value[2..] : value;
        if (hex.Length != 32 || hex.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new InvalidDataException("A SAMPLE-AES IV must contain exactly 16 hexadecimal bytes.");
        }

        return "0x" + hex.ToUpperInvariant();
    }

    private static void ValidateFmp4KeyRotation(SampleAesPlaylistPackage package)
    {
        if (package.InitializationSegmentPath is null)
        {
            return;
        }

        int distinctKeys = package.Segments
            .Where(segment => segment.Key is not null)
            .Select(segment => Convert.ToHexString(segment.Key!.Value) + NormalizeIv(segment.Key.InitializationVectorHex))
            .Distinct(StringComparer.Ordinal)
            .Count();
        if (distinctKeys > 1)
        {
            throw new NotSupportedException("identity SAMPLE-AES key rotation for fMP4 is not supported by this first Windows implementation.");
        }
    }
}

public sealed class SampleAesMediaComposer(SampleAesLocalPackageBuilder packageBuilder, IMediaComposer composer)
{
    public async Task<MediaComposeResult> ComposeAsync(
        SampleAesPlaylistPackage package,
        string outputBasePath,
        TimeSpan? timeout = null,
        CancellationToken cancellationToken = default)
    {
        await using ProtectedPlaylistLease lease = await packageBuilder.BuildAsync(package, cancellationToken).ConfigureAwait(false);
        return await composer.ComposeAsync(
            new MediaComposeRequest(lease.PlaylistPath, outputBasePath, timeout, lease.RedactedValues),
            cancellationToken).ConfigureAwait(false);
    }
}
