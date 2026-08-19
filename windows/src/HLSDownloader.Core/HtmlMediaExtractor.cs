using System.Text.RegularExpressions;
using AngleSharp.Html.Parser;

namespace HLSDownloader.Core;

public sealed record ExtractedMediaReference(
    Uri Uri,
    MediaCandidateKind Kind,
    MediaCandidateOrigin Origin,
    Uri? PosterUri,
    string? Title);

public sealed record ExtractedFrameReference(Uri? Uri, string? SourceDocument, string? Title);

public sealed record HtmlMediaExtraction(
    Uri DocumentUri,
    Uri BaseUri,
    string? Title,
    Uri? ThumbnailUri,
    IReadOnlyList<ExtractedMediaReference> Media,
    IReadOnlyList<ExtractedFrameReference> Frames);

public static partial class HtmlMediaExtractor
{
    private static readonly string[] MediaAttributeNames =
    [
        "src", "data-src", "data-hls", "data-hls-src", "data-dash-src", "data-mpd",
        "data-video-src", "data-playlist", "data-file", "data-url"
    ];

    private static readonly string[] FrameAttributeNames = ["src", "data-src", "data-lazy-src", "data-url"];

    public static HtmlMediaExtraction Extract(string html, Uri documentUri)
    {
        ArgumentNullException.ThrowIfNull(html);
        if (!UriUtilities.IsHttp(documentUri)) throw new CoreException("The HTML document URI must be HTTP(S).");
        var document = new HtmlParser().ParseDocument(html);
        var baseUri = ResolveOptional(documentUri, document.QuerySelector("base[href]")?.GetAttribute("href")) ?? documentUri;
        var pageTitle = Clean(document.Title) ?? Clean(document.QuerySelector("meta[property='og:title']")?.GetAttribute("content"));
        var thumbnail = ResolveOptional(baseUri,
            document.QuerySelector("meta[property='og:image']")?.GetAttribute("content") ??
            document.QuerySelector("meta[name='twitter:image']")?.GetAttribute("content"));

        var media = new List<ExtractedMediaReference>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var element in document.All)
        {
            var localName = element.LocalName.ToLowerInvariant();
            var origin = localName switch
            {
                "video" => MediaCandidateOrigin.Video,
                "source" => MediaCandidateOrigin.Source,
                _ => MediaCandidateOrigin.DataAttribute
            };
            var parentVideo = localName == "source" ? element.ParentElement?.Closest("video") : null;
            var mime = element.GetAttribute("type");
            var poster = ResolveOptional(baseUri,
                element.GetAttribute("poster") ?? element.GetAttribute("data-poster") ?? parentVideo?.GetAttribute("poster"));
            var title = Clean(element.GetAttribute("title") ?? element.GetAttribute("aria-label") ??
                              parentVideo?.GetAttribute("title")) ?? pageTitle;
            foreach (var attribute in MediaAttributeNames)
            {
                var raw = element.GetAttribute(attribute);
                if (!TryMedia(baseUri, raw, mime, out var uri, out var kind)) continue;
                var key = $"{kind}:{uri.AbsoluteUri}";
                if (seen.Add(key)) media.Add(new(uri, kind, origin, poster ?? thumbnail, title));
            }
        }

        foreach (var script in document.Scripts)
        {
            foreach (Match match in ManifestPattern().Matches(DecodeEscapes(script.TextContent)))
            {
                if (!TryMedia(baseUri, match.Groups[1].Value, null, out var uri, out var kind)) continue;
                var key = $"{kind}:{uri.AbsoluteUri}";
                if (seen.Add(key)) media.Add(new(uri, kind, MediaCandidateOrigin.InlineScript, thumbnail, pageTitle));
            }
        }

        var frames = new List<ExtractedFrameReference>();
        var seenFrames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var frame in document.QuerySelectorAll("iframe"))
        {
            var title = Clean(frame.GetAttribute("title") ?? frame.GetAttribute("aria-label"));
            var srcdoc = frame.GetAttribute("srcdoc");
            if (!string.IsNullOrWhiteSpace(srcdoc))
            {
                frames.Add(new(null, srcdoc, title));
                continue;
            }
            foreach (var name in FrameAttributeNames)
            {
                var uri = ResolveOptional(baseUri, frame.GetAttribute(name));
                if (uri is not null && seenFrames.Add(uri.AbsoluteUri)) frames.Add(new(uri, null, title));
            }
        }
        return new(documentUri, baseUri, pageTitle, thumbnail, media, frames);
    }

    private static bool TryMedia(
        Uri baseUri, string? raw, string? mimeType, out Uri uri, out MediaCandidateKind kind)
    {
        uri = null!;
        kind = default;
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var candidate = ResolveOptional(baseUri, DecodeEscapes(raw));
        if (candidate is null) return false;
        var path = candidate.AbsolutePath;
        if (mimeType?.Contains("dash+xml", StringComparison.OrdinalIgnoreCase) == true ||
            path.EndsWith(".mpd", StringComparison.OrdinalIgnoreCase)) kind = MediaCandidateKind.WidevineDash;
        else if (mimeType?.Contains("mpegurl", StringComparison.OrdinalIgnoreCase) == true ||
                  path.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase)) kind = MediaCandidateKind.Hls;
        else if (ProgressiveMediaHintClassifier.IsSupportedHint(candidate, mimeType))
            kind = MediaCandidateKind.Progressive;
        else return false;
        uri = candidate;
        return true;
    }

    private static Uri? ResolveOptional(Uri baseUri, string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        try { return UriUtilities.Resolve(baseUri, raw); }
        catch (CoreException) { return null; }
    }

    private static string DecodeEscapes(string value) => System.Net.WebUtility.HtmlDecode(value)
        .Replace("\\/", "/", StringComparison.Ordinal)
        .Replace("\\u0026", "&", StringComparison.OrdinalIgnoreCase)
        .Replace("\\x26", "&", StringComparison.OrdinalIgnoreCase);

    private static string? Clean(string? value)
    {
        var cleaned = string.Join(' ', (value ?? string.Empty).Split((char[]?)null,
            StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        if (cleaned.Length == 0) return null;
        return cleaned.Length <= 256 ? cleaned : cleaned[..256];
    }

    [GeneratedRegex("""(?i)((?:https?:)?//[^\s"'<>\\]+?\.(?:m3u8|mpd)(?:\?[^\s"'<>\\]*)?|(?:\.\.?/|/)[^\s"'<>\\]+?\.(?:m3u8|mpd)(?:\?[^\s"'<>\\]*)?|[A-Za-z0-9_%@+.-]+(?:/[A-Za-z0-9_%@+.,~!$&()*;=:-]+)*\.(?:m3u8|mpd)(?:\?[^\s"'<>\\]*)?)""",
        RegexOptions.CultureInvariant, 200)]
    private static partial Regex ManifestPattern();
}
