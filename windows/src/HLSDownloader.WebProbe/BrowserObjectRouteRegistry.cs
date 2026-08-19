namespace HLSDownloader.WebProbe;

/// <summary>
/// Keeps the WebView frame that owns an opaque browser-object identifier.
/// A missing route means that the object belongs to the top-level document.
/// </summary>
public sealed class BrowserObjectRouteRegistry<TTarget> where TTarget : class
{
    private readonly object _gate = new();
    private readonly Dictionary<string, TTarget> _routes = new(StringComparer.Ordinal);

    public void Set(string objectId, TTarget? target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(objectId);
        lock (_gate)
        {
            if (target is null)
            {
                _routes.Remove(objectId);
            }
            else
            {
                _routes[objectId] = target;
            }
        }
    }

    public bool TryGet(string objectId, out TTarget? target)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(objectId);
        lock (_gate)
        {
            return _routes.TryGetValue(objectId, out target);
        }
    }

    public IReadOnlyList<string> RemoveTarget(TTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        lock (_gate)
        {
            var removed = _routes
                .Where(entry => ReferenceEquals(entry.Value, target))
                .Select(entry => entry.Key)
                .ToArray();
            foreach (var objectId in removed)
            {
                _routes.Remove(objectId);
            }

            return removed;
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _routes.Clear();
        }
    }
}
