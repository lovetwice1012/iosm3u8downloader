using System.Text;
using HLSDownloader.Core;

namespace HLSDownloader.Worker;

public sealed class WorkerFileLog
{
    private const long MaximumLogBytes = 2 * 1024 * 1024;
    private readonly string _path;
    private readonly object _gate = new();

    public WorkerFileLog(string path)
    {
        _path = Path.GetFullPath(path);
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
    }

    public void Write(string message)
    {
        string safe = DiagnosticRedactor.Redact(message).Replace('\r', ' ').Replace('\n', ' ');
        string line = $"[{DateTimeOffset.Now:O}] {safe}{Environment.NewLine}";
        lock (_gate)
        {
            try
            {
                RotateIfNeeded(Encoding.UTF8.GetByteCount(line));
                File.AppendAllText(_path, line, new UTF8Encoding(false));
            }
            catch (IOException)
            {
                // Logging must never terminate a download.
            }
            catch (UnauthorizedAccessException)
            {
                // Logging must never terminate a download.
            }
        }
    }

    private void RotateIfNeeded(int incomingBytes)
    {
        if (!File.Exists(_path) || new FileInfo(_path).Length + incomingBytes <= MaximumLogBytes)
        {
            return;
        }

        File.Move(_path, _path + ".1", overwrite: true);
    }
}
