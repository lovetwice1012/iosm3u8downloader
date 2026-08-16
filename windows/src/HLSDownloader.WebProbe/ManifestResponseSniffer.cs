using System.Buffers;
using System.Text;

namespace HLSDownloader.WebProbe;

public enum SniffedManifestKind
{
    None,
    Hls,
    Dash
}

/// <summary>
/// Restricts response-body inspection to small, plausibly textual responses and
/// classifies only an HLS or DASH signature at the start of the response.
/// </summary>
public static class ManifestResponseSniffer
{
    public const int MaximumPrefixBytes = 32 * 1024;
    public const long MaximumDeclaredContentLength = 512 * 1024;

    private static readonly HashSet<string> InspectableMimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "application/octet-stream",
        "application/xml",
        "binary/octet-stream",
        "text/plain",
        "text/xml"
    };

    private static readonly HashSet<string> KnownBinaryExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".aac",
        ".avif",
        ".bin",
        ".gif",
        ".jpeg",
        ".jpg",
        ".m4a",
        ".m4s",
        ".mp3",
        ".mp4",
        ".png",
        ".ts",
        ".webm",
        ".webp",
        ".woff",
        ".woff2"
    };

    public static bool ShouldInspect(
        Uri responseUri,
        string? contentType,
        long? declaredContentLength,
        int statusCode)
    {
        ArgumentNullException.ThrowIfNull(responseUri);

        if (statusCode is < 200 or >= 300
            || !responseUri.IsAbsoluteUri
            || (responseUri.Scheme != Uri.UriSchemeHttp && responseUri.Scheme != Uri.UriSchemeHttps)
            || !string.IsNullOrEmpty(responseUri.UserInfo)
            || string.IsNullOrWhiteSpace(responseUri.IdnHost)
            || contentType?.Length > 256
            || ResourceClassifier.IsManifest(responseUri, contentType)
            || declaredContentLength is null or <= 0 or > MaximumDeclaredContentLength)
        {
            return false;
        }

        if (KnownBinaryExtensions.Contains(Path.GetExtension(responseUri.AbsolutePath)))
        {
            return false;
        }

        var normalizedContentType = NormalizeContentType(contentType);
        return normalizedContentType.Length == 0 || InspectableMimeTypes.Contains(normalizedContentType);
    }

    public static async Task<SniffedManifestKind> ClassifyPrefixAsync(
        Stream content,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(content);

        var buffer = ArrayPool<byte>.Shared.Rent(MaximumPrefixBytes);
        try
        {
            var length = 0;
            while (length < MaximumPrefixBytes)
            {
                var read = await content.ReadAsync(
                    buffer.AsMemory(length, MaximumPrefixBytes - length),
                    cancellationToken);
                if (read == 0)
                {
                    break;
                }

                length += read;
            }

            return ClassifyPrefix(buffer.AsSpan(0, length));
        }
        finally
        {
            ArrayPool<byte>.Shared.Return(buffer, clearArray: true);
        }
    }

    public static SniffedManifestKind ClassifyPrefix(ReadOnlySpan<byte> prefix)
    {
        if (prefix.IsEmpty)
        {
            return SniffedManifestKind.None;
        }

        var text = DecodePrefix(prefix);
        var position = SkipWhitespace(text, 0);
        if (text.AsSpan(position).StartsWith("#EXTM3U", StringComparison.Ordinal))
        {
            return SniffedManifestKind.Hls;
        }

        position = SkipXmlPreamble(text, position);
        if (position < 0 || !text.AsSpan(position).StartsWith("<MPD", StringComparison.Ordinal))
        {
            return SniffedManifestKind.None;
        }

        var boundary = position + 4;
        return boundary < text.Length
               && (char.IsWhiteSpace(text[boundary]) || text[boundary] is '>' or '/')
            ? SniffedManifestKind.Dash
            : SniffedManifestKind.None;
    }

    public static bool TryResolveRedirectTarget(Uri responseUri, string? location, out Uri? target)
    {
        target = null;
        if (string.IsNullOrWhiteSpace(location)
            || location.Length > 8 * 1024
            || !Uri.TryCreate(responseUri, location, out var resolved))
        {
            return false;
        }

        return ProbePayloadParser.TryNormalizeHttpUrl(resolved.AbsoluteUri, out target);
    }

    private static string NormalizeContentType(string? contentType)
    {
        if (string.IsNullOrWhiteSpace(contentType))
        {
            return string.Empty;
        }

        var separator = contentType.IndexOf(';');
        return (separator < 0 ? contentType : contentType[..separator]).Trim();
    }

    private static string DecodePrefix(ReadOnlySpan<byte> prefix)
    {
        if (prefix.StartsWith(new byte[] { 0xFF, 0xFE }))
        {
            return Encoding.Unicode.GetString(prefix[2..]);
        }

        if (prefix.StartsWith(new byte[] { 0xFE, 0xFF }))
        {
            return Encoding.BigEndianUnicode.GetString(prefix[2..]);
        }

        if (prefix.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
        {
            prefix = prefix[3..];
        }

        return Encoding.UTF8.GetString(prefix);
    }

    private static int SkipXmlPreamble(string text, int position)
    {
        while (position < text.Length)
        {
            position = SkipWhitespace(text, position);
            if (text.AsSpan(position).StartsWith("<?", StringComparison.Ordinal))
            {
                position = SkipDelimited(text, position + 2, "?>");
            }
            else if (text.AsSpan(position).StartsWith("<!--", StringComparison.Ordinal))
            {
                position = SkipDelimited(text, position + 4, "-->");
            }
            else if (text.AsSpan(position).StartsWith("<!DOCTYPE", StringComparison.OrdinalIgnoreCase))
            {
                position = SkipDelimited(text, position + 9, ">");
            }
            else
            {
                return position;
            }

            if (position < 0)
            {
                return -1;
            }
        }

        return position;
    }

    private static int SkipDelimited(string text, int start, string delimiter)
    {
        var end = text.IndexOf(delimiter, start, StringComparison.Ordinal);
        return end < 0 ? -1 : end + delimiter.Length;
    }

    private static int SkipWhitespace(string text, int position)
    {
        while (position < text.Length && char.IsWhiteSpace(text[position]))
        {
            position++;
        }

        return position;
    }
}
