namespace HLSDownloader.Media;

public sealed class FFmpegToolLocator
{
    public const string ToolDirectoryEnvironmentVariable = "HLS_DOWNLOADER_FFMPEG_DIR";

    private readonly string? _explicitDirectory;

    public FFmpegToolLocator(string? explicitDirectory = null)
    {
        _explicitDirectory = explicitDirectory;
    }

    public string ResolveFFmpeg() => Resolve("ffmpeg");

    public string ResolveFFprobe() => Resolve("ffprobe");

    private string Resolve(string toolName)
    {
        string executable = OperatingSystem.IsWindows() ? $"{toolName}.exe" : toolName;
        foreach (string directory in CandidateDirectories())
        {
            string candidate = Path.GetFullPath(Path.Combine(directory, executable));
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }

        string? path = Environment.GetEnvironmentVariable("PATH");
        if (!string.IsNullOrWhiteSpace(path))
        {
            foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                try
                {
                    string candidate = Path.GetFullPath(Path.Combine(directory, executable));
                    if (File.Exists(candidate))
                    {
                        return candidate;
                    }
                }
                catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
                {
                    // Ignore malformed PATH entries and continue with the remaining candidates.
                }
            }
        }

        throw new FileNotFoundException(
            $"{executable} was not found. Install FFmpeg on PATH or set {ToolDirectoryEnvironmentVariable}.");
    }

    private IEnumerable<string> CandidateDirectories()
    {
        if (!string.IsNullOrWhiteSpace(_explicitDirectory))
        {
            yield return _explicitDirectory;
        }

        string? configured = Environment.GetEnvironmentVariable(ToolDirectoryEnvironmentVariable);
        if (!string.IsNullOrWhiteSpace(configured))
        {
            yield return configured;
        }

        yield return Path.Combine(AppContext.BaseDirectory, "tools", "ffmpeg");
        yield return AppContext.BaseDirectory;
    }
}
