using HLSDownloader.Core;
using HLSDownloader.Media;
using HLSDownloader.Worker;
using System.Net;
using System.Text;

namespace HLSDownloader.Windows.Services;

/// <summary>
/// Thin UI boundary around the portable discovery and media pipeline.
/// </summary>
public sealed class CoreMediaWorkflow : IMediaWorkflow, IDisposable
{
    public const int MaximumCapturedHlsManifestBytes = 4 * 1024 * 1024;

    private readonly IWidevineCredentialSource _widevineCredentialSource;
    private readonly object _browserCookieSnapshotLock = new();
    private readonly Dictionary<BrowserCookieCapabilityKey, RememberedBrowserCookies> _browserCookieSnapshots = [];
    private readonly Dictionary<Uri, RememberedBrowserCookies> _analysisCookieSnapshots = [];
    private readonly WidevineLicenseHintCache _widevineLicenseHints = new();
    private readonly Timer _browserCookieExpiryTimer;
    private readonly SemaphoreSlim _downloadGate = new(1, 1);
    private static readonly TimeSpan BrowserCookieSnapshotLifetime = TimeSpan.FromMinutes(5);
    private bool _disposed;
    private readonly object _workerStartLock = new();
    private readonly object _activeWorkerJobLock = new();
    private Guid? _activeWorkerJobId;

    public CoreMediaWorkflow(IWidevineCredentialSource? widevineCredentialSource = null)
    {
        _browserCookieExpiryTimer = new Timer(
            static state => ((CoreMediaWorkflow)state!).PurgeExpiredBrowserCookieSnapshots(),
            this,
            Timeout.InfiniteTimeSpan,
            Timeout.InfiniteTimeSpan);
        _widevineCredentialSource = widevineCredentialSource ?? new WvdCredentialStore();
    }

    public event Action<string>? DiagnosticGenerated;

    public bool CanDownload(MediaCandidate candidate, out string reason)
    {
        if (candidate.Kind is MediaCandidateKind.Hls or MediaCandidateKind.Progressive)
        {
            reason = "再生・保存に対応";
            return true;
        }

        if (!candidate.CanDownload
            || !WidevineDownloadPolicy.IsDownloadableWidevineDomain(candidate.RequestedUri ?? candidate.Uri)
            || !WidevineDownloadPolicy.IsDownloadableWidevineDomain(candidate.Uri))
        {
            reason = "許可されていないhostのWidevineは再生・保存できません";
            return false;
        }

        if (!_widevineCredentialSource.IsAvailable)
        {
            reason = "Widevine保存には有効なL3 WVDファイルの読み込みが必要です";
            return false;
        }

        try
        {
            // UI availability checks must not create a long-lived provider/client.
            // The real provider is constructed inside the candidate download scope.
            var locator = new FFmpegToolLocator();
            _ = locator.ResolveFFmpeg();
            _ = locator.ResolveFFprobe();
            reason = "Widevine L3を復号してMP4/WAVへ保存できます";
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            // Availability is a UI hint only. The download path performs the
            // same checks again and reports a redacted, fail-closed error.
        }

        reason = "Widevine保存に必要なWVDまたはFFmpegを利用できません";
        return false;
    }

    public void RememberBrowserCookies(
        Uri candidateUri,
        BrowserCookieSnapshot snapshot,
        string? browserSourceId = null)
    {
        ArgumentNullException.ThrowIfNull(candidateUri);
        ArgumentNullException.ThrowIfNull(snapshot);
        var capabilityKey = new BrowserCookieCapabilityKey(candidateUri, browserSourceId);
        lock (_browserCookieSnapshotLock)
        {
            if (_disposed)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            PurgeExpiredBrowserCookieSnapshotsLocked(now);

            if (!_browserCookieSnapshots.ContainsKey(capabilityKey) && _browserCookieSnapshots.Count >= 128)
            {
                _browserCookieSnapshots.Remove(_browserCookieSnapshots.Keys.First());
            }

            _browserCookieSnapshots[capabilityKey] = new RememberedBrowserCookies(snapshot, now);
            ScheduleBrowserCookieExpiryLocked(now);
        }
    }

