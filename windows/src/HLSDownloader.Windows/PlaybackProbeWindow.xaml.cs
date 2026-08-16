using HLSDownloader.Core;
using HLSDownloader.WebProbe;
using HLSDownloader.Windows.Services;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Windows.System;

namespace HLSDownloader.Windows;

public sealed record PlaybackProbeCandidate(
    ProbeSignal Signal,
    BrowserCookieSnapshot CookieSnapshot);

public sealed partial class PlaybackProbeWindow : Window
{
    private readonly ProbeSession _session = new();
    private readonly Uri _initialUri;
    private int _manifestCount;

    public PlaybackProbeWindow(Uri initialUri)
    {
        _initialUri = initialUri;
        InitializeComponent();
        AddressTextBox.Text = initialUri.AbsoluteUri;
        Closed += OnClosed;

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Maximize();
        }
    }

    public event EventHandler<PlaybackProbeCandidate>? CandidateDetected;

    public event EventHandler<string>? DiagnosticGenerated;

    private async void Browser_OnCoreWebView2Initialized(WebView2 sender, CoreWebView2InitializedEventArgs args)
    {
        if (args.Exception is not null || sender.CoreWebView2 is null)
        {
            BrowserProgress.IsActive = false;
            ShowError($"WebView2を初期化できませんでした: {args.Exception?.Message}");
            return;
        }

        var core = sender.CoreWebView2;
        core.Settings.AreDevToolsEnabled = false;
        core.Settings.AreDefaultContextMenusEnabled = true;
        core.Settings.IsStatusBarEnabled = true;
        core.WebMessageReceived += Core_OnWebMessageReceived;
        core.WebResourceRequested += Core_OnWebResourceRequested;
        core.WebResourceResponseReceived += Core_OnWebResourceResponseReceived;
        core.NewWindowRequested += Core_OnNewWindowRequested;

        foreach (var context in new[]
                 {
                     CoreWebView2WebResourceContext.Media,
                     CoreWebView2WebResourceContext.XmlHttpRequest,
                     CoreWebView2WebResourceContext.Fetch,
                     CoreWebView2WebResourceContext.Document,
                     CoreWebView2WebResourceContext.Other
                 })
        {
            core.AddWebResourceRequestedFilter("*", context);
        }

        try
        {
            await core.AddScriptToExecuteOnDocumentCreatedAsync(
                WebProbeScript.CreateDocumentStartScript(
                    _session.Nonce,
                    WidevineDownloadPolicy.DownloadableWidevineHosts));
            sender.Source = _initialUri;
        }
        catch (Exception exception)
        {
            BrowserProgress.IsActive = false;
            ShowError($"再生解析を開始できませんでした: {DiagnosticRedactor.Redact(exception.Message)}");
        }
    }

    private void Core_OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (!ProbePayloadParser.TryParse(args.WebMessageAsJson, _session, out var signal) || signal is null)
        {
            return;
        }

        HandleSignal(signal);
    }

    private void Core_OnWebResourceRequested(object? sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        if (Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var requestedUri)
            && requestedUri.AbsolutePath.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase))
        {
            if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(requestedUri))
            {
                args.Response = Browser.CoreWebView2.Environment.CreateWebResourceResponse(
                    null,
                    403,
                    "Widevine host is not permitted",
                    "Content-Type: text/plain; charset=utf-8");
                DiagnosticGenerated?.Invoke(
                    this,
                    $"許可されていないWidevine MPDをブロック: {RedactForLog(requestedUri)}");
                return;
            }
        }

        // Deliberately inspect only the URL. Request headers and bodies can contain secrets.
        if (ProbePayloadParser.TryCreateHostSignal(
                args.Request.Uri,
                "webview-request",
                null,
                _session,
                out var signal)
            && signal is not null)
        {
            HandleSignal(signal);
        }
    }

    private void Core_OnWebResourceResponseReceived(
        object? sender,
        CoreWebView2WebResourceResponseReceivedEventArgs args)
    {
        string? contentType = null;
        try
        {
            contentType = args.Response.Headers.GetHeader("Content-Type");
        }
        catch (ArgumentException)
        {
            // Missing header is expected for some responses.
        }

        if (ProbePayloadParser.TryCreateHostSignal(
                args.Request.Uri,
                "webview-response",
                contentType,
                _session,
                out var signal)
            && signal is not null)
        {
            HandleSignal(signal);
        }
    }

    private void Core_OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (!ProbePayloadParser.TryNormalizeHttpUrl(args.Uri, out var uri) || uri is null)
        {
            return;
        }

        Browser.Source = uri;
    }

    private void Browser_OnNavigationCompleted(WebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        BrowserProgress.IsActive = false;
        BackButton.IsEnabled = sender.CanGoBack;
        if (sender.Source is not null)
        {
            AddressTextBox.Text = sender.Source.AbsoluteUri;
        }

        if (!args.IsSuccess)
        {
            ShowError($"ページを読み込めませんでした: {args.WebErrorStatus}");
        }
    }

    private async void HandleSignal(ProbeSignal signal)
    {
        if (signal.IsDash)
        {
            if (!WidevineDownloadPolicy.IsDownloadableWidevineDomain(signal.Url))
            {
                Browser.CoreWebView2?.Stop();
                ShowError("許可されていないhostのWidevineコンテンツをブロックしました。");
                return;
            }
        }

        if (signal.Kind == ProbeSignalKind.EncryptedMedia)
        {
            DiagnosticGenerated?.Invoke(
                this,
                $"暗号化メディアを検出 ({signal.KeySystem ?? signal.MimeType ?? "方式不明"}) {RedactForLog(signal.Url)}");
        }

        if (!signal.IsManifest)
        {
            return;
        }

        _manifestCount++;
        ProbeInfoBar.Severity = InfoBarSeverity.Success;
        ProbeInfoBar.Message = $"ページ内の再生を解析中です。候補 {_manifestCount} 件";
        DiagnosticGenerated?.Invoke(this, $"{signal.Source} で候補を検出: {RedactForLog(signal.Url)}");
        var cookieSnapshot = await CaptureCookiesAsync(signal);
        CandidateDetected?.Invoke(this, new PlaybackProbeCandidate(signal, cookieSnapshot));
    }

    private async Task<BrowserCookieSnapshot> CaptureCookiesAsync(ProbeSignal signal)
    {
        var requestedScopes = new[] { signal.Url, signal.PageUrl }
            .Where(uri => uri is not null)
            .Cast<Uri>()
            .DistinctBy(uri => uri.AbsoluteUri)
            .Take(8)
            .ToArray();
        if (Browser.CoreWebView2 is null)
        {
            return new BrowserCookieSnapshot([], []);
        }

        var siteContext = Browser.Source is { IsAbsoluteUri: true } current
                          && (current.Scheme == Uri.UriSchemeHttp || current.Scheme == Uri.UriSchemeHttps)
            ? current
            : signal.PageUrl ?? _initialUri;
        var result = new Dictionary<string, BrowserSessionCookie>(StringComparer.Ordinal);
        var capturedScopes = new List<Uri>(requestedScopes.Length);
        foreach (var scope in requestedScopes)
        {
            try
            {
                var browserCookies = await Browser.CoreWebView2.CookieManager.GetCookiesAsync(scope.AbsoluteUri);
                capturedScopes.Add(scope);
                foreach (var cookie in browserCookies.Take(128))
                {
                    var isDomainCookie = cookie.Domain.StartsWith(".", StringComparison.Ordinal);
                    var key = $"{cookie.Name}\n{cookie.Domain}\n{cookie.Path}\n{isDomainCookie}";
                    if (result.Count >= 128 && !result.ContainsKey(key))
                    {
                        continue;
                    }

                    DateTimeOffset? expires = null;
                    if (cookie.Expires > 0)
                    {
                        try
                        {
                            expires = DateTimeOffset.FromUnixTimeSeconds((long)cookie.Expires);
                        }
                        catch (ArgumentOutOfRangeException)
                        {
                        }
                    }

                    var capturedForUris = result.TryGetValue(key, out var existing)
                        ? existing.CapturedForUris.Append(scope).DistinctBy(uri => uri.AbsoluteUri).ToArray()
                        : [scope];
                    result[key] = new BrowserSessionCookie(
                        capturedForUris,
                        siteContext,
                        cookie.Name,
                        cookie.Value,
                        cookie.Domain,
                        isDomainCookie,
                        string.IsNullOrEmpty(cookie.Path) ? "/" : cookie.Path,
                        cookie.IsSecure,
                        cookie.IsHttpOnly,
                        cookie.SameSite switch
                        {
                            CoreWebView2CookieSameSiteKind.None => BrowserCookieSameSite.None,
                            CoreWebView2CookieSameSiteKind.Lax => BrowserCookieSameSite.Lax,
                            CoreWebView2CookieSameSiteKind.Strict => BrowserCookieSameSite.Strict,
                            _ => BrowserCookieSameSite.Unknown
                        },
                        expires);
                }
            }
            catch (Exception)
            {
                // Cookie values are optional and are never emitted to diagnostics.
            }
        }

        return new BrowserCookieSnapshot(capturedScopes, result.Values.ToArray());
    }

    private void NavigateFromAddressBar()
    {
        if (!ProbePayloadParser.TryNormalizeHttpUrl(AddressTextBox.Text.Trim(), out var uri) || uri is null)
        {
            ShowError("http または https の有効なURLを入力してください。");
            return;
        }

        BrowserProgress.IsActive = true;
        Browser.Source = uri;
    }

    private void BackButton_OnClick(object sender, RoutedEventArgs e)
    {
        if (Browser.CanGoBack)
        {
            Browser.GoBack();
        }
    }

    private void ReloadButton_OnClick(object sender, RoutedEventArgs e)
    {
        BrowserProgress.IsActive = true;
        Browser.Reload();
    }

    private void GoButton_OnClick(object sender, RoutedEventArgs e) => NavigateFromAddressBar();

    private void AddressTextBox_OnKeyDown(object sender, KeyRoutedEventArgs e)
    {
        if (e.Key == VirtualKey.Enter)
        {
            e.Handled = true;
            NavigateFromAddressBar();
        }
    }

    private void DoneButton_OnClick(object sender, RoutedEventArgs e) => Close();

    private void ShowError(string message)
    {
        ProbeInfoBar.Severity = InfoBarSeverity.Error;
        ProbeInfoBar.Message = message;
        DiagnosticGenerated?.Invoke(this, message);
    }

    private static string RedactForLog(Uri uri)
    {
        return DiagnosticRedactor.SummarizeUri(uri);
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        if (Browser.CoreWebView2 is { } core)
        {
            core.WebMessageReceived -= Core_OnWebMessageReceived;
            core.WebResourceRequested -= Core_OnWebResourceRequested;
            core.WebResourceResponseReceived -= Core_OnWebResourceResponseReceived;
            core.NewWindowRequested -= Core_OnNewWindowRequested;
        }

        Browser.Close();
    }
}
