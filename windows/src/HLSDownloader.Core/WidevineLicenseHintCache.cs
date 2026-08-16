namespace HLSDownloader.Core;

[System.Diagnostics.DebuggerDisplay("ObservedWidevineLicenseHint(<redacted>)")]
public sealed record ObservedWidevineLicenseHint(
    Uri LicenseUri,
    BrowserCookieSnapshot CookieSnapshot)
{
    public override string ToString() => "ObservedWidevineLicenseHint(<redacted>)";
}

/// <summary>
/// Bounded, in-memory-only cache for playback-observed license endpoints.
/// Taking an entry removes it before the caller performs network I/O.
/// </summary>
public sealed class WidevineLicenseHintCache
{
    public static readonly TimeSpan DefaultLifetime = TimeSpan.FromMinutes(5);

    private readonly object _gate = new();
    private readonly Dictionary<Uri, Entry> _entries = [];
    private readonly TimeSpan _lifetime;
    private readonly int _capacity;

    public WidevineLicenseHintCache(TimeSpan? lifetime = null, int capacity = 128)
    {
        _lifetime = lifetime ?? DefaultLifetime;
        if (_lifetime <= TimeSpan.Zero || _lifetime > TimeSpan.FromHours(1))
        {
            throw new ArgumentOutOfRangeException(nameof(lifetime));
        }

        if (capacity is < 1 or > 2_000)
        {
            throw new ArgumentOutOfRangeException(nameof(capacity));
        }

        _capacity = capacity;
    }

    public int Count
    {
        get
        {
            lock (_gate)
            {
                return _entries.Count;
            }
        }
    }

    public DateTimeOffset? NextExpiry
    {
        get
        {
            lock (_gate)
            {
                return _entries.Count == 0
                    ? null
                    : _entries.Values.Min(entry => entry.CapturedAt) + _lifetime;
            }
        }
    }

    public bool Remember(
        Uri manifestUri,
        Uri licenseUri,
        BrowserCookieSnapshot cookieSnapshot,
        DateTimeOffset observedAt)
    {
        ArgumentNullException.ThrowIfNull(manifestUri);
        ArgumentNullException.ThrowIfNull(licenseUri);
        ArgumentNullException.ThrowIfNull(cookieSnapshot);
        if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(manifestUri)
            || !WidevineDownloadPolicy.IsDownloadableWidevineDomain(licenseUri))
        {
            return false;
        }

        lock (_gate)
        {
            PurgeExpiredLocked(observedAt);
            if (!_entries.ContainsKey(manifestUri) && _entries.Count >= _capacity)
            {
                var oldest = _entries.MinBy(pair => pair.Value.CapturedAt).Key;
                _entries.Remove(oldest);
            }

            _entries[manifestUri] = new Entry(
                new ObservedWidevineLicenseHint(licenseUri, cookieSnapshot),
                observedAt);
            return true;
        }
    }

    public bool TryTake(
        Uri manifestUri,
        DateTimeOffset observedAt,
        out ObservedWidevineLicenseHint? hint)
    {
        ArgumentNullException.ThrowIfNull(manifestUri);
        lock (_gate)
        {
            hint = null;
            if (!_entries.Remove(manifestUri, out var entry))
            {
                return false;
            }

            var age = observedAt - entry.CapturedAt;
            if (age < TimeSpan.Zero || age >= _lifetime)
            {
                return false;
            }

            hint = entry.Hint;
            return true;
        }
    }

    public void PurgeExpired(DateTimeOffset observedAt)
    {
        lock (_gate)
        {
            PurgeExpiredLocked(observedAt);
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _entries.Clear();
        }
    }

    private void PurgeExpiredLocked(DateTimeOffset observedAt)
    {
        foreach (var key in _entries
                     .Where(pair => observedAt - pair.Value.CapturedAt >= _lifetime)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            _entries.Remove(key);
        }
    }

    private sealed record Entry(
        ObservedWidevineLicenseHint Hint,
        DateTimeOffset CapturedAt);
}
