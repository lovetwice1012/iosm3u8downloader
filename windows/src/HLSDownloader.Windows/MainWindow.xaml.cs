using System.Collections.ObjectModel;
using System.Diagnostics;
using HLSDownloader.Core;
using HLSDownloader.WebProbe;
using HLSDownloader.Windows.Services;
using HLSDownloader.Windows.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace HLSDownloader.Windows;

public sealed partial class MainWindow : Window
{
    private readonly IMediaWorkflow _workflow;
    private readonly WvdCredentialStore _wvdStore = new();
    private readonly ThumbnailLoader _thumbnailLoader = new();
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly List<PlaybackProbeWindow> _probeWindows = [];
    private readonly List<MediaPlaybackWindow> _mediaWindows = [];
    private CancellationTokenSource? _analysisCancellation;
    private CancellationTokenSource? _downloadCancellation;
    private bool _backgroundRestoreStarted;
    private bool _resumedBackgroundJobActive;
    private string? _completedFilePath;

    public MainWindow()
        : this(new CoreMediaWorkflow())
    {
    }

    internal MainWindow(IMediaWorkflow workflow)
    {
        _workflow = workflow;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1_080, 860));
        Closed += MainWindow_OnClosed;
        Activated += MainWindow_OnActivated;
        if (_workflow is CoreMediaWorkflow coreWorkflow)
        {
            coreWorkflow.DiagnosticGenerated += CoreWorkflow_OnDiagnosticGenerated;
        }
        UpdateWvdStatus();
        AddDiagnostic("INFO", "アプリを起動しました。秘密headerとWVD内容は記録しません。");
    }

    public ObservableCollection<CandidateItem> Candidates { get; } = [];

    public ObservableCollection<DiagnosticEntry> Diagnostics { get; } = [];

    private async void PasteButton_OnClick(object sender, RoutedEventArgs e)
    {
        try
        {
            var content = Clipboard.GetContent();
            if (content.Contains(StandardDataFormats.Text))
            {
                InputTextBox.Text = (await content.GetTextAsync()).Trim();
            }
        }
        catch (Exception exception)
        {
            ShowStatus("クリップボードを読み取れませんでした。", InfoBarSeverity.Error);
            AddDiagnostic("ERROR", SafeMessage(exception.Message));
        }
    }

    private async void AnalyzeButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (!TryGetInputUri(out var input))
        {
            return;
        }

        _analysisCancellation?.Cancel();
        _analysisCancellation?.Dispose();
        _analysisCancellation = new CancellationTokenSource();
        SetAnalysisBusy(true);
        ShowStatus("ページと埋め込みフレームを解析しています…", InfoBarSeverity.Informational);
        AddDiagnostic("INFO", $"静的解析を開始: {RedactForLog(input!)}");

        try
        {
            var candidates = await _workflow.AnalyzeAsync(input!, _analysisCancellation.Token);
            foreach (var candidate in candidates)
            {
                AddCandidate(candidate);
            }

            ShowStatus(
                candidates.Count == 0
                    ? "候補が見つかりませんでした。再生解析（α）でページ上の動画を再生してみてください。"
                    : $"{candidates.Count} 件の候補を解析しました。",
                candidates.Count == 0 ? InfoBarSeverity.Warning : InfoBarSeverity.Success);
            AddDiagnostic("INFO", $"静的解析完了: {candidates.Count} 件");
        }
        catch (OperationCanceledException)
        {
            ShowStatus("解析を取り消しました。", InfoBarSeverity.Warning);
        }
        catch (Exception exception)
        {
            var safeMessage = SafeMessage(exception.Message);
            ShowStatus(safeMessage, InfoBarSeverity.Error);
            AddDiagnostic("ERROR", safeMessage);
        }
        finally
        {
            SetAnalysisBusy(false);
        }
    }

    private void ProbeButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (!TryGetInputUri(out var input))
        {
            return;
        }

        OpenProbe(input!);
    }

    private void CandidatePlayButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: CandidateItem item })
        {
            if (item.Candidate.Kind == MediaCandidateKind.WidevineDash)
            {
                if (!item.Candidate.CanDownload)
                {
                    ShowStatus("許可されていないhostのWidevineは再生できません。", InfoBarSeverity.Error);
                    return;
                }

                if (item.Candidate.Origin == MediaCandidateOrigin.Direct)
                {
                    ShowStatus(
                        "直接MPDにはページplayerがありません。配信サービスの再生ページURLを再生解析してください。",
                        InfoBarSeverity.Warning);
                    return;
                }

                OpenProbe(item.Candidate.PageUri);
                return;
            }

            if (item.Candidate.Origin != MediaCandidateOrigin.Direct)
            {
                OpenProbe(item.Candidate.PageUri);
                return;
            }

            var window = new MediaPlaybackWindow(item.Candidate.Uri);
            _mediaWindows.Add(window);
            window.Closed += (_, _) => _mediaWindows.Remove(window);
            window.Activate();
        }
    }

    private async void CandidateDownloadButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: CandidateItem item })
        {
            return;
        }

        _downloadCancellation?.Cancel();
        _downloadCancellation?.Dispose();
        _downloadCancellation = new CancellationTokenSource();
        CompletionCard.Visibility = Visibility.Collapsed;
        ProgressCard.Visibility = Visibility.Visible;
        ProgressTitle.Text = "ダウンロードを準備中";
        ProgressDetail.Text = RedactForLog(item.Candidate.Uri);
        WorkProgressBar.IsIndeterminate = true;
        AddDiagnostic("INFO", $"保存を開始: {RedactForLog(item.Candidate.Uri)}");

        var progress = new Progress<DownloadProgress>(UpdateProgress);
        try
        {
            var completed = await _workflow.DownloadAsync(
                item.Candidate,
                progress,
                _downloadCancellation.Token);
            _completedFilePath = completed.FilePath;
            ProgressCard.Visibility = Visibility.Collapsed;
            CompletionCard.Visibility = Visibility.Visible;
            CompletionTitle.Text = completed.Format == MediaOutputFormat.Wav
                ? "PCM WAVを作成しました"
                : "MP4を作成しました";
            CompletionPath.Text = completed.FilePath;
            AddDiagnostic("INFO", $"保存完了: {Path.GetFileName(completed.FilePath)}");
        }
        catch (OperationCanceledException)
        {
            ProgressCard.Visibility = Visibility.Collapsed;
            ShowStatus("ダウンロードを取り消しました。", InfoBarSeverity.Warning);
            AddDiagnostic("INFO", "ダウンロードを取り消しました。");
        }
        catch (Exception exception)
        {
            ProgressCard.Visibility = Visibility.Collapsed;
            var safeMessage = SafeMessage(exception.Message);
            ShowStatus(safeMessage, InfoBarSeverity.Error);
            AddDiagnostic("ERROR", safeMessage);
        }
    }

    private void CandidateCopyUrlButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: CandidateItem item })
        {
            return;
        }

        var package = new DataPackage();
        package.SetText(item.Candidate.Uri.AbsoluteUri);
        Clipboard.SetContent(package);
        Clipboard.Flush();
        ShowStatus("候補URLをコピーしました。", InfoBarSeverity.Success);
        AddDiagnostic("INFO", "候補URLをコピーしました（URL自体はログへ記録していません）。");
    }

    private async void CancelButton_OnClick(object sender, RoutedEventArgs e)
    {
        _downloadCancellation?.Cancel();
        if (!_resumedBackgroundJobActive)
        {
            return;
        }

        try
        {
            if (await _workflow.CancelActiveBackgroundJobAsync(CancellationToken.None))
            {
                AddDiagnostic("INFO", "再接続したバックグラウンドjobへ取消を要求しました。");
            }
        }
        catch (Exception exception)
        {
            ShowStatus(SafeMessage(exception.Message), InfoBarSeverity.Error);
            AddDiagnostic("ERROR", "バックグラウンドjobを取り消せませんでした。");
        }
    }

    private void InputTextBox_OnTextChanged(object sender, TextChangedEventArgs e)
    {
        StatusInfoBar.IsOpen = false;
    }

    private async void ImportWvdButton_OnClick(object sender, RoutedEventArgs e)
    {
        var picker = new FileOpenPicker();
        InitializePicker(picker);
        picker.FileTypeFilter.Add(".wvd");
        picker.SuggestedStartLocation = PickerLocationId.Downloads;
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            return;
        }

        try
        {
            await _wvdStore.ImportAsync(file.Path, CancellationToken.None);
            UpdateWvdStatus();
            ShowStatus("WVDを現在のWindowsユーザー用に暗号化して保存しました。", InfoBarSeverity.Success);
            AddDiagnostic("INFO", "WVDを読み込みました（内容・元パスは記録していません）。");
        }
        catch (Exception exception)
        {
            ShowStatus(SafeMessage(exception.Message), InfoBarSeverity.Error);
            AddDiagnostic("ERROR", "WVDを読み込めませんでした。");
        }
    }

    private void RemoveWvdButton_OnClick(object sender, RoutedEventArgs e)
    {
        _wvdStore.Remove();
        UpdateWvdStatus();
        ShowStatus("保存済みWVDを削除しました。", InfoBarSeverity.Success);
        AddDiagnostic("INFO", "保存済みWVDを削除しました。");
    }

    private async void SaveAsButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (!TryGetCompletedFile(out var sourcePath))
        {
            return;
        }

        var extension = Path.GetExtension(sourcePath!);
        var picker = new FileSavePicker
        {
            SuggestedFileName = Path.GetFileNameWithoutExtension(sourcePath),
            SuggestedStartLocation = PickerLocationId.VideosLibrary
        };
        InitializePicker(picker);
        picker.FileTypeChoices.Add(
            string.Equals(extension, ".wav", StringComparison.OrdinalIgnoreCase) ? "PCM WAV" : "MP4 video",
            [extension]);
        var destination = await picker.PickSaveFileAsync();
        if (destination is null)
        {
            return;
        }

        var source = await StorageFile.GetFileFromPathAsync(sourcePath);
        await source.CopyAndReplaceAsync(destination);
        ShowStatus("指定した場所へ保存しました。", InfoBarSeverity.Success);
    }

    private void OpenCompletedButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (TryGetCompletedFile(out var path))
        {
            Process.Start(new ProcessStartInfo(path!) { UseShellExecute = true });
        }
    }

    private void ShowCompletedButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (!TryGetCompletedFile(out var path))
        {
            return;
        }

        var startInfo = new ProcessStartInfo("explorer.exe") { UseShellExecute = true };
        startInfo.ArgumentList.Add("/select,");
        startInfo.ArgumentList.Add(path!);
        Process.Start(startInfo);
    }

    private void ClearLogButton_OnClick(object sender, RoutedEventArgs e) => Diagnostics.Clear();

    private void CopyLogButton_OnClick(object sender, RoutedEventArgs e)
    {
        var package = new DataPackage();
        package.SetText(RenderDiagnosticLog());
        Clipboard.SetContent(package);
        Clipboard.Flush();
        ShowStatus("診断ログをコピーしました。", InfoBarSeverity.Success);
    }

    private async void SaveLogButton_OnClick(object sender, RoutedEventArgs e)
    {
        var picker = new FileSavePicker
        {
            SuggestedFileName = $"hls-downloader-{DateTimeOffset.Now:yyyyMMdd-HHmmss}",
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary
        };
        InitializePicker(picker);
        picker.FileTypeChoices.Add("Text log", [".log"]);
        var destination = await picker.PickSaveFileAsync();
        if (destination is null)
        {
            return;
        }

        await FileIO.WriteTextAsync(destination, RenderDiagnosticLog());
        ShowStatus("診断ログを保存しました。", InfoBarSeverity.Success);
    }

    private string RenderDiagnosticLog()
        => string.Join(
            Environment.NewLine,
            Diagnostics.Reverse().Select(entry => DiagnosticRedactor.Redact(entry.Display)));

    private void OpenProbe(Uri input)
    {
        var window = new PlaybackProbeWindow(input);
        _probeWindows.Add(window);
        window.CandidateDetected += ProbeWindow_OnCandidateDetected;
        window.DiagnosticGenerated += ProbeWindow_OnDiagnosticGenerated;
        window.Closed += (_, _) =>
        {
            window.CandidateDetected -= ProbeWindow_OnCandidateDetected;
            window.DiagnosticGenerated -= ProbeWindow_OnDiagnosticGenerated;
            _probeWindows.Remove(window);
        };
        window.Activate();
        AddDiagnostic("INFO", $"再生解析を開始: {RedactForLog(input)}");
    }

    private void ProbeWindow_OnCandidateDetected(object? sender, PlaybackProbeCandidate detected)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            var signal = detected.Signal;
            if (signal.IsDash && !WidevineDownloadPolicy.IsDownloadableWidevineDomain(signal.Url))
            {
                AddDiagnostic("PROBE", $"許可されていないWidevine候補を除外: {RedactForLog(signal.Url)}");
                return;
            }

            _workflow.ImportBrowserCookies(signal.Url, detected.Cookies);
            if (signal.PageUrl is { } pageScope)
            {
                _workflow.ImportBrowserCookies(pageScope, detected.Cookies);
            }

            var pageUri = signal.PageUrl ?? TryGetInputUriSilently() ?? signal.Url;
            var candidate = new MediaCandidate(
                signal.Url,
                signal.IsDash ? MediaCandidateKind.WidevineDash : MediaCandidateKind.Hls,
                signal.Source == "dom" ? MediaCandidateOrigin.Video : MediaCandidateOrigin.InlineScript,
                pageUri,
                PosterUri: signal.ThumbnailUrl,
                Title: signal.Title);
            AddCandidate(candidate);
        });
    }

    private void ProbeWindow_OnDiagnosticGenerated(object? sender, string message)
        => DispatcherQueue.TryEnqueue(() => AddDiagnostic("PROBE", message));

    private void AddCandidate(MediaCandidate candidate)
    {
        if (candidate.Kind == MediaCandidateKind.WidevineDash && !candidate.CanDownload)
        {
            AddDiagnostic("INFO", $"許可されていないWidevine候補を除外: {RedactForLog(candidate.Uri)}");
            return;
        }

        if (Candidates.Any(existing => Uri.Compare(
                existing.Candidate.Uri,
                candidate.Uri,
                UriComponents.HttpRequestUrl,
                UriFormat.SafeUnescaped,
                StringComparison.OrdinalIgnoreCase) == 0))
        {
            return;
        }

        var canDownload = _workflow.CanDownload(candidate, out var downloadHint);
        var item = new CandidateItem(candidate, canDownload, downloadHint);
        Candidates.Add(item);
        CandidatesCard.Visibility = Visibility.Visible;
        CandidateCountText.Text = $"{Candidates.Count} 件";
        _ = LoadThumbnailAsync(item);
    }

    private void UpdateProgress(DownloadProgress progress)
    {
        ProgressTitle.Text = progress.Phase switch
        {
            DownloadPhase.Resolving => "プレイリストを解析中",
            DownloadPhase.Downloading => "segmentをダウンロード中",
            DownloadPhase.Composing => "動画・音声ファイルを生成中",
            DownloadPhase.Completed => "完了",
            _ => "準備中"
        };
        ProgressDetail.Text = progress.Message ?? string.Empty;
        if (progress.Fraction is { } fraction)
        {
            WorkProgressBar.IsIndeterminate = false;
            WorkProgressBar.Value = fraction * 100;
        }
        else
        {
            WorkProgressBar.IsIndeterminate = true;
        }
    }

    private bool TryGetInputUri(out Uri? uri)
    {
        if (!ProbePayloadParser.TryNormalizeHttpUrl(InputTextBox.Text.Trim(), out uri) || uri is null)
        {
            ShowStatus("http または https の有効なURLを入力してください。", InfoBarSeverity.Error);
            return false;
        }

        return true;
    }

    private Uri? TryGetInputUriSilently()
        => ProbePayloadParser.TryNormalizeHttpUrl(InputTextBox.Text.Trim(), out var uri) ? uri : null;

    private bool TryGetCompletedFile(out string? path)
    {
        path = _completedFilePath;
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            ShowStatus("完成ファイルが見つかりません。", InfoBarSeverity.Error);
            return false;
        }

        return true;
    }

    private void SetAnalysisBusy(bool busy)
    {
        AnalyzeButton.IsEnabled = !busy;
        ProbeButton.IsEnabled = !busy;
        AnalyzeButton.Content = busy ? "解析中…" : "解析";
    }

    private void UpdateWvdStatus()
    {
        var available = _wvdStore.HasCredential;
        WvdStatusText.Text = available
            ? "WVDは現在のWindowsユーザー用に暗号化して保存済みです。Widevine保存providerの接続後に利用できます。"
            : "WVDは未設定です。認証情報は安全に保管できますが、このビルドのWidevine保存providerは未接続です。";
        RemoveWvdButton.IsEnabled = available;
    }

    private void ShowStatus(string message, InfoBarSeverity severity)
    {
        StatusInfoBar.Message = message;
        StatusInfoBar.Severity = severity;
        StatusInfoBar.IsOpen = true;
    }

    private void AddDiagnostic(string level, string message)
    {
        Diagnostics.Insert(0, new DiagnosticEntry(
            DateTimeOffset.Now,
            level,
            SafeMessage(message)));
        while (Diagnostics.Count > 500)
        {
            Diagnostics.RemoveAt(Diagnostics.Count - 1);
        }
    }

    private void InitializePicker(object picker)
    {
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);
    }

    private static string RedactForLog(Uri uri)
    {
        return DiagnosticRedactor.SummarizeUri(uri);
    }

    private static string SafeMessage(string? message)
    {
        var safe = DiagnosticRedactor.Redact(message);
        foreach (var path in new[]
                 {
                     Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                     Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                     Path.GetTempPath(),
                     AppContext.BaseDirectory
                 }.Where(path => !string.IsNullOrWhiteSpace(path)).OrderByDescending(path => path.Length))
        {
            safe = safe.Replace(path, "[local-path]", StringComparison.OrdinalIgnoreCase);
        }

        return safe;
    }

    private void MainWindow_OnClosed(object sender, WindowEventArgs args)
    {
        Activated -= MainWindow_OnActivated;
        _analysisCancellation?.Cancel();
        _lifetimeCancellation.Cancel();
        if (_workflow is CoreMediaWorkflow coreWorkflow)
        {
            coreWorkflow.DiagnosticGenerated -= CoreWorkflow_OnDiagnosticGenerated;
        }

        if (_workflow is IDisposable disposable)
        {
            disposable.Dispose();
        }

        _thumbnailLoader.Dispose();
        _lifetimeCancellation.Dispose();
    }

    private void CoreWorkflow_OnDiagnosticGenerated(string message)
        => DispatcherQueue.TryEnqueue(() => AddDiagnostic(
            "MEDIA",
            message.StartsWith("Starting external", StringComparison.Ordinal)
                ? "外部メディアツールを開始しました。"
                : message.StartsWith("External media tool exited", StringComparison.Ordinal)
                    ? "外部メディアツールが終了しました。"
                    : message));

    private async Task RestoreLatestBackgroundJobAsync()
    {
        var progress = new Progress<DownloadProgress>(update =>
        {
            _resumedBackgroundJobActive = true;
            ProgressCard.Visibility = Visibility.Visible;
            UpdateProgress(update);
        });

        try
        {
            var completed = await _workflow.ResumeLatestBackgroundJobAsync(
                progress,
                _lifetimeCancellation.Token);
            if (completed is null)
            {
                return;
            }

            _completedFilePath = completed.FilePath;
            ProgressCard.Visibility = Visibility.Collapsed;
            CompletionCard.Visibility = Visibility.Visible;
            CompletionTitle.Text = completed.Format == MediaOutputFormat.Wav
                ? "バックグラウンド処理でPCM WAVを作成しました"
                : "バックグラウンド処理でMP4を作成しました";
            CompletionPath.Text = completed.FilePath;
            AddDiagnostic("INFO", "直近のバックグラウンド完了jobを復元しました。");
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
        }
        catch (OperationCanceledException)
        {
            ProgressCard.Visibility = Visibility.Collapsed;
            ShowStatus("バックグラウンドjobを取り消しました。", InfoBarSeverity.Warning);
            AddDiagnostic("INFO", "再接続したバックグラウンドjobを取り消しました。");
        }
        catch (Exception exception)
        {
            ProgressCard.Visibility = Visibility.Collapsed;
            AddDiagnostic("ERROR", $"バックグラウンドjobへ再接続できませんでした: {SafeMessage(exception.Message)}");
        }
        finally
        {
            _resumedBackgroundJobActive = false;
        }
    }

    private void MainWindow_OnActivated(object sender, WindowActivatedEventArgs args)
    {
        if (_backgroundRestoreStarted)
        {
            return;
        }

        _backgroundRestoreStarted = true;
        Activated -= MainWindow_OnActivated;
        _ = RestoreLatestBackgroundJobAsync();
    }

    private async Task LoadThumbnailAsync(CandidateItem item)
    {
        if (item.Candidate.PosterUri is not { } poster)
        {
            return;
        }

        try
        {
            item.Thumbnail = await _thumbnailLoader.LoadAsync(
                poster,
                item.Candidate.PageUri,
                _lifetimeCancellation.Token);
        }
        catch (OperationCanceledException) when (_lifetimeCancellation.IsCancellationRequested)
        {
        }
        catch (Exception)
        {
            AddDiagnostic("INFO", "安全な範囲でサムネイルを取得できませんでした。");
        }
    }
}
