using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Media.Core;

namespace HLSDownloader.Windows;

public sealed partial class MediaPlaybackWindow : Window
{
    public MediaPlaybackWindow(Uri source)
    {
        InitializeComponent();
        Player.Source = MediaSource.CreateFromUri(source);
        Closed += OnClosed;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Maximize();
        }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        Player.MediaPlayer?.Pause();
        Player.Source = null;
        Player.MediaPlayer?.Dispose();
    }
}
