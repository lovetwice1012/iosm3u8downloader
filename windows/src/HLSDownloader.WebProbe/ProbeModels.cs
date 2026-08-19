using System.Security.Cryptography;
using System.Text;
using System.Diagnostics;

namespace HLSDownloader.WebProbe;

public enum ProbeSignalKind
{
    Manifest,
    MediaElement,
    Network,
    EncryptedMedia,
    EncryptedMediaLifecycle,
    BrowserBlob,
    MediaSource
}

public enum ProbeMediaContainer
{
    Unknown,
    Hls,
    Dash,
    Mp4,
    QuickTime,
    MpegTs,
    WebM,
    M4a,
    Mp3,
    Aac,
    Ogg,
    Opus
}

public enum ProbeEmeLifecyclePhase
{
    GenerateRequestStarted,
    GenerateRequestSucceeded,
    UpdateSucceeded
}

[DebuggerDisplay("ProbeSignal(<redacted>)")]
public sealed record ProbeSignal(
    ProbeSignalKind Kind,
    Uri Url,
    string Source,
    string? MimeType = null,
    Uri? ThumbnailUrl = null,
    string? Title = null,
    string? KeySystem = null,
    long Sequence = 0,
    Uri? PageUrl = null,
    ProbeEmeLifecyclePhase? EmePhase = null,
    string? BrowserObjectId = null,
    long? ByteLength = null,
    ProbeMediaContainer Container = ProbeMediaContainer.Unknown)
{
    public bool IsDash => Url.AbsolutePath.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)
        || MimeType?.Contains("dash", StringComparison.OrdinalIgnoreCase) == true;

    public bool IsHls => Url.AbsolutePath.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)
        || MimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true;

    public bool IsManifest => IsDash || IsHls;

    public bool IsBrowserBlob => Kind == ProbeSignalKind.BrowserBlob;

    public bool IsMediaSource => Kind == ProbeSignalKind.MediaSource;

    public bool IsBrowserGenerated => IsBrowserBlob || IsMediaSource;

    public override string ToString() => "ProbeSignal(<redacted>)";
}

public sealed class ProbeSession
{
    private readonly HashSet<string> _deduplicationKeys = new(StringComparer.Ordinal);
    private int _acceptedCount;

    public ProbeSession(int maximumSignals = 2_000)
    {
        if (maximumSignals is < 1 or > 20_000)
        {
            throw new ArgumentOutOfRangeException(nameof(maximumSignals));
        }

        MaximumSignals = maximumSignals;
        Nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    }

    public string Nonce { get; }

    public int MaximumSignals { get; }

    public int AcceptedCount => Volatile.Read(ref _acceptedCount);

    internal bool TryAccept(ProbeSignal signal)
    {
        if (AcceptedCount >= MaximumSignals)
        {
            return false;
        }

        var key = string.Concat(
            signal.Kind,
            "\n",
            signal.Url.AbsoluteUri,
            "\n",
            signal.KeySystem,
            "\n",
            signal.EmePhase,
            "\n",
            signal.BrowserObjectId,
            signal.Kind == ProbeSignalKind.EncryptedMediaLifecycle
                ? string.Concat("\n", signal.Sequence)
                : string.Empty);
        lock (_deduplicationKeys)
        {
            if (_acceptedCount >= MaximumSignals || !_deduplicationKeys.Add(key))
            {
                return false;
            }

            _acceptedCount++;
            return true;
        }
    }

    internal bool MatchesNonce(string? candidate)
    {
        if (candidate is null || candidate.Length != Nonce.Length)
        {
            return false;
        }

        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(candidate),
            Encoding.UTF8.GetBytes(Nonce));
    }
}

[System.Diagnostics.DebuggerDisplay("WidevineLicenseAssociation(<redacted>)")]
public sealed record WidevineLicenseAssociation(Uri ManifestUri, Uri LicenseUri)
{
    public override string ToString() => "WidevineLicenseAssociation(<redacted>)";
}

/// <summary>
/// Correlates a single WebView2 playback window's EME lifecycle with native
/// response metadata. It never receives request/response bodies or headers.
/// </summary>
public sealed class WidevineLicenseObservationTracker
{
    public static readonly TimeSpan DefaultObservationWindow = TimeSpan.FromSeconds(30);

