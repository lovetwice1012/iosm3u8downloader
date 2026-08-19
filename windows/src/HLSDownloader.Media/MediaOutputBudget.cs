namespace HLSDownloader.Media;

internal static class MediaOutputBudget
{
    internal const long AbsoluteMaximumBytes = 64L * 1024 * 1024 * 1024;
    internal const long RequiredFreeSpaceReserveBytes = 512L * 1024 * 1024;
    internal const long MinimumWritableBytes = 1024 * 1024;

    internal static long LimitForPath(string outputPath, long requestedMaximumBytes = AbsoluteMaximumBytes)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(outputPath);
        string fullPath = Path.GetFullPath(outputPath);
        string directory = Path.GetDirectoryName(fullPath)
            ?? throw new IOException("The media output directory could not be resolved.");
        Directory.CreateDirectory(directory);
        string root = Path.GetPathRoot(directory)
            ?? throw new IOException("The media output volume could not be resolved.");
        var drive = new DriveInfo(root);
        if (!drive.IsReady)
            throw new IOException("The media output volume is not ready.");
        return CalculateLimit(drive.AvailableFreeSpace, requestedMaximumBytes);
    }

    internal static long CalculateLimit(long availableFreeSpace, long requestedMaximumBytes = AbsoluteMaximumBytes)
    {
        if (availableFreeSpace < 0 || requestedMaximumBytes < MinimumWritableBytes)
            throw new ArgumentOutOfRangeException();

        long availableAfterReserve = availableFreeSpace - RequiredFreeSpaceReserveBytes;
        long limit = Math.Min(
            availableAfterReserve,
            Math.Min(requestedMaximumBytes, AbsoluteMaximumBytes));
        if (limit < MinimumWritableBytes)
            throw new IOException("There is not enough free space to safely create the media output.");
        return limit;
    }

    internal static void EnsureBelowLimit(string path, long limit)
    {
        var file = new FileInfo(path);
        file.Refresh();
        if (!file.Exists || file.Length <= 0 || file.Length >= limit)
            throw new IOException("The generated media output is empty or reached its bounded size limit.");
    }

    internal static void EnsureFits(string destinationPath, long requiredBytes, long requestedMaximumBytes = AbsoluteMaximumBytes)
    {
        if (requiredBytes <= 0 || requiredBytes >= LimitForPath(destinationPath, requestedMaximumBytes))
            throw new IOException("The media output cannot fit within the safe storage budget.");
    }
}
