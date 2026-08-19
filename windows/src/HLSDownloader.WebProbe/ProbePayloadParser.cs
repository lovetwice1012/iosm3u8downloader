using System.Text.Json;

namespace HLSDownloader.WebProbe;

public static class ProbePayloadParser
{
    public const int MaximumPayloadCharacters = 32 * 1024;
    public const long MaximumBrowserBlobBytes = 20L * 1024 * 1024 * 1024;
    private const int MaximumTextLength = 512;
    private const int MaximumUrlLength = 8 * 1024;

    public static bool TryParse(string json, ProbeSession session, out ProbeSignal? signal)
    {
        signal = null;
        if (string.IsNullOrWhiteSpace(json) || json.Length > MaximumPayloadCharacters)
        {
            return false;
        }

        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions
            {
                AllowTrailingCommas = false,
                CommentHandling = JsonCommentHandling.Disallow,
                MaxDepth = 8
            });

            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || ReadString(root, "channel") != "hls-downloader-probe"
                || ReadInt64(root, "version") != 1
                || !session.MatchesNonce(ReadString(root, "nonce")))
            {
                return false;
            }

            var rawUrl = ReadString(root, "url");
            if (!TryNormalizeHttpUrl(rawUrl, out var url))
            {
                return false;
            }

            var kind = ParseKind(ReadString(root, "kind"));
            var source = Limit(ReadString(root, "source"), 80) ?? "page";
            var mime = Limit(ReadString(root, "mime"), 160);
            var title = Limit(ReadString(root, "title"), MaximumTextLength);
            var keySystem = Limit(ReadString(root, "keySystem"), 160);
            var sequence = Math.Max(0, ReadInt64(root, "seq") ?? 0);
            var emePhase = ParseEmePhase(ReadString(root, "phase"));
            var browserObjectId = Limit(ReadString(root, "objectId"), 96);
            var byteLength = ReadInt64(root, "byteLength");
            var container = ParseContainer(ReadString(root, "container"));

            Uri? thumbnail = null;
            if (TryNormalizeHttpUrl(ReadString(root, "thumbnail"), out var parsedThumbnail))
            {
                thumbnail = parsedThumbnail;
            }

            Uri? pageUrl = null;
            if (TryNormalizeHttpUrl(ReadString(root, "pageUrl"), out var parsedPageUrl))
            {
                pageUrl = parsedPageUrl;
            }

            var parsed = new ProbeSignal(
                kind,
                url!,
                source,
                mime,
                thumbnail,
                title,
                keySystem,
                sequence,
                pageUrl,
                emePhase,
                browserObjectId,
                byteLength,
                container);
            if (!parsed.IsManifest
                && kind is not ProbeSignalKind.MediaElement
                    and not ProbeSignalKind.EncryptedMedia
                    and not ProbeSignalKind.EncryptedMediaLifecycle
                    and not ProbeSignalKind.BrowserBlob
                    and not ProbeSignalKind.MediaSource)
            {
                return false;
            }

            if (kind is ProbeSignalKind.BrowserBlob or ProbeSignalKind.MediaSource)
            {
                if (!IsValidBrowserObjectId(browserObjectId)
                    || pageUrl is null
                    || !IsSameOrigin(url!, pageUrl)
                    || (kind == ProbeSignalKind.BrowserBlob
                        && (byteLength is null or <= 0 or > MaximumBrowserBlobBytes))
                    || (kind == ProbeSignalKind.MediaSource && byteLength is not null))
                {
                    return false;
                }
            }

            if (kind == ProbeSignalKind.EncryptedMediaLifecycle
                && (emePhase is null
                    || sequence <= 0
                    || !string.Equals(keySystem, "com.widevine.alpha", StringComparison.OrdinalIgnoreCase)))
            {
                return false;
            }

            if (!session.TryAccept(parsed))
            {
                return false;
            }

            signal = parsed;
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    public static bool TryCreateHostSignal(
        string? rawUrl,
        string source,
        string? mimeType,
        ProbeSession session,
        out ProbeSignal? signal)
    {
        signal = null;
        if (!TryNormalizeHttpUrl(rawUrl, out var url))
        {
            return false;
        }

        var kind = ResourceClassifier.IsManifest(url!, mimeType)
            ? ProbeSignalKind.Manifest
            : ProbeSignalKind.Network;
        var parsed = new ProbeSignal(kind, url!, Limit(source, 80) ?? "webview", Limit(mimeType, 160));
        if (!parsed.IsManifest || !session.TryAccept(parsed))
        {
            return false;
        }

        signal = parsed;
        return true;
    }

    public static bool TryNormalizeHttpUrl(string? raw, out Uri? normalized)
    {
        normalized = null;
        if (string.IsNullOrWhiteSpace(raw) || raw.Length > MaximumUrlLength
            || !Uri.TryCreate(raw, UriKind.Absolute, out var parsed)
            || (parsed.Scheme != Uri.UriSchemeHttps && parsed.Scheme != Uri.UriSchemeHttp)
            || !string.IsNullOrEmpty(parsed.UserInfo)
            || string.IsNullOrWhiteSpace(parsed.IdnHost))
        {
            return false;
        }

        var builder = new UriBuilder(parsed) { Fragment = string.Empty };
        normalized = builder.Uri;
        return true;
    }

    private static ProbeSignalKind ParseKind(string? raw) => raw switch
    {
        "manifest" => ProbeSignalKind.Manifest,
        "media" => ProbeSignalKind.MediaElement,
        "eme" => ProbeSignalKind.EncryptedMedia,
        "eme-lifecycle" => ProbeSignalKind.EncryptedMediaLifecycle,
        "browser-blob" => ProbeSignalKind.BrowserBlob,
        "media-source" => ProbeSignalKind.MediaSource,
        _ => ProbeSignalKind.Network
    };

    private static ProbeMediaContainer ParseContainer(string? raw) => raw switch
    {
        "hls" => ProbeMediaContainer.Hls,
        "dash" => ProbeMediaContainer.Dash,
        "mp4" => ProbeMediaContainer.Mp4,
        "quicktime" => ProbeMediaContainer.QuickTime,
        "mpegts" => ProbeMediaContainer.MpegTs,
        "webm" => ProbeMediaContainer.WebM,
        "m4a" => ProbeMediaContainer.M4a,
        "mp3" => ProbeMediaContainer.Mp3,
        "aac" => ProbeMediaContainer.Aac,
        "ogg" => ProbeMediaContainer.Ogg,
        "opus" => ProbeMediaContainer.Opus,
        _ => ProbeMediaContainer.Unknown
    };

    private static ProbeEmeLifecyclePhase? ParseEmePhase(string? raw) => raw switch
    {
        "generate-request-started" => ProbeEmeLifecyclePhase.GenerateRequestStarted,
        "generate-request-succeeded" => ProbeEmeLifecyclePhase.GenerateRequestSucceeded,
        "update-succeeded" => ProbeEmeLifecyclePhase.UpdateSucceeded,
        _ => null
    };

    private static string? ReadString(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long? ReadInt64(JsonElement root, string name)
        => root.TryGetProperty(name, out var value)
           && value.ValueKind == JsonValueKind.Number
           && value.TryGetInt64(out var number)
            ? number
            : null;

    private static string? Limit(string? value, int length)
        => string.IsNullOrWhiteSpace(value) ? null : value[..Math.Min(value.Length, length)];

    private static bool IsValidBrowserObjectId(string? value)
    {
        if (string.IsNullOrEmpty(value) || value.Length > 96)
        {
            return false;
        }

        foreach (var character in value)
        {
            if (!char.IsAsciiLetterOrDigit(character) && character is not '-' and not '_')
            {
                return false;
            }
        }

        return true;
    }

    private static bool IsSameOrigin(Uri left, Uri right)
        => string.Equals(left.Scheme, right.Scheme, StringComparison.OrdinalIgnoreCase)
           && string.Equals(left.IdnHost, right.IdnHost, StringComparison.OrdinalIgnoreCase)
           && left.Port == right.Port;
}

