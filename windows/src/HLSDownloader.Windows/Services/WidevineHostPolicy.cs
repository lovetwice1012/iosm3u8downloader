using System.Runtime.InteropServices;
using HLSDownloader.Core;

namespace HLSDownloader.Windows.Services;

[ComVisible(true)]
[Guid("6AA164B7-3AA9-419A-9333-B4B455F46991")]
[InterfaceType(ComInterfaceType.InterfaceIsIDispatch)]
public interface IWidevineHostPolicy
{
    [DispId(1)]
    bool IsWidevinePlaybackAllowed(string rawPageUrl);
}

[ComVisible(true)]
[Guid("33529F9A-A662-4DB3-B657-C7DCC3F05D8B")]
[ClassInterface(ClassInterfaceType.None)]
public sealed class WidevineHostPolicy : IWidevineHostPolicy
{
    private int _allowedManifestObserved;

    public bool IsWidevinePlaybackAllowed(string rawPageUrl)
        => Volatile.Read(ref _allowedManifestObserved) == 1
           || (Uri.TryCreate(rawPageUrl, UriKind.Absolute, out var uri)
               && WidevineDownloadPolicy.IsDownloadableWidevineDomain(uri));

    public void ObserveManifest(Uri manifestUri)
    {
        if (WidevineDownloadPolicy.IsDownloadableWidevineDomain(manifestUri))
        {
            Interlocked.Exchange(ref _allowedManifestObserved, 1);
        }
    }

    public void Reset() => Interlocked.Exchange(ref _allowedManifestObserved, 0);
}
