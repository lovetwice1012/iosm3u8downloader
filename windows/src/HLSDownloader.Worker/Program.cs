using HLSDownloader.Media;
using HLSDownloader.Worker;
using HLSDownloader.Core;
using System.Net;

string applicationData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
string ledgerPath = GetOption(args, "--ledger") ?? Path.Combine(applicationData, "HLSDownloader", "worker", "jobs.json");
string pipeName = GetOption(args, "--pipe") ?? "HLSDownloader.Worker";
string portableToolDirectory = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "tools", "ffmpeg"));
var locator = new FFmpegToolLocator(portableToolDirectory);
if (args.Contains("--check-tools", StringComparer.OrdinalIgnoreCase))
{
    Console.WriteLine(locator.ResolveFFmpeg());
    Console.WriteLine(locator.ResolveFFprobe());
    return 0;
}

// A replacement launched while the idle instance is stopping waits here instead
// of exiting. Keep this top-level entry point synchronous after acquisition:
// System.Threading.Mutex must be released by the thread that acquired it.
using var singleInstance = WorkerSingleInstanceLease.TryAcquire(pipeName, TimeSpan.FromSeconds(5));
if (singleInstance is null)
{
    return 0;
}

using var shutdown = new CancellationTokenSource();
Console.CancelKeyPress += (_, eventArgs) =>
{
    eventArgs.Cancel = true;
    shutdown.Cancel();
};

var fileLog = new WorkerFileLog(Path.Combine(Path.GetDirectoryName(Path.GetFullPath(ledgerPath))!, "worker.log"));
void Log(string message)
{
    string safe = DiagnosticRedactor.Redact(message);
    Console.Error.WriteLine($"[{DateTimeOffset.Now:O}] {safe}");
    fileLog.Write(safe);
}
var runner = new ExternalToolRunner(Log);
var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
var composer = new FFmpegMediaComposer(locator.ResolveFFmpeg(), probe, runner);
var cookies = new CookieContainer();
using var discoveryHttp = new BoundedHttpClient(
    new BoundedHttpOptions(MaximumResponseBytes: 8 * 1024 * 1024),
    cookies: cookies);
using var segmentHttp = new BoundedHttpClient(
    new BoundedHttpOptions(MaximumResponseBytes: 48 * 1024 * 1024),
    cookies: cookies);
var hlsCoordinator = new HlsDownloadCoordinator(
    new HlsDownloadPlanBuilder(discoveryHttp),
    segmentHttp,
    composer,
    options: new HlsMediaDownloadOptions(MaximumConcurrentRequests: 2));
var ledger = new JobLedger(ledgerPath);
var coordinator = new WorkerCoordinator(ledger, composer, hlsCoordinator, Log);
var pipeServer = new WorkerPipeServer(pipeName, ledger, coordinator, shutdown);
var idleMonitor = new WorkerIdleShutdownMonitor(coordinator, shutdown, TimeSpan.FromSeconds(60));

try
{
    Task.WhenAll(
        coordinator.RunAsync(shutdown.Token),
        pipeServer.RunAsync(shutdown.Token),
        idleMonitor.RunAsync(shutdown.Token)).GetAwaiter().GetResult();
}
catch (OperationCanceledException) when (shutdown.IsCancellationRequested)
{
    // Graceful shutdown requested through the pipe or Ctrl+C.
}

return 0;

static string? GetOption(string[] arguments, string name)
{
    int index = Array.FindIndex(arguments, argument => argument.Equals(name, StringComparison.OrdinalIgnoreCase));
    if (index < 0)
    {
        return null;
    }

    if (index == arguments.Length - 1 || arguments[index + 1].StartsWith("--", StringComparison.Ordinal))
    {
        throw new ArgumentException($"{name} requires a value.");
    }

    return arguments[index + 1];
}
