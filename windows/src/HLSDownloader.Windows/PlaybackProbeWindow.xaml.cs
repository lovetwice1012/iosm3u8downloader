using System.Globalization;
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
using System.Security.Cryptography;
using System.Text.Json;
using System.Diagnostics;

namespace HLSDownloader.Windows;

[DebuggerDisplay("PlaybackProbeCandidate(<redacted>)")]
public sealed record PlaybackProbeCandidate(
    ProbeSignal Signal,
    BrowserCookieSnapshot CookieSnapshot,
    Uri? ObservedWidevineLicenseUri = null,
    BrowserGeneratedMediaDescriptor? BrowserGeneratedMedia = null)
{
    public override string ToString() => "PlaybackProbeCandidate(<redacted>)";
}

[DebuggerDisplay("BrowserGeneratedMediaDescriptor(<redacted>)")]
public sealed record BrowserGeneratedMediaDescriptor(
    string ObjectId,
    Uri PageUri,
    ProbeMediaContainer Container,
    string? MimeType,
    long? ByteLength,
    bool CanCapture,
    BrowserBlobCaptureHandle CaptureHandle)
{
    public override string ToString() => "BrowserGeneratedMediaDescriptor(<redacted>)";
}

public sealed class BrowserBlobCaptureHandle
{
    private readonly WeakReference<PlaybackProbeWindow> _owner;

    internal BrowserBlobCaptureHandle(PlaybackProbeWindow owner, string objectId)
    {
        _owner = new WeakReference<PlaybackProbeWindow>(owner);
        ObjectId = objectId;
    }

    public string ObjectId { get; }

    public Task<string> CaptureToTemporaryFileAsync(CancellationToken cancellationToken)
    {
        if (!_owner.TryGetTarget(out var owner))
        {
            throw new InvalidOperationException("The browser-generated media is no longer available.");
        }

        return owner.CaptureBrowserBlobAsync(ObjectId, cancellationToken);
    }

    public bool TryActivateOwner()
    {
        if (!_owner.TryGetTarget(out var owner))
        {
            return false;
        }

        owner.Activate();
        return true;
    }
}

public sealed partial class PlaybackProbeWindow : Window
{
    private const int MaximumResponseSniffAttempts = 64;
    private static readonly TimeSpan ResponseSniffTimeout = TimeSpan.FromSeconds(3);
    private static int _browserBlobCleanupStarted;

    private readonly ProbeSession _session = new();
    private readonly WidevineLicenseObservationTracker _widevineLicenseTracker = new(
        WidevineDownloadPolicy.DownloadableWidevineHosts);
    private readonly Dictionary<string, ProbeSignal> _manifestSignals = new(StringComparer.Ordinal);
    private readonly Uri _initialUri;
    private readonly CancellationTokenSource _lifetimeCancellation = new();
    private readonly SemaphoreSlim _responseSniffSlots = new(2, 2);
    private readonly SemaphoreSlim _blobCaptureGate = new(1, 1);
    private readonly Dictionary<string, BrowserGeneratedMediaDescriptor> _browserGeneratedMedia = new(StringComparer.Ordinal);
    private readonly BrowserObjectRouteRegistry<CoreWebView2Frame> _browserObjectRoutes = new();
    private readonly HashSet<CoreWebView2Frame> _observedFrames = [];
    private PendingBlobCapture? _pendingBlobCapture;
    private int _browserInitializationFailureReported;
    private int _manifestCount;
    private int _responseSniffAttempts;

