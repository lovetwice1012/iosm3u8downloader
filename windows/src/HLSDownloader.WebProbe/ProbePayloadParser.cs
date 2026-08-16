using System.Text.Json;

namespace HLSDownloader.WebProbe;

public static class ProbePayloadParser
{
    public const int MaximumPayloadCharacters = 32 * 1024;
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
                emePhase);
            if (!parsed.IsManifest
                && kind is not ProbeSignalKind.MediaElement
                    and not ProbeSignalKind.EncryptedMedia
                    and not ProbeSignalKind.EncryptedMediaLifecycle)
            {
                return false;
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
        _ => ProbeSignalKind.Network
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
        => root.TryGetProperty(name, out var value) && value.TryGetInt64(out var number)
            ? number
            : null;

    private static string? Limit(string? value, int length)
        => string.IsNullOrWhiteSpace(value) ? null : value[..Math.Min(value.Length, length)];
}

public static class ResourceClassifier
{
    public static bool IsManifest(Uri url, string? mimeType = null)
    {
        var path = url.AbsolutePath;
        return path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)
            || mimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true
            || mimeType?.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) == true;
    }
}