    public void RememberObservedWidevineLicense(
        Uri manifestUri,
        Uri licenseUri,
        BrowserCookieSnapshot snapshot)
    {
        ArgumentNullException.ThrowIfNull(manifestUri);
        ArgumentNullException.ThrowIfNull(licenseUri);
        ArgumentNullException.ThrowIfNull(snapshot);
        lock (_browserCookieSnapshotLock)
        {
            if (_disposed)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            PurgeExpiredBrowserCookieSnapshotsLocked(now);
            // The endpoint (including any required query) and its cookie scope stay
            // in process memory only. They are removed before the first network I/O.
            _widevineLicenseHints.Remember(
                manifestUri,
                licenseUri,
                snapshot,
                now);
            ScheduleBrowserCookieExpiryLocked(now);
        }
    }

    private void RememberAnalysisCookies(
        IReadOnlyList<MediaCandidate> candidates,
        CookieContainer analysisCookies)
    {
        var captured = candidates.Select(candidate =>
        {
            Uri[] scopes = new[] { candidate.RequestedUri, candidate.Uri, candidate.PageUri }
                .OfType<Uri>()
                .Where(uri => uri.IsAbsoluteUri
                              && (uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
                                  || uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
                              && string.IsNullOrEmpty(uri.UserInfo))
                .DistinctBy(uri => uri.AbsoluteUri, StringComparer.OrdinalIgnoreCase)
                .ToArray();
            return (candidate.Uri, Snapshot: BrowserCookieImporter.CaptureHostOnlySnapshot(analysisCookies, scopes));
        }).ToArray();

        lock (_browserCookieSnapshotLock)
        {
            if (_disposed)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            PurgeExpiredBrowserCookieSnapshotsLocked(now);
            foreach (var entry in captured)
            {
                // A new analysis supersedes any older capability for the same candidate,
                // including when the new response produced no applicable cookies.
                _analysisCookieSnapshots.Remove(entry.Uri);
                if (entry.Snapshot.Cookies.Count == 0)
                {
                    continue;
                }

                if (_analysisCookieSnapshots.Count >= 128)
                {
                    _analysisCookieSnapshots.Remove(_analysisCookieSnapshots.Keys.First());
                }

                _analysisCookieSnapshots[entry.Uri] = new RememberedBrowserCookies(entry.Snapshot, now);
            }

            ScheduleBrowserCookieExpiryLocked(now);
        }
    }

    public async Task<CompletedMedia?> ResumeLatestBackgroundJobAsync(
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        var ledgerPath = GetWorkerLedgerPath();
        if (!File.Exists(GetWorkerExecutablePath()) || !File.Exists(ledgerPath))
        {
            return null;
        }

        var ledger = new JobLedger(ledgerPath);
        var jobs = await ledger.GetJobsAsync(cancellationToken).ConfigureAwait(false);
        var active = jobs
            .Where(job => job.State is WorkerJobState.Queued or WorkerJobState.Running)
            .OrderByDescending(job => job.UpdatedAt)
            .FirstOrDefault();
        if (active is null)
        {
            var completedWithoutWorker = jobs
                .Where(job => job.State == WorkerJobState.Completed
                              && !string.IsNullOrWhiteSpace(job.OutputPath)
                              && File.Exists(job.OutputPath))
                .OrderByDescending(job => job.UpdatedAt)
                .FirstOrDefault();
            return completedWithoutWorker is null ? null : ToCompletedMedia(completedWithoutWorker.OutputPath!);
        }

        const string pipeName = "HLSDownloader.Worker";
        EnsureWorkerStarted(pipeName);
        var client = new WorkerPipeClient(pipeName);
        var response = await client.GetStatusAsync(cancellationToken).ConfigureAwait(false);
        if (!response.Ok)
        {
            throw new IOException(DiagnosticRedactor.Redact(
                response.Error ?? "バックグラウンドjobの状態を取得できませんでした。"));
        }

        jobs = response.Jobs ?? [];
        active = jobs
            .Where(job => job.State is WorkerJobState.Queued or WorkerJobState.Running)
            .OrderByDescending(job => job.UpdatedAt)
            .FirstOrDefault();
        if (active is not null)
        {
            DiagnosticGenerated?.Invoke("既存のバックグラウンドjobへ再接続しました。");
            return await WaitForBackgroundJobAsync(
                client,
                active,
                progress,
                cancelRemoteOnCancellation: false,
                cancellationToken).ConfigureAwait(false);
        }

        var completed = jobs
            .Where(job => job.State == WorkerJobState.Completed
                          && !string.IsNullOrWhiteSpace(job.OutputPath)
                          && File.Exists(job.OutputPath))
            .OrderByDescending(job => job.UpdatedAt)
            .FirstOrDefault();
        return completed is null ? null : ToCompletedMedia(completed.OutputPath!);
    }

    public async Task<bool> CancelActiveBackgroundJobAsync(CancellationToken cancellationToken)
    {
        Guid? jobId;
        lock (_activeWorkerJobLock)
        {
            jobId = _activeWorkerJobId;
        }

        if (jobId is null)
        {
            return false;
        }

        var response = await new WorkerPipeClient("HLSDownloader.Worker")
            .CancelAsync(jobId.Value, cancellationToken)
            .ConfigureAwait(false);
        if (!response.Ok)
        {
            throw new IOException(DiagnosticRedactor.Redact(
                response.Error ?? "バックグラウンドjobを取り消せませんでした。"));
        }

        return true;
    }

    public async Task<IReadOnlyList<MediaCandidate>> AnalyzeAsync(
        Uri input,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var analysisCookies = CreateCookieContainer();
        using var discoveryClient = new BoundedHttpClient(
            new BoundedHttpOptions(MaximumResponseBytes: 8 * 1024 * 1024),
            cookies: analysisCookies);
        var resolver = new MediaSourceResolver(discoveryClient);
        var resolution = await resolver.ResolveAsync(input, cancellationToken).ConfigureAwait(false);
        RememberAnalysisCookies(resolution.Candidates, analysisCookies);
        return resolution.Candidates;
    }

    public async Task<CompletedMedia> DownloadAsync(
        MediaCandidate candidate,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        if (!CanDownload(candidate, out var reason))
        {
            throw new InvalidOperationException(reason);
        }

        await _downloadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            BrowserCookieSnapshot? snapshot = null;
            BrowserCookieSnapshot? analysisSnapshot = null;
            BrowserCookieSnapshot? licenseSnapshot = null;
            Uri? observedWidevineLicenseUri = null;
            lock (_browserCookieSnapshotLock)
            {
                var now = DateTimeOffset.UtcNow;
                PurgeExpiredBrowserCookieSnapshotsLocked(now);
                if (_browserCookieSnapshots.Remove(
                        new BrowserCookieCapabilityKey(candidate.Uri, candidate.BrowserSourceId),
                        out var remembered)
                    && now - remembered.CapturedAt <= BrowserCookieSnapshotLifetime)
                {
                    // A browser credential snapshot is a short-lived, single-use capability.
                    // Removing it before network I/O prevents replay after this attempt.
                    snapshot = remembered.Snapshot;
                }

                if (_analysisCookieSnapshots.Remove(candidate.Uri, out var rememberedAnalysis)
                    && now - rememberedAnalysis.CapturedAt <= BrowserCookieSnapshotLifetime)
                {
                    analysisSnapshot = rememberedAnalysis.Snapshot;
                }

                if (_widevineLicenseHints.TryTake(candidate.Uri, now, out var rememberedLicense)
                    && rememberedLicense is not null)
                {
                    observedWidevineLicenseUri = rememberedLicense.LicenseUri;
                    licenseSnapshot = rememberedLicense.CookieSnapshot;
                }

                ScheduleBrowserCookieExpiryLocked(now);
            }

            if (candidate.Kind == MediaCandidateKind.WidevineDash)
            {
                // The short-lived store is authoritative. Never retain a URI copied
                // into a UI candidate after the corresponding capability has expired.
                candidate = candidate with
                {
                    ObservedWidevineLicenseUri = observedWidevineLicenseUri
                };
            }

            var jobCookies = CreateCookieContainer();
            // Both the importer index and the cookie jar are job-scoped. Imported browser
            // values and response Set-Cookie state become unreachable after this attempt.
            new BrowserCookieSnapshotSynchronizer().Replace(jobCookies, analysisSnapshot);
            new BrowserCookieSnapshotSynchronizer().Replace(jobCookies, snapshot);
            new BrowserCookieSnapshotSynchronizer().Replace(jobCookies, licenseSnapshot);
            return await DownloadWithCoordinatorAsync(
                    candidate,
                    jobCookies,
                    progress,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            _downloadGate.Release();
        }
    }

    public async Task<CompletedMedia> ProcessCapturedProgressiveAsync(
        MediaCandidate candidate,
        string capturedPath,
        string? declaredMediaType,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentException.ThrowIfNullOrWhiteSpace(capturedPath);
        if (candidate.Kind != MediaCandidateKind.Progressive
            || candidate.Origin != MediaCandidateOrigin.BrowserBlob
            || string.IsNullOrWhiteSpace(candidate.BrowserSourceId))
        {
            throw new InvalidOperationException("A browser Blob progressive candidate is required.");
        }

        await _downloadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var outputDirectory = GetOutputDirectory();
            Directory.CreateDirectory(outputDirectory);
            var outputBasePath = Path.Combine(outputDirectory, CreateOutputName(candidate));
            var runner = new ExternalToolRunner(message => DiagnosticGenerated?.Invoke(message));
            var locator = new FFmpegToolLocator();
            var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
            var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
            var processor = new ProgressiveMediaProcessor(probe, composer);
            processor.CleanupAbandonedJobs(TimeSpan.FromDays(1));
            var result = await processor.ProcessLocalAsync(
                capturedPath,
                outputBasePath,
                declaredMediaType,
                progress,
                cancellationToken).ConfigureAwait(false);
            return ToCompletedMedia(result.OutputPath);
        }
        finally
        {
            _downloadGate.Release();
        }
    }

