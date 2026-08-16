namespace HLSDownloader.Windows.ViewModels;

public sealed class DiagnosticEntry
{
    public DiagnosticEntry(DateTimeOffset timestamp, string level, string message)
    {
        Timestamp = timestamp;
        Level = level;
        Message = message;
    }

    public DateTimeOffset Timestamp { get; set; }

    public string Level { get; set; }

    public string Message { get; set; }

    public string Display => $"{Timestamp:HH:mm:ss} [{Level}] {Message}";
}
