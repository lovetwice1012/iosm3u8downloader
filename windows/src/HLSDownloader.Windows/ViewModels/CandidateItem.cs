using HLSDownloader.Core;
using Microsoft.UI.Xaml.Media.Imaging;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace HLSDownloader.Windows.ViewModels;

public sealed class CandidateItem : INotifyPropertyChanged
{
    private BitmapImage? _thumbnail;
    private bool _canDownload;
    private string _downloadHint;

    public CandidateItem(MediaCandidate candidate, bool canDownload, string downloadHint)
    {
        Candidate = candidate;
        _canDownload = canDownload;
        _downloadHint = downloadHint;
    }

    public MediaCandidate Candidate { get; private set; }

    public string Url
    {
        get
        {
            var pathDepth = Candidate.Uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Length;
            var extension = Path.GetExtension(Candidate.Uri.AbsolutePath);
            var query = string.IsNullOrEmpty(Candidate.Uri.Query) ? string.Empty : " • queryあり";
            var port = Candidate.Uri.IsDefaultPort ? string.Empty : $":{Candidate.Uri.Port}";
            return $"{Candidate.Uri.Scheme}://{Candidate.Uri.IdnHost}{port} • path {pathDepth}階層"
                + (string.IsNullOrEmpty(extension) ? string.Empty : $" • {extension.ToLowerInvariant()}")
                + query;
        }
    }

    public string Kind => Candidate.Kind switch
    {
        MediaCandidateKind.Hls => "HLS / m3u8",
        MediaCandidateKind.WidevineDash => "MPEG-DASH / Widevine",
        _ => "動画"
    };

    public string Origin => Candidate.Origin switch
    {
        MediaCandidateOrigin.Direct => "直接URL",
        MediaCandidateOrigin.Video => "videoタグ",
        MediaCandidateOrigin.Source => "sourceタグ",
        MediaCandidateOrigin.DataAttribute => "data属性",
        MediaCandidateOrigin.InlineScript => "ページ内スクリプト",
        MediaCandidateOrigin.Iframe => $"iframe（深さ {Candidate.IframeDepth}）",
        _ => "ページ解析"
    };

    public string? Title => Candidate.Title;

    public BitmapImage? Thumbnail
    {
        get => _thumbnail;
        set
        {
            if (ReferenceEquals(_thumbnail, value))
            {
                return;
            }

            _thumbnail = value;
            OnPropertyChanged();
        }
    }

    public bool HasThumbnail => Thumbnail is not null;

    public bool CanDownload => _canDownload;

    public string DownloadHint => _downloadHint;

    public void UpdateDownloadCapability(bool canDownload, string downloadHint)
    {
        if (_canDownload != canDownload)
        {
            _canDownload = canDownload;
            OnPropertyChanged(nameof(CanDownload));
        }

        if (!string.Equals(_downloadHint, downloadHint, StringComparison.Ordinal))
        {
            _downloadHint = downloadHint;
            OnPropertyChanged(nameof(DownloadHint));
        }
    }

    public void UpdateCandidate(MediaCandidate candidate)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        if (Uri.Compare(
                Candidate.Uri,
                candidate.Uri,
                UriComponents.HttpRequestUrl,
                UriFormat.SafeUnescaped,
                StringComparison.OrdinalIgnoreCase) != 0)
        {
            throw new ArgumentException("Candidate URI cannot be changed in place.", nameof(candidate));
        }

        Candidate = candidate;
        OnPropertyChanged(nameof(Candidate));
        OnPropertyChanged(nameof(Url));
        OnPropertyChanged(nameof(Kind));
        OnPropertyChanged(nameof(Origin));
        OnPropertyChanged(nameof(Title));
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