    public async Task<CompletedMedia> ProcessCapturedHlsAsync(
        MediaCandidate candidate,
        string capturedPath,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(candidate);
        ArgumentException.ThrowIfNullOrWhiteSpace(capturedPath);
        ArgumentNullException.ThrowIfNull(progress);
        if (candidate.Kind != MediaCandidateKind.Hls
            || candidate.Origin != MediaCandidateOrigin.BrowserBlob
            || string.IsNullOrWhiteSpace(candidate.BrowserSourceId))
        {
            throw new InvalidOperationException("A browser Blob HLS candidate is required.");
        }

        var manifestText = await ReadCapturedHlsManifestAsync(
            capturedPath,
            cancellationToken).ConfigureAwait(false);
        _ = HlsPlaylistParser.Parse(manifestText, candidate.PageUri, candidate.PageUri);

        await _downloadGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            BrowserCookieSnapshot? snapshot = null;
            lock (_browserCookieSnapshotLock)
            {
                var now = DateTimeOffset.UtcNow;
                PurgeExpiredBrowserCookieSnapshotsLocked(now);
                if (_browserCookieSnapshots.Remove(
                        new BrowserCookieCapabilityKey(candidate.Uri, candidate.BrowserSourceId),
                        out var remembered)
                    && now - remembered.CapturedAt <= BrowserCookieSnapshotLifetime)
                {
                    snapshot = remembered.Snapshot;
                }

                ScheduleBrowserCookieExpiryLocked(now);
            }

            var jobCookies = CreateCookieContainer();
            new BrowserCookieSnapshotSynchronizer().Replace(jobCookies, snapshot);
            var outputDirectory = GetOutputDirectory();
            Directory.CreateDirectory(outputDirectory);
            var outputBasePath = Path.Combine(outputDirectory, CreateOutputName(candidate));
            using var job = CreateDownloadJob(candidate, jobCookies, manifestText);
            var result = await job.Coordinator.DownloadAsync(
                candidate,
                outputBasePath,
                progress,
                cancellationToken).ConfigureAwait(false);
            return ToCompletedMedia(result.OutputPath);
        }
        finally
        {
            _downloadGate.Release();
        }
    }

    private async Task<CompletedMedia> DownloadWithCoordinatorAsync(
        MediaCandidate candidate,
        CookieContainer jobCookies,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        var outputDirectory = GetOutputDirectory();

        Directory.CreateDirectory(outputDirectory);
        var outputBasePath = Path.Combine(outputDirectory, CreateOutputName(candidate));
        if (CanUseBackgroundWorker(candidate, jobCookies))
        {
            return await DownloadWithBackgroundWorkerAsync(
                candidate,
                outputBasePath,
                progress,
                cancellationToken).ConfigureAwait(false);
        }

        using var job = CreateDownloadJob(candidate, jobCookies);
        var result = await job.Coordinator.DownloadAsync(
            candidate,
            outputBasePath,
            progress,
            cancellationToken).ConfigureAwait(false);
        return ToCompletedMedia(result.OutputPath);
    }

    private async Task<CompletedMedia> DownloadWithBackgroundWorkerAsync(
        MediaCandidate candidate,
        string outputBasePath,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        const string pipeName = "HLSDownloader.Worker";
        EnsureWorkerStarted(pipeName);
        var client = new WorkerPipeClient(pipeName);
        var job = WorkerJobRecord.CreateHls(candidate, outputBasePath);
        var accepted = await client.EnqueueAsync(job, cancellationToken).ConfigureAwait(false);
        if (!accepted.Ok)
        {
            throw new InvalidOperationException(
                DiagnosticRedactor.Redact(accepted.Error ?? "バックグラウンドjobを開始できませんでした。"));
        }

        DiagnosticGenerated?.Invoke("バックグラウンドworkerへjobを引き渡しました。");
        return await WaitForBackgroundJobAsync(
            client,
            job,
            progress,
            cancelRemoteOnCancellation: true,
            cancellationToken).ConfigureAwait(false);
    }

    private async Task<CompletedMedia> WaitForBackgroundJobAsync(
        WorkerPipeClient client,
        WorkerJobRecord job,
        IProgress<DownloadProgress> progress,
        bool cancelRemoteOnCancellation,
        CancellationToken cancellationToken)
    {
        SetActiveWorkerJob(job.Id);
        try
        {
            while (true)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(500), cancellationToken).ConfigureAwait(false);
                var response = await client.GetStatusAsync(cancellationToken).ConfigureAwait(false);
                var current = response.Jobs?.FirstOrDefault(item => item.Id == job.Id)
                    ?? throw new IOException("バックグラウンドjobの状態を取得できませんでした。");
                var completed = Math.Clamp((int)Math.Round(current.Progress * 1_000), 0, 1_000);
                progress.Report(new DownloadProgress(
                    current.State == WorkerJobState.Running ? DownloadPhase.Downloading : DownloadPhase.Resolving,
                    completed,
                    1_000,
                    current.State switch
                    {
                        WorkerJobState.Queued => "バックグラウンド処理を待機中",
                        WorkerJobState.Running => "バックグラウンドで保存中",
                        _ => null
                    }));

                switch (current.State)
                {
                    case WorkerJobState.Completed when !string.IsNullOrWhiteSpace(current.OutputPath):
                        return ToCompletedMedia(current.OutputPath);
                    case WorkerJobState.Cancelled:
                        throw new OperationCanceledException("バックグラウンドjobを取り消しました。", cancellationToken);
                    case WorkerJobState.Failed:
                        throw new InvalidOperationException(DiagnosticRedactor.Redact(
                            current.Error ?? "バックグラウンドjobが失敗しました。"));
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            if (cancelRemoteOnCancellation)
            {
                using var cancelTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                try
                {
                    await client.CancelAsync(job.Id, cancelTimeout.Token).ConfigureAwait(false);
                }
                catch (Exception)
                {
                    // Cancellation remains best-effort if the worker is shutting down.
                }
            }

            throw;
        }
        finally
        {
            ClearActiveWorkerJob(job.Id);
        }
    }

    private static CompletedMedia ToCompletedMedia(string outputPath)
        => new(
            outputPath,
            Path.GetExtension(outputPath).ToLowerInvariant() switch
            {
                ".wav" => HLSDownloader.Core.MediaOutputFormat.Wav,
                ".webm" => HLSDownloader.Core.MediaOutputFormat.WebM,
                _ => HLSDownloader.Core.MediaOutputFormat.Mp4
            });

    private static string GetOutputDirectory()
    {
        var videos = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos);
        return string.IsNullOrWhiteSpace(videos)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "HLSDownloader.Windows",
                "Completed")
            : Path.Combine(videos, "HLSDownloader");
    }

    private void EnsureWorkerStarted(string pipeName)
    {
        lock (_workerStartLock)
        {
            var ledgerPath = GetWorkerLedgerPath();
            Directory.CreateDirectory(Path.GetDirectoryName(ledgerPath)!);
            var bundledToolDirectory = Path.Combine(AppContext.BaseDirectory, "tools", "ffmpeg");
            if (Directory.Exists(bundledToolDirectory))
            {
                Environment.SetEnvironmentVariable(
                    FFmpegToolLocator.ToolDirectoryEnvironmentVariable,
                    bundledToolDirectory,
                    EnvironmentVariableTarget.Process);
            }

            _ = BackgroundWorkerLauncher.Start(GetWorkerExecutablePath(), ledgerPath, pipeName);
        }
    }

    private static string GetWorkerExecutablePath()
        => Path.Combine(AppContext.BaseDirectory, "worker", "HLSDownloader.Worker.exe");

    private static string GetWorkerLedgerPath()
        => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "HLSDownloader.Windows",
            "worker",
            "jobs.json");

    private void SetActiveWorkerJob(Guid jobId)
    {
        lock (_activeWorkerJobLock)
        {
            _activeWorkerJobId = jobId;
        }
    }

    private void ClearActiveWorkerJob(Guid jobId)
    {
        lock (_activeWorkerJobLock)
        {
            if (_activeWorkerJobId == jobId)
            {
                _activeWorkerJobId = null;
            }
        }
    }

    private bool CanUseBackgroundWorker(MediaCandidate candidate, CookieContainer jobCookies)
        => candidate.Kind == MediaCandidateKind.Hls
           && candidate.Origin == MediaCandidateOrigin.Direct
           && jobCookies.Count == 0
           && string.IsNullOrEmpty(candidate.RequestedUri?.Query)
           && string.IsNullOrEmpty(candidate.Uri.Query)
           && string.IsNullOrEmpty(candidate.PageUri.Query)
           && File.Exists(GetWorkerExecutablePath());

    private DownloadJob CreateDownloadJob(
        MediaCandidate candidate,
        CookieContainer jobCookies,
        string? capturedHlsManifest = null)
    {
        BoundedHttpClient? discoveryClient = null;
        BoundedHttpClient? segmentClient = null;
        WidevineRawLicenseTransport? licenseTransport = null;
        try
        {
            IOutboundUriPolicy contentPolicy = candidate.Kind == MediaCandidateKind.WidevineDash
                ? new DownloadableWidevineUriPolicy()
                : new PublicNetworkUriPolicy();
            discoveryClient = new BoundedHttpClient(
                new BoundedHttpOptions(MaximumResponseBytes: 8 * 1024 * 1024),
                contentPolicy,
                jobCookies);
            segmentClient = new BoundedHttpClient(
                new BoundedHttpOptions(MaximumResponseBytes: 48 * 1024 * 1024),
                contentPolicy,
                jobCookies);

            var runner = new ExternalToolRunner(message => DiagnosticGenerated?.Invoke(message));
            var locator = new FFmpegToolLocator();
            var ffmpegPath = locator.ResolveFFmpeg();
            var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
            var composer = new FFmpegMediaComposer(ffmpegPath, probe, runner);
            ITextResourceFetcher playlistFetcher = capturedHlsManifest is null
                ? discoveryClient
                : new HLSDownloader.Core.CapturedRootManifestFetcher(
                    capturedHlsManifest,
                    candidate.PageUri,
                    discoveryClient);
            var planner = new HlsDownloadPlanBuilder(playlistFetcher);
            var progressiveProcessor = new ProgressiveMediaProcessor(probe, composer, segmentClient);
            progressiveProcessor.CleanupAbandonedJobs(TimeSpan.FromDays(1));
            IWidevineL3MediaProvider? widevineProvider = null;
            if (candidate.Kind == MediaCandidateKind.WidevineDash)
            {
                var widevinePolicy = new DownloadableWidevineUriPolicy();
                licenseTransport = new WidevineRawLicenseTransport(jobCookies, widevinePolicy);
                widevineProvider = new WidevineL3MediaProvider(
                    discoveryClient,
                    segmentClient,
                    _widevineCredentialSource,
                    licenseTransport,
                    ffmpegPath,
                    probe,
                    runner);
            }

            var coordinator = new HlsDownloadCoordinator(
                planner,
                segmentClient,
                composer,
                widevineProvider: widevineProvider,
                options: new HlsMediaDownloadOptions(MaximumConcurrentRequests: 2),
                progressiveProcessor: progressiveProcessor);
            coordinator.CleanupAbandonedJobs(TimeSpan.FromDays(1));
            return new DownloadJob(coordinator, discoveryClient, segmentClient, licenseTransport);
        }
        catch
        {
            licenseTransport?.Dispose();
            segmentClient?.Dispose();
            discoveryClient?.Dispose();
            throw;
        }
    }

    private static CookieContainer CreateCookieContainer()
        => new(capacity: 512, perDomainCapacity: 128, maxCookieSize: 8 * 1024);

    private static async Task<string> ReadCapturedHlsManifestAsync(
        string capturedPath,
        CancellationToken cancellationToken)
    {
        var info = new FileInfo(capturedPath);
        if (!info.Exists
            || info.LinkTarget is not null
            || info.Length is <= 0 or > MaximumCapturedHlsManifestBytes)
        {
            throw new InvalidDataException("The captured HLS manifest is missing or exceeds 4 MiB.");
        }

        var bytes = await File.ReadAllBytesAsync(capturedPath, cancellationToken).ConfigureAwait(false);
        if (bytes.Length is <= 0 or > MaximumCapturedHlsManifestBytes)
        {
            throw new InvalidDataException("The captured HLS manifest changed while it was being read.");
        }
        try
        {
            return new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
                .GetString(bytes);
        }
        catch (DecoderFallbackException exception)
        {
            throw new InvalidDataException("The captured HLS manifest is not valid UTF-8.", exception);
        }
    }

    private static string CreateOutputName(MediaCandidate candidate)
    {
        var requested = string.IsNullOrWhiteSpace(candidate.Title) ? "media" : candidate.Title.Trim();
        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var safe = new string(requested.Select(character => invalid.Contains(character) ? '_' : character).ToArray())
            .Trim(' ', '.');
        if (safe.Length == 0)
        {
            safe = "media";
        }

        if (safe.Length > 72)
        {
            safe = safe[..72];
        }

        return $"{safe}-{DateTimeOffset.Now:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}"[..Math.Min(
            safe.Length + 1 + 15 + 1 + 32,
            120)];
    }

    public void Dispose()
    {
        lock (_browserCookieSnapshotLock)
        {
            _disposed = true;
            _browserCookieSnapshots.Clear();
            _analysisCookieSnapshots.Clear();
            _widevineLicenseHints.Clear();
        }

        _browserCookieExpiryTimer.Dispose();
    }

    private void PurgeExpiredBrowserCookieSnapshots()
    {
        lock (_browserCookieSnapshotLock)
        {
            if (_disposed)
            {
                return;
            }

            var now = DateTimeOffset.UtcNow;
            PurgeExpiredBrowserCookieSnapshotsLocked(now);
            ScheduleBrowserCookieExpiryLocked(now);
        }
    }

    private void PurgeExpiredBrowserCookieSnapshotsLocked(DateTimeOffset now)
    {
        foreach (var expired in _browserCookieSnapshots
                     .Where(pair => now - pair.Value.CapturedAt >= BrowserCookieSnapshotLifetime)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            _browserCookieSnapshots.Remove(expired);
        }

        foreach (var expired in _analysisCookieSnapshots
                     .Where(pair => now - pair.Value.CapturedAt >= BrowserCookieSnapshotLifetime)
                     .Select(pair => pair.Key)
                     .ToArray())
        {
            _analysisCookieSnapshots.Remove(expired);
        }
        _widevineLicenseHints.PurgeExpired(now);
    }

    private void ScheduleBrowserCookieExpiryLocked(DateTimeOffset now)
    {
        if (_disposed)
        {
            return;
        }

        if (_browserCookieSnapshots.Count == 0
            && _analysisCookieSnapshots.Count == 0
            && _widevineLicenseHints.Count == 0)
        {
            _browserCookieExpiryTimer.Change(Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
            return;
        }

        var earliest = _browserCookieSnapshots.Values
                           .Select(entry => entry.CapturedAt)
                           .Concat(_analysisCookieSnapshots.Values.Select(entry => entry.CapturedAt))
                           .Select(capturedAt => capturedAt + BrowserCookieSnapshotLifetime)
                           .Concat(_widevineLicenseHints.NextExpiry is { } hintExpiry
                               ? [hintExpiry]
                               : [])
                           .Min();
        var dueTime = earliest > now ? earliest - now : TimeSpan.Zero;
        _browserCookieExpiryTimer.Change(dueTime, Timeout.InfiniteTimeSpan);
    }

    private sealed record RememberedBrowserCookies(
        BrowserCookieSnapshot Snapshot,
        DateTimeOffset CapturedAt);

    private readonly record struct BrowserCookieCapabilityKey(
        Uri CandidateUri,
        string? BrowserSourceId);

    private sealed class DownloadJob(
        HlsDownloadCoordinator coordinator,
        BoundedHttpClient discoveryClient,
        BoundedHttpClient segmentClient,
        WidevineRawLicenseTransport? licenseTransport) : IDisposable
    {
        public HlsDownloadCoordinator Coordinator { get; } = coordinator;

        public void Dispose()
        {
            licenseTransport?.Dispose();
            segmentClient.Dispose();
            discoveryClient.Dispose();
        }
    }

}