    private readonly object _gate = new();
    private readonly HashSet<string> _allowedHosts;
    private readonly TimeSpan _observationWindow;
    private readonly HashSet<Uri> _manifestUris = [];
    private readonly HashSet<Uri> _successfulPostUris = [];
    private DateTimeOffset? _generateStartedAt;
    private bool _generateSucceeded;
    private bool _cycleAmbiguous;
    private bool _cycleClosed = true;

    public WidevineLicenseObservationTracker(
        IEnumerable<string> allowedHosts,
        TimeSpan? observationWindow = null)
    {
        ArgumentNullException.ThrowIfNull(allowedHosts);
        _allowedHosts = new HashSet<string>(
            allowedHosts
                .Where(host => !string.IsNullOrWhiteSpace(host))
                .Select(host => host.Trim()),
            StringComparer.OrdinalIgnoreCase);
        if (_allowedHosts.Count == 0)
        {
            throw new ArgumentException("At least one allowed host is required.", nameof(allowedHosts));
        }

        _observationWindow = observationWindow ?? DefaultObservationWindow;
        if (_observationWindow <= TimeSpan.Zero || _observationWindow > TimeSpan.FromMinutes(5))
        {
            throw new ArgumentOutOfRangeException(nameof(observationWindow));
        }
    }

    public bool ObserveManifest(Uri manifestUri)
    {
        ArgumentNullException.ThrowIfNull(manifestUri);
        if (!IsAllowedHttpsUri(manifestUri))
        {
            return false;
        }

        lock (_gate)
        {
            // Two distinct manifests are sufficient to make this window ambiguous;
            // retaining any additional URLs would only increase memory exposure.
            if (_manifestUris.Count < 2 || _manifestUris.Contains(manifestUri))
            {
                _manifestUris.Add(manifestUri);
            }

            return true;
        }
    }

    public bool ObserveSuccessfulPost(
        Uri requestUri,
        string? method,
        int statusCode,
        DateTimeOffset observedAt)
    {
        ArgumentNullException.ThrowIfNull(requestUri);
        if (!string.Equals(method, "POST", StringComparison.OrdinalIgnoreCase)
            || statusCode is < 200 or >= 300
            || !IsAllowedHttpsUri(requestUri))
        {
            return false;
        }

        lock (_gate)
        {
            if (!IsActiveAt(observedAt))
            {
                return false;
            }

            if (_successfulPostUris.Count < 2 || _successfulPostUris.Contains(requestUri))
            {
                _successfulPostUris.Add(requestUri);
            }

            return true;
        }
    }

    public WidevineLicenseAssociation? ObserveLifecycle(
        ProbeEmeLifecyclePhase phase,
        DateTimeOffset observedAt)
    {
        lock (_gate)
        {
            switch (phase)
            {
                case ProbeEmeLifecyclePhase.GenerateRequestStarted:
                    if (!_cycleClosed && IsActiveAt(observedAt))
                    {
                        _cycleAmbiguous = true;
                        return null;
                    }

                    _generateStartedAt = observedAt;
                    _generateSucceeded = false;
                    _cycleAmbiguous = false;
                    _cycleClosed = false;
                    _successfulPostUris.Clear();
                    return null;

                case ProbeEmeLifecyclePhase.GenerateRequestSucceeded:
                    if (!IsActiveAt(observedAt))
                    {
                        return null;
                    }

                    _generateSucceeded = true;
                    return null;

                case ProbeEmeLifecyclePhase.UpdateSucceeded:
                    if (!IsActiveAt(observedAt))
                    {
                        _cycleClosed = true;
                        return null;
                    }

                    _cycleClosed = true;
                    if (!_generateSucceeded
                        || _cycleAmbiguous
                        || _manifestUris.Count != 1
                        || _successfulPostUris.Count != 1)
                    {
                        return null;
                    }

                    return new WidevineLicenseAssociation(
                        _manifestUris.Single(),
                        _successfulPostUris.Single());

                default:
                    return null;
            }
        }
    }

    private bool IsActiveAt(DateTimeOffset observedAt)
    {
        if (_cycleClosed || _generateStartedAt is not { } startedAt)
        {
            return false;
        }

        var elapsed = observedAt - startedAt;
        if (elapsed < TimeSpan.Zero || elapsed > _observationWindow)
        {
            _cycleClosed = true;
            return false;
        }

        return true;
    }

    private bool IsAllowedHttpsUri(Uri uri)
        => uri.IsAbsoluteUri
           && string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
           && string.IsNullOrEmpty(uri.UserInfo)
           && _allowedHosts.Contains(uri.IdnHost);
}