public static class ResourceClassifier
{
    private static readonly HashSet<string> ProgressiveExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".mp4", ".mov", ".m4v", ".m4a", ".mp3", ".aac", ".ogg", ".oga", ".opus",
        ".ts", ".m2ts", ".webm"
    };

    private static readonly HashSet<string> FragmentExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".m4s", ".cmfv", ".cmfa"
    };

    private static readonly HashSet<string> ProgressiveMimeTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "video/mp4", "video/quicktime", "video/x-m4v", "audio/mp4", "audio/x-m4a",
        "audio/mpeg", "audio/aac", "audio/ogg", "application/ogg", "audio/opus",
        "video/mp2t", "video/mpeg", "video/webm", "audio/webm"
    };

    public static bool IsManifest(Uri url, string? mimeType = null)
    {
        var path = url.AbsolutePath;
        return path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)
            || mimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true
            || mimeType?.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) == true;
    }

    public static bool IsProgressiveMedia(Uri url, string? mimeType = null)
    {
        ArgumentNullException.ThrowIfNull(url);
        var extension = Path.GetExtension(url.AbsolutePath);
        if (FragmentExtensions.Contains(extension))
        {
            return false;
        }
        if (ProgressiveExtensions.Contains(extension))
        {
            return true;
        }

        if (string.IsNullOrWhiteSpace(mimeType))
        {
            return false;
        }

        var separator = mimeType.IndexOf(';');
        var normalized = (separator < 0 ? mimeType : mimeType[..separator]).Trim();
        return ProgressiveMimeTypes.Contains(normalized);
    }
}
