namespace HLSDownloader.Core;

/// <summary>
/// Classifies only explicit URL/MIME hints for complete progressive resources.
/// This is discovery metadata, not a trust boundary; the media pipeline must
/// still verify container magic, DRM metadata, and real tracks before saving.
/// </summary>
public static class ProgressiveMediaHintClassifier
{
    private static readonly HashSet<string> Extensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".mov", ".m4v", ".m4a", ".mp3", ".aac", ".ogg", ".oga", ".opus",
        ".ts", ".m2ts", ".webm"
    };

    private static readonly HashSet<string> FragmentExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".m4s", ".cmfv", ".cmfa"
    };

    private static readonly HashSet<string> MimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "video/mp4", "video/quicktime", "video/x-m4v", "audio/mp4", "audio/x-m4a",
        "audio/mpeg", "audio/aac", "audio/ogg", "application/ogg", "audio/opus",
        "video/mp2t", "video/mpeg", "video/webm", "audio/webm"
    };

    public static bool IsSupportedHint(Uri uri, string? mimeType = null)
    {
        ArgumentNullException.ThrowIfNull(uri);
        var extension = Path.GetExtension(uri.AbsolutePath);
        if (FragmentExtensions.Contains(extension))
        {
            return false;
        }

        return Extensions.Contains(extension) || IsSupportedMimeType(mimeType);
    }

    public static bool IsSupportedMimeType(string? mimeType)
    {
        if (string.IsNullOrWhiteSpace(mimeType))
        {
            return false;
        }

        var separator = mimeType.IndexOf(';');
        var normalized = (separator < 0 ? mimeType : mimeType[..separator]).Trim();
        return MimeTypes.Contains(normalized);
    }

    public static bool HasSupportedMagic(ReadOnlySpan<byte> prefix)
    {
        if (prefix.Length >= 12 && prefix[4..8].SequenceEqual("ftyp"u8))
        {
            return true;
        }

        ReadOnlySpan<byte> ebml = [0x1A, 0x45, 0xDF, 0xA3];
        if (prefix.StartsWith(ebml)
            || prefix.StartsWith("OggS"u8)
            || prefix.StartsWith("ID3"u8)
            || prefix.Length >= 2 && prefix[0] == 0xFF && (prefix[1] & 0xE0) == 0xE0)
        {
            return true;
        }

        if (prefix.Length < 188 * 3)
        {
            return false;
        }

        for (var offset = 0; offset < 188; offset++)
        {
            if (prefix[offset] == 0x47
                && prefix[offset + 188] == 0x47
                && prefix[offset + 376] == 0x47)
            {
                return true;
            }
        }

        return false;
    }
}