    public PlaybackProbeWindow(Uri initialUri, CoreWebView2Environment environment)
    {
        ArgumentNullException.ThrowIfNull(environment);
        _initialUri = initialUri;
        InitializeComponent();
        AddressTextBox.Text = initialUri.AbsoluteUri;
        Closed += OnClosed;
        if (Interlocked.Exchange(ref _browserBlobCleanupStarted, 1) == 0)
        {
            _ = Task.Run(() => CleanupAbandonedBrowserBlobCaptures(TimeSpan.FromDays(1)));
        }
        _ = InitializeBrowserAsync(environment);

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Maximize();
        }
    }

    public event EventHandler<PlaybackProbeCandidate>? CandidateDetected;

    public event EventHandler<string>? DiagnosticGenerated;

    private async Task InitializeBrowserAsync(CoreWebView2Environment environment)
    {
        try
        {
            // Explicitly inject the shared LocalAppData-backed environment before
            // the window is activated. Never fall back to the portable EXE folder.
            await Browser.EnsureCoreWebView2Async(environment);
        }
        catch (Exception exception)
        {
            ReportBrowserInitializationFailure(exception.Message);
        }
    }

    private async void Browser_OnCoreWebView2Initialized(WebView2 sender, CoreWebView2InitializedEventArgs args)
    {
        if (_lifetimeCancellation.IsCancellationRequested)
        {
            return;
        }

        if (args.Exception is not null || sender.CoreWebView2 is null)
        {
            ReportBrowserInitializationFailure(args.Exception?.Message ?? "CoreWebView2を利用できません。");
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
        core.FrameCreated += Core_OnFrameCreated;
        core.DownloadStarting += Core_OnDownloadStarting;

        // Includes script, text-track, manifest, websocket handshake, ping and
        // future contexts that were missed by the previous hand-picked list.
        core.AddWebResourceRequestedFilter(
            "*",
            CoreWebView2WebResourceContext.All,
            CoreWebView2WebResourceRequestSourceKinds.All);

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
            ShowError($"再生解析を開始できませんでした: {SafeMessage(exception.Message)}");
        }
    }

    private void Core_OnWebMessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (!ProbePayloadParser.TryParse(args.WebMessageAsJson, _session, out var signal) || signal is null)
        {
            return;
        }

        HandleSignal(signal, sender as CoreWebView2Frame);
    }

    private void Core_OnFrameCreated(object? sender, CoreWebView2FrameCreatedEventArgs args)
        => ObserveFrame(args.Frame);

    private void ObserveFrame(CoreWebView2Frame frame)
    {
        if (!_observedFrames.Add(frame))
        {
            return;
        }

        frame.WebMessageReceived += Core_OnWebMessageReceived;
        frame.FrameCreated += Core_OnFrameCreated;
        frame.Destroyed += Frame_OnDestroyed;
    }

    private void Frame_OnDestroyed(object? sender, object args)
    {
        if (sender is not CoreWebView2Frame frame || !_observedFrames.Remove(frame))
        {
            return;
        }

        frame.WebMessageReceived -= Core_OnWebMessageReceived;
        frame.FrameCreated -= Core_OnFrameCreated;
        frame.Destroyed -= Frame_OnDestroyed;
        foreach (var objectId in _browserObjectRoutes.RemoveTarget(frame))
        {
            _browserGeneratedMedia.Remove(objectId);
        }
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

    private async void Core_OnWebResourceResponseReceived(
        object? sender,
        CoreWebView2WebResourceResponseReceivedEventArgs args)
    {
        try
        {
            await ProcessWebResourceResponseAsync(args);
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception)
        {
            // A response can disappear while WebView2 is closing. Never log its details.
        }
    }

    private async Task ProcessWebResourceResponseAsync(
        CoreWebView2WebResourceResponseReceivedEventArgs args)
    {
        if (!ProbePayloadParser.TryNormalizeHttpUrl(args.Request.Uri, out var responseUri)
            || responseUri is null)
        {
            return;
        }

        var contentType = TryGetResponseHeader(args, "Content-Type");
        var statusCode = args.Response.StatusCode;
        var requestMethod = args.Request.Method;
        var isDeclaredManifest = ResourceClassifier.IsManifest(responseUri, contentType);

        // Only method, normalized URI and status are observed. Request/response
        // headers and bodies are never inspected for license correlation.
        if (!isDeclaredManifest)
        {
            _widevineLicenseTracker.ObserveSuccessfulPost(
                responseUri,
                requestMethod,
                statusCode,
                DateTimeOffset.UtcNow);
        }

        if (statusCode is >= 200 and < 300
            && isDeclaredManifest
            && (responseUri.AbsolutePath.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)
                || contentType?.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) == true))
        {
            _widevineLicenseTracker.ObserveManifest(responseUri);
        }

        if (statusCode is >= 300 and < 400
            && ManifestResponseSniffer.TryResolveRedirectTarget(
                responseUri,
                TryGetResponseHeader(args, "Location"),
                out var redirectTarget)
            && redirectTarget is not null
            && ProbePayloadParser.TryCreateHostSignal(
                redirectTarget.AbsoluteUri,
                "webview-redirect",
                null,
                _session,
                out var redirectSignal)
            && redirectSignal is not null)
        {
            HandleSignal(redirectSignal);
        }

        if (ProbePayloadParser.TryCreateHostSignal(
                responseUri.AbsoluteUri,
                "webview-response",
                contentType,
                _session,
                out var signal)
            && signal is not null)
        {
            HandleSignal(signal);
            return;
        }

        var declaredContentLength = TryParseContentLength(TryGetResponseHeader(args, "Content-Length"));
        if (!string.Equals(requestMethod, "GET", StringComparison.OrdinalIgnoreCase)
            || !ManifestResponseSniffer.ShouldInspect(
                responseUri,
                contentType,
                declaredContentLength,
                statusCode)
            || !await _responseSniffSlots.WaitAsync(0))
        {
            return;
        }

        try
        {
            if (Interlocked.Increment(ref _responseSniffAttempts) > MaximumResponseSniffAttempts)
            {
                return;
            }

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                _lifetimeCancellation.Token);
            timeout.CancelAfter(ResponseSniffTimeout);

            var contentOperation = args.Response.GetContentAsync();
            using var cancellationRegistration = timeout.Token.Register(contentOperation.Cancel);
            using var randomAccessContent = await contentOperation;
            using var content = randomAccessContent.AsStreamForRead();
            var kind = await ManifestResponseSniffer.ClassifyPrefixAsync(
                content,
                timeout.Token);
            var sniffedContentType = kind switch
            {
                SniffedManifestKind.Hls => "application/vnd.apple.mpegurl",
                SniffedManifestKind.Dash => "application/dash+xml",
                _ => null
            };
            if (sniffedContentType is not null
                && ProbePayloadParser.TryCreateHostSignal(
                    responseUri.AbsoluteUri,
                    "webview-response-sniff",
                    sniffedContentType,
                    _session,
                    out var sniffedSignal)
                && sniffedSignal is not null)
            {
                if (kind == SniffedManifestKind.Dash)
                {
                    _widevineLicenseTracker.ObserveManifest(responseUri);
                }

                HandleSignal(sniffedSignal);
            }
        }
        catch (OperationCanceledException)
        {
            // Closing the window or exceeding the short inspection deadline is expected.
        }
        catch (Exception)
        {
            // A response body can be unavailable. Never emit response details or headers.
        }
        finally
        {
            _responseSniffSlots.Release();
        }
    }

    private static string? TryGetResponseHeader(
        CoreWebView2WebResourceResponseReceivedEventArgs args,
        string name)
    {
        try
        {
            return args.Response.Headers.GetHeader(name);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static long? TryParseContentLength(string? raw)
    {
        return long.TryParse(raw, NumberStyles.None, CultureInfo.InvariantCulture, out var value)
            ? value
            : null;
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

    private void Browser_OnNavigationStarting(WebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        BrowserProgress.IsActive = true;
        if (_pendingBlobCapture is { } pending)
        {
            CancelPendingBlobCapture(pending);
        }

        _browserGeneratedMedia.Clear();
        _browserObjectRoutes.Clear();
    }

    private async void HandleSignal(ProbeSignal signal, CoreWebView2Frame? sourceFrame = null)
    {
        if (signal.Kind == ProbeSignalKind.EncryptedMediaLifecycle)
        {
            if (signal.EmePhase is { } phase
                && _widevineLicenseTracker.ObserveLifecycle(
                    phase,
                    DateTimeOffset.UtcNow) is { } association)
            {
                await PublishWidevineLicenseAssociationAsync(association);
            }

            return;
        }

        if (signal.IsBrowserGenerated)
        {
            await PublishBrowserGeneratedMediaAsync(signal, sourceFrame);
            return;
        }

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


        if (signal.Kind == ProbeSignalKind.MediaElement
            && ResourceClassifier.IsProgressiveMedia(signal.Url, signal.MimeType))
        {
            var progressiveCookies = await CaptureCookiesAsync(signal);
            CandidateDetected?.Invoke(this, new PlaybackProbeCandidate(signal, progressiveCookies));
            return;
        }

        if (!signal.IsManifest)
        {
            return;
        }

        RememberManifestSignal(signal);

        _manifestCount++;
        ProbeInfoBar.Severity = InfoBarSeverity.Success;
        ProbeInfoBar.Message = $"ページ内の再生を解析中です。候補 {_manifestCount} 件";
        DiagnosticGenerated?.Invoke(this, $"{signal.Source} で候補を検出: {RedactForLog(signal.Url)}");
        var cookieSnapshot = await CaptureCookiesAsync(signal);
        CandidateDetected?.Invoke(this, new PlaybackProbeCandidate(signal, cookieSnapshot));
    }

    private async Task PublishBrowserGeneratedMediaAsync(
        ProbeSignal signal,
        CoreWebView2Frame? sourceFrame)
    {
        if (signal.BrowserObjectId is not { Length: > 0 } objectId
            || signal.PageUrl is null
            || signal.Container == ProbeMediaContainer.Unknown)
        {
            return;
        }

        var isBlob = signal.IsBrowserBlob;
        var captureHandle = new BrowserBlobCaptureHandle(this, objectId);
        var descriptor = new BrowserGeneratedMediaDescriptor(
            objectId,
            signal.PageUrl,
            signal.Container,
            signal.MimeType,
            signal.ByteLength,
            isBlob,
            captureHandle);
        _browserGeneratedMedia[objectId] = descriptor;
        _browserObjectRoutes.Set(objectId, sourceFrame);

        var cookies = await CaptureCookiesAsync(signal);
        CandidateDetected?.Invoke(
            this,
            new PlaybackProbeCandidate(signal, cookies, BrowserGeneratedMedia: descriptor));
        DiagnosticGenerated?.Invoke(
            this,
            isBlob
                ? $"Browser-generated {signal.Container} media detected ({signal.ByteLength ?? 0} bytes)."
                : $"MediaSource playback detected ({signal.Container}); saving requires its source manifest.");
    }

    private void RememberManifestSignal(ProbeSignal signal)
    {
        var key = signal.Url.AbsoluteUri;
        if (!_manifestSignals.TryGetValue(key, out var existing)
            || (existing.PageUrl is null && signal.PageUrl is not null)
            || (existing.ThumbnailUrl is null && signal.ThumbnailUrl is not null))
        {
            _manifestSignals[key] = signal;
        }
    }

    private async Task PublishWidevineLicenseAssociationAsync(
        WidevineLicenseAssociation association)
    {
        if (!_manifestSignals.TryGetValue(association.ManifestUri.AbsoluteUri, out var signal))
        {
            signal = new ProbeSignal(
                ProbeSignalKind.Manifest,
                association.ManifestUri,
                "webview-response",
                "application/dash+xml",
                PageUrl: Browser.Source ?? _initialUri);
            RememberManifestSignal(signal);
        }

        var cookieSnapshot = await CaptureCookiesAsync(signal, association.LicenseUri);
        CandidateDetected?.Invoke(
            this,
            new PlaybackProbeCandidate(signal, cookieSnapshot, association.LicenseUri));
        DiagnosticGenerated?.Invoke(
            this,
            "Widevine license endpointを再生時の通信から関連付けました（URI・query・bodyはログへ出力しません）。");
    }

    private async Task<BrowserCookieSnapshot> CaptureCookiesAsync(
        ProbeSignal signal,
        params Uri[] additionalScopes)
    {
        var requestedScopes = new[] { signal.Url, signal.PageUrl }
            .Where(uri => uri is not null)
            .Cast<Uri>()
            .Concat(additionalScopes.Where(uri => uri is not null))
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

    internal async Task<string> CaptureBrowserBlobAsync(
        string objectId,
        CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(objectId);
        await _blobCaptureGate.WaitAsync(cancellationToken);
        string? outputPath = null;
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (_lifetimeCancellation.IsCancellationRequested
                || Browser.CoreWebView2 is not { } core
                || !_browserGeneratedMedia.TryGetValue(objectId, out var descriptor)
                || !descriptor.CanCapture
                || descriptor.ByteLength is not { } expectedLength
                || expectedLength is <= 0 or > ProbePayloadParser.MaximumBrowserBlobBytes)
            {
                throw new InvalidOperationException("The browser-generated media is no longer available.");
            }

            var captureRoot = Path.Combine(
                GetBrowserBlobCaptureRoot(),
                Guid.NewGuid().ToString("N"));
            EnsureCaptureDiskSpace(captureRoot, expectedLength);
            Directory.CreateDirectory(captureRoot);
            var extension = BrowserContainerExtension(descriptor.Container);
            outputPath = Path.Combine(captureRoot, $"captured.{extension}");
            var token = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
            var pending = new PendingBlobCapture(
                objectId,
                token,
                outputPath,
                expectedLength,
                new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously));
            _pendingBlobCapture = pending;

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken,
                _lifetimeCancellation.Token);
            timeout.CancelAfter(TimeSpan.FromMinutes(30));
            using var registration = timeout.Token.Register(() =>
                DispatcherQueue.TryEnqueue(() => CancelPendingBlobCapture(pending)));
            var commandJson = JsonSerializer.Serialize(new
            {
                channel = "hls-downloader-probe",
                nonce = _session.Nonce,
                command = "download-browser-blob",
                objectId,
                downloadToken = token
            });
            if (_browserObjectRoutes.TryGet(objectId, out var sourceFrame)
                && sourceFrame is not null)
            {
                sourceFrame.PostWebMessageAsJson(commandJson);
            }
            else
            {
                core.PostWebMessageAsJson(commandJson);
            }

            var completedPath = await pending.Completion.Task.WaitAsync(timeout.Token);
            var info = new FileInfo(completedPath);
            if (!info.Exists || info.LinkTarget is not null || info.Length != expectedLength)
            {
                throw new InvalidDataException("The browser-generated media capture was incomplete.");
            }

            outputPath = null;
            return completedPath;
        }
        finally
        {
            _pendingBlobCapture = null;
            _blobCaptureGate.Release();
            if (outputPath is not null)
            {
                TryDeleteFileAndEmptyParent(outputPath);
            }
        }
    }

    private void Core_OnDownloadStarting(object? sender, CoreWebView2DownloadStartingEventArgs args)
    {
        var pending = _pendingBlobCapture;
        var operation = args.DownloadOperation;
        var proposedFileName = Path.GetFileName(args.ResultFilePath);
        if (pending is null
            || !Uri.TryCreate(operation.Uri, UriKind.Absolute, out var downloadUri)
            || !string.Equals(downloadUri.Scheme, "blob", StringComparison.OrdinalIgnoreCase)
            || proposedFileName is null
            || !proposedFileName.StartsWith(
                $"hls-downloader-{pending.DownloadToken}.",
                StringComparison.Ordinal))
        {
            return;
        }

        using var deferral = args.GetDeferral();
        try
        {
            if (operation.TotalBytesToReceive is { } total
                && checked((ulong)total) != checked((ulong)pending.ExpectedLength))
            {
                operation.Cancel();
                pending.Completion.TrySetException(
                    new InvalidDataException("The browser-generated media size changed before capture."));
                return;
            }

            pending.Operation = operation;
            args.ResultFilePath = pending.OutputPath;
            args.Handled = true;
            operation.BytesReceivedChanged += BlobDownloadOperation_OnBytesReceivedChanged;
            operation.StateChanged += BlobDownloadOperation_OnStateChanged;
        }
        catch (Exception exception)
        {
            operation.Cancel();
            pending.Completion.TrySetException(
                new IOException("The browser-generated media capture could not start.", exception));
        }
        finally
        {
            deferral.Complete();
        }
    }

    private void BlobDownloadOperation_OnBytesReceivedChanged(
        object? sender,
        object args)
    {
        if (sender is not CoreWebView2DownloadOperation operation
            || _pendingBlobCapture is not { } pending
            || !ReferenceEquals(pending.Operation, operation)
            || operation.BytesReceived <= pending.ExpectedLength)
        {
            return;
        }

        operation.Cancel();
        pending.Completion.TrySetException(
            new InvalidDataException("The browser-generated media exceeded its declared size."));
    }

    private void BlobDownloadOperation_OnStateChanged(object? sender, object args)
    {
        if (sender is not CoreWebView2DownloadOperation operation
            || _pendingBlobCapture is not { } pending
            || !ReferenceEquals(pending.Operation, operation))
        {
            return;
        }

        if (operation.State == CoreWebView2DownloadState.InProgress)
        {
            return;
        }

        operation.BytesReceivedChanged -= BlobDownloadOperation_OnBytesReceivedChanged;
        operation.StateChanged -= BlobDownloadOperation_OnStateChanged;
        if (operation.State == CoreWebView2DownloadState.Completed)
        {
            pending.Completion.TrySetResult(pending.OutputPath);
        }
        else
        {
            pending.Completion.TrySetException(
                new IOException($"The browser-generated media capture was interrupted ({operation.InterruptReason})."));
        }
    }

    private void CancelPendingBlobCapture(PendingBlobCapture pending)
    {
        if (!ReferenceEquals(_pendingBlobCapture, pending))
        {
            return;
        }

        try
        {
            pending.Operation?.Cancel();
        }
        catch (Exception)
        {
        }

        pending.Completion.TrySetCanceled();
    }

    private static string BrowserContainerExtension(ProbeMediaContainer container) => container switch
    {
        ProbeMediaContainer.Hls => "m3u8",
        ProbeMediaContainer.Dash => "mpd",
        ProbeMediaContainer.Mp4 => "mp4",
        ProbeMediaContainer.QuickTime => "mov",
        ProbeMediaContainer.MpegTs => "ts",
        ProbeMediaContainer.WebM => "webm",
        ProbeMediaContainer.M4a => "m4a",
        ProbeMediaContainer.Mp3 => "mp3",
        ProbeMediaContainer.Aac => "aac",
        ProbeMediaContainer.Ogg => "ogg",
        ProbeMediaContainer.Opus => "opus",
        _ => "bin"
    };

    private static void EnsureCaptureDiskSpace(string path, long expectedLength)
    {
        var root = Path.GetPathRoot(Path.GetFullPath(path));
        if (string.IsNullOrWhiteSpace(root))
        {
            throw new IOException("The browser capture volume could not be resolved.");
        }

        long freeBytes = new DriveInfo(root).AvailableFreeSpace;
        if (!BrowserCaptureStoragePolicy.CanCapture(freeBytes, expectedLength))
        {
            throw new IOException("There is not enough free disk space to capture this browser-generated media.");
        }
    }

    private static string GetBrowserBlobCaptureRoot()
        => Path.GetFullPath(Path.Combine(
            Path.GetTempPath(),
            "HLSDownloader",
            "BrowserBlobCaptures"));

    private static void CleanupAbandonedBrowserBlobCaptures(TimeSpan olderThan)
    {
        var root = GetBrowserBlobCaptureRoot();
        if (olderThan < TimeSpan.Zero || !Directory.Exists(root))
        {
            return;
        }

        var threshold = DateTime.UtcNow - olderThan;
        try
        {
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                var target = Path.GetFullPath(directory);
                if (!string.Equals(
                        Path.GetDirectoryName(target),
                        root.TrimEnd(Path.DirectorySeparatorChar),
                        StringComparison.OrdinalIgnoreCase)
                    || !Guid.TryParseExact(Path.GetFileName(target), "N", out _))
                {
                    continue;
                }

                try
                {
                    var info = new DirectoryInfo(target);
                    if ((info.Attributes & FileAttributes.ReparsePoint) != 0
                        || info.LastWriteTimeUtc >= threshold)
                    {
                        continue;
                    }

                    Directory.Delete(target, recursive: true);
                }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                {
                }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static void TryDeleteFileAndEmptyParent(string path)
    {
        try
        {
            File.Delete(path);
            var directory = Path.GetDirectoryName(path);
            if (directory is not null && Directory.Exists(directory)
                && !Directory.EnumerateFileSystemEntries(directory).Any())
            {
                Directory.Delete(directory);
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
        }
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

    private void ReportBrowserInitializationFailure(string message)
    {
        if (_lifetimeCancellation.IsCancellationRequested
            || Interlocked.Exchange(ref _browserInitializationFailureReported, 1) != 0)
        {
            return;
        }

        BrowserProgress.IsActive = false;
        ShowError($"WebView2を初期化できませんでした: {SafeMessage(message)}");
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

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _lifetimeCancellation.Cancel();
        if (_pendingBlobCapture is { } pending)
        {
            CancelPendingBlobCapture(pending);
        }
        if (Browser.CoreWebView2 is { } core)
        {
            core.WebMessageReceived -= Core_OnWebMessageReceived;
            core.WebResourceRequested -= Core_OnWebResourceRequested;
            core.WebResourceResponseReceived -= Core_OnWebResourceResponseReceived;
            core.NewWindowRequested -= Core_OnNewWindowRequested;
            core.FrameCreated -= Core_OnFrameCreated;
            core.DownloadStarting -= Core_OnDownloadStarting;
        }

        foreach (var frame in _observedFrames.ToArray())
        {
            frame.WebMessageReceived -= Core_OnWebMessageReceived;
            frame.FrameCreated -= Core_OnFrameCreated;
            frame.Destroyed -= Frame_OnDestroyed;
        }
        _observedFrames.Clear();
        _browserGeneratedMedia.Clear();
        _browserObjectRoutes.Clear();

        Browser.Close();
    }

    private sealed class PendingBlobCapture(
        string objectId,
        string downloadToken,
        string outputPath,
        long expectedLength,
        TaskCompletionSource<string> completion)
    {
        public string ObjectId { get; } = objectId;
        public string DownloadToken { get; } = downloadToken;
        public string OutputPath { get; } = outputPath;
        public long ExpectedLength { get; } = expectedLength;
        public TaskCompletionSource<string> Completion { get; } = completion;
        public CoreWebView2DownloadOperation? Operation { get; set; }
    }
}
