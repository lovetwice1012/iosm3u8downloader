namespace HLSDownloader.WebProbe;

public static class BrowserCaptureStoragePolicy
{
    public const long RequiredFreeSpaceReserveBytes = 512L * 1024 * 1024;

    public static bool CanCapture(long availableFreeSpace, long expectedLength)
    {
        if (availableFreeSpace < 0 || expectedLength <= 0)
        {
            return false;
        }

        long safeAvailable = availableFreeSpace - RequiredFreeSpaceReserveBytes;
        return safeAvailable > 0 && expectedLength < safeAvailable;
    }
}
