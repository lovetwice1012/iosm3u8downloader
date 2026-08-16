using HLSDownloader.Core;
using HLSDownloader.Media;
using HLSDownloader.Worker;
using System.Net;

namespace HLSDownloader.Windows.Services;

/// <summary>
/// Thin UI boundary around the portable discovery and media pipeline.
/// </summary>
public sealed class CoreMediaWorkflow : IMediaWorkflow, IDisposable
{
    private readonly BoundedHttpClient _discoveryClient;
    private readonly BoundedHttpClient _segmentClient;
    private readonly CookieContainer _cookies;
    private HlsDownloadCoordinator? _coordinator;
    private readonly object _workerStartLock = new();
    private readonly object _activeWorkerJobLock = new();
    private Guid? _activeWorkerJobId;

    public CoreMediaWorkflow()
    {
        _cookies = new CookieContainer();
        _discoveryClient = new BoundedHttpClient(
            new BoundedHttpOptions(MaximumResponseBytes: 8 * 1024 * 1024),
            cookies: _cookies);
        _segmentClient = new BoundedHttpClient(
            new BoundedHttpOptions(MaximumResponseBytes: 48 * 1024 * 1024),
            cookies: _cookies);
    }

    public event Action<string>? DiagnosticGenerated;

    public bool CanDownload(MediaCandidate candidate, out string reason)
    {
        if (candidate.Kind == MediaCandidateKind.Hls)
        {
            reason = "再生・保存に対応";
            return true;
        }

        reason = candidate.CanDownload
            ? "このビルドではWidevine L3保存providerが未接続です"
            : "許可されていないhostのWidevineは再生・保存できません";
        return false;
    }

    public void ImportBrowserCookies(Uri scope, IReadOnlyList<BrowserSessionCookie> cookies)
    {
        if (!(scope.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
              || scope.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            || !string.IsNullOrEmpty(scope.UserInfo)
            || cookies.Count > 128)
        {
            return;
        }

        foreach (var source in cookies)
        {
            if (!IsSafeCookie(source, scope))
            {
                continue;
            }

            var rawDomain = source.Domain.Trim();
            var domain = rawDomain.TrimStart('.').ToLowerInvariant();
            var cookieDomain = rawDomain.StartsWith(".", StringComparison.Ordinal)
                ? "." + domain
                : scope.IdnHost;
            try
            {
                var cookie = new Cookie(source.Name, source.Value, source.Path, cookieDomain)
                {
                    Secure = source.IsSecure,
                    HttpOnly = source.IsHttpOnly
                };
                if (source.Expires is { } expires)
                {
                    cookie.Expires = expires.UtcDateTime;
                }

                _cookies.Add(cookie);
            }
            catch (CookieException)
            {
                // Ignore malformed browser-profile data without exposing its value.
            }
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
        var resolver = new MediaSourceResolver(_discoveryClient);
        var resolution = await resolver.ResolveAsync(input, cancellationToken).ConfigureAwait(false);
        return resolution.Candidates;
    }

    public Task<CompletedMedia> DownloadAsync(
        MediaCandidate candidate,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        if (!CanDownload(candidate, out var reason))
        {
            throw new InvalidOperationException(reason);
        }

        return DownloadWithCoordinatorAsync(candidate, progress, cancellationToken);
    }

    private async Task<CompletedMedia> DownloadWithCoordinatorAsync(
        MediaCandidate candidate,
        IProgress<DownloadProgress> progress,
        CancellationToken cancellationToken)
    {
        var outputDirectory = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            "HLSDownloader");
        if (string.IsNullOrWhiteSpace(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos)))
        {
            outputDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "HLSDownloader.Windows",
                "Completed");
        }

        Directory.CreateDirectory(outputDirectory);
        var outputBasePath = Path.Combine(outputDirectory, CreateOutputName(candidate));
        if (CanUseBackgroundWorker(candidate))
        {
            return await DownloadWithBackgroundWorkerAsync(
                candidate,
                outputBasePath,
                progress,
                cancellationToken).ConfigureAwait(false);
        }

        var coordinator = _coordinator ??= CreateCoordinator();
        var result = await coordinator.DownloadAsync(
            candidate,
            outputBasePath,
            progress,
            cancellationToken).ConfigureAwait(false);
        return new CompletedMedia(
            result.OutputPath,
            result.OutputFormat == HLSDownloader.Media.MediaOutputFormat.Wav
                ? HLSDownloader.Core.MediaOutputFormat.Wav
                : HLSDownloader.Core.MediaOutputFormat.Mp4);
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
            Path.GetExtension(outputPath).Equals(".wav", StringComparison.OrdinalIgnoreCase)
                ? HLSDownloader.Core.MediaOutputFormat.Wav
                : HLSDownloader.Core.MediaOutputFormat.Mp4);

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

    private bool CanUseBackgroundWorker(MediaCandidate candidate)
        => candidate.Kind == MediaCandidateKind.Hls
           && candidate.Origin == MediaCandidateOrigin.Direct
           && _cookies.Count == 0
           && string.IsNullOrEmpty(candidate.RequestedUri?.Query)
           && string.IsNullOrEmpty(candidate.Uri.Query)
           && string.IsNullOrEmpty(candidate.PageUri.Query)
           && File.Exists(GetWorkerExecutablePath());

    private static bool IsSafeCookie(BrowserSessionCookie cookie, Uri scope)
    {
        if (string.IsNullOrWhiteSpace(cookie.Name)
            || cookie.Name.Length > 256
            || cookie.Value.Length > 4096
            || cookie.Domain.Length > 255
            || cookie.Path.Length is < 1 or > 2048
            || !cookie.Path.StartsWith("/", StringComparison.Ordinal)
            || cookie.Name.Any(IsUnsafeCookieCharacter)
            || cookie.Value.Any(character => character is '\r' or '\n' or '\0')
            || cookie.IsSecure && scope.Scheme != Uri.UriSchemeHttps)
        {
            return false;
        }

        var domain = cookie.Domain.Trim().TrimStart('.');
        return domain.Length > 0
               && (scope.IdnHost.Equals(domain, StringComparison.OrdinalIgnoreCase)
                   || scope.IdnHost.EndsWith("." + domain, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsUnsafeCookieCharacter(char character)
        => char.IsControl(character) || character is '(' or ')' or '<' or '>' or '@' or ',' or ';' or ':'
            or '\\' or '"' or '/' or '[' or ']' or '?' or '=' or '{' or '}' or ' ' or '\t';

    private HlsDownloadCoordinator CreateCoordinator()
    {
        var runner = new ExternalToolRunner(message => DiagnosticGenerated?.Invoke(message));
        var locator = new FFmpegToolLocator();
        var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
        var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
        var planner = new HlsDownloadPlanBuilder(_discoveryClient);
        var coordinator = new HlsDownloadCoordinator(
            planner,
            _segmentClient,
            composer,
            options: new HlsMediaDownloadOptions(MaximumConcurrentRequests: 2));
        coordinator.CleanupAbandonedJobs(TimeSpan.FromDays(1));
        return coordinator;
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
        _discoveryClient.Dispose();
        _segmentClient.Dispose();
    }

}
