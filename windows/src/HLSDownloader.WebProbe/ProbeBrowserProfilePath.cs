namespace HLSDownloader.WebProbe;

public static class ProbeBrowserProfilePath
{
    public static string FromLocalApplicationData(string localApplicationData)
    {
        if (string.IsNullOrWhiteSpace(localApplicationData)
            || !Path.IsPathFullyQualified(localApplicationData))
        {
            throw new ArgumentException(
                "A fully qualified local application data directory is required.",
                nameof(localApplicationData));
        }

        return Path.Combine(
            Path.GetFullPath(localApplicationData),
            "HLSDownloader.Windows",
            "WebView2Profile");
    }
}
