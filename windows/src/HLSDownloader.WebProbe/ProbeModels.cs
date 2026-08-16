using System.Security.Cryptography;
using System.Text;

namespace HLSDownloader.WebProbe;

public enum ProbeSignalKind
{
    Manifest,
    MediaElement,
    Network,
    EncryptedMedia
}

public sealed record ProbeSignal(
    ProbeSignalKind Kind,
    Uri Url,
    string Source,
    string? MimeType = null,
    Uri? ThumbnailUrl = null,
    string? Title = null,
    string? KeySystem = null,
    long Sequence = 0,
    Uri? PageUrl = null)
{
    public bool IsDash => Url.AbsolutePath.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)
        || MimeType?.Contains("dash", StringComparison.OrdinalIgnoreCase) == true;

    public bool IsHls => Url.AbsolutePath.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)
        || MimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true;

    public bool IsManifest => IsDash || IsHls;
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

        var key = string.Concat(signal.Kind, "\n", signal.Url.AbsoluteUri, "\n", signal.KeySystem);
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
