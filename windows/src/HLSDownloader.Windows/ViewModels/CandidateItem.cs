using HLSDownloader.Core;
using Microsoft.UI.Xaml.Media.Imaging;
using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace HLSDownloader.Windows.ViewModels;

public sealed class CandidateItem : INotifyPropertyChanged
{
    private BitmapImage? _thumbnail;

    public CandidateItem(MediaCandidate candidate, bool canDownload, string downloadHint)
    {
        Candidate = candidate;
        CanDownload = canDownload;
        DownloadHint = downloadHint;
    }

    public MediaCandidate Candidate { get; }

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

    public bool CanDownload { get; }

    public string DownloadHint { get; }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
