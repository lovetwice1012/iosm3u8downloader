namespace HLSDownloader.Media;

public enum MediaOutputFormat
{
    Mp4,
    Wav,
    WebM
}

public sealed record MediaTrackInfo(
    bool HasVideo,
    bool HasAudio,
    int? AudioSampleRate = null,
    int? AudioChannels = null)
{
    public MediaOutputFormat OutputFormat => HasVideo ? MediaOutputFormat.Mp4 : MediaOutputFormat.Wav;
}

public sealed record MediaComposeRequest(
    string InputPath,
    string OutputBasePath,
    TimeSpan? Timeout = null,
    IReadOnlyCollection<string>? RedactedValues = null,
    string? SecondaryAudioInputPath = null,
    long? MaximumOutputBytes = null);

public sealed record MediaComposeResult(
    string OutputPath,
    MediaOutputFormat OutputFormat,
    MediaTrackInfo Tracks);

public interface IMediaTrackProbe
{
    Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default);
}

public interface IMediaComposer
{
    Task<MediaComposeResult> ComposeAsync(MediaComposeRequest request, CancellationToken cancellationToken = default);
}

[System.Diagnostics.DebuggerDisplay("WidevineL3DownloadRequest(<redacted>)")]
public sealed record WidevineL3DownloadRequest(
    Uri RequestedManifestUri,
    Uri InitialEffectiveManifestUri,
    string OutputBasePath,
    Func<Uri, bool> IsPermittedManifestUri,
    Uri? ObservedLicenseUri = null)
{
    public override string ToString() => "WidevineL3DownloadRequest(<redacted>)";
}

/// <summary>
/// A short-lived clear WVD buffer. The buffer is copied at construction and
/// zeroed on disposal. Text conversion is always redacted.
/// </summary>
public sealed class WidevineCredentialLease : IDisposable
{
    private byte[]? _credential;

    public WidevineCredentialLease(ReadOnlySpan<byte> credential)
    {
        if (credential.IsEmpty || credential.Length > 256 * 1024)
            throw new ArgumentOutOfRangeException(nameof(credential));
        _credential = credential.ToArray();
    }

    internal ReadOnlySpan<byte> Credential =>
        _credential ?? throw new ObjectDisposedException(nameof(WidevineCredentialLease));

    public void Dispose()
    {
        if (_credential is { } credential)
        {
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(credential);
            _credential = null;
        }
        GC.SuppressFinalize(this);
    }

    public override string ToString() => "WidevineCredentialLease(<redacted>)";
}

/// <summary>
/// Implemented by the UI credential store so Media never knows the on-disk WVD
/// location and never persists clear credential bytes.
/// </summary>
public interface IWidevineCredentialSource
{
    bool IsAvailable { get; }
    Task<WidevineCredentialLease> LoadAsync(CancellationToken cancellationToken = default);
}

/// <summary>
/// Sends one raw SignedMessage challenge. Implementations must not follow
/// redirects and must apply the supplied exact-host policy immediately before
/// transmitting credential-derived data.
/// </summary>
public interface IWidevineRawLicenseTransport
{
    Task<byte[]> SendAsync(
        Uri licenseUri,
        ReadOnlyMemory<byte> challenge,
        Uri? referer,
        Func<Uri, bool> isPermittedUri,
        CancellationToken cancellationToken = default);
}

/// <summary>
/// Optional boundary for an authorized Widevine L3 implementation. Implementations must invoke
/// <see cref="WidevineL3DownloadRequest.IsPermittedManifestUri"/> for the requested manifest and
/// <see cref="WidevineL3DownloadRequest.InitialEffectiveManifestUri"/>, every later effective
/// manifest URI after redirects, and again immediately before producing output.
/// </summary>
public interface IWidevineL3MediaProvider
{
    bool IsConfigured { get; }

    Task<MediaComposeResult> DownloadAndComposeAsync(
        WidevineL3DownloadRequest request,
        CancellationToken cancellationToken = default);
}

public sealed class WidevineL3ProviderUnavailableException(string message) : NotSupportedException(message);
