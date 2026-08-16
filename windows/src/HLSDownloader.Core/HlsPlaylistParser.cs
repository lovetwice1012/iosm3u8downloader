using System.Globalization;

namespace HLSDownloader.Core;

public static class HlsPlaylistParser
{
    public static bool IsPlaylist(string text) => Normalize(text).StartsWith("#EXTM3U", StringComparison.Ordinal);

    public static HlsPlaylist Parse(string text, Uri effectiveUri, Uri? referer = null)
    {
        if (!effectiveUri.IsAbsoluteUri) throw new PlaylistException("The effective URI must be absolute.");
        var normalized = Normalize(text);
        if (!normalized.StartsWith("#EXTM3U", StringComparison.Ordinal))
            throw new PlaylistException("The playlist does not start with #EXTM3U.");
        var lines = normalized.Split('\n').Select(x => x.Trim()).Where(x => x.Length > 0).ToArray();
        if (lines.Contains("#EXT-X-I-FRAMES-ONLY", StringComparer.Ordinal))
            throw new PlaylistException("I-frame-only playlists cannot be saved as normal media.");
        return lines.Any(x => x.StartsWith("#EXT-X-STREAM-INF:", StringComparison.Ordinal))
            ? ParseMaster(lines, effectiveUri)
            : ParseMedia(lines, effectiveUri, referer);
    }

    private static HlsMasterPlaylist ParseMaster(string[] lines, Uri baseUri)
    {
        var variants = new List<HlsVariant>();
        var renditions = new List<HlsRendition>();
        Dictionary<string, string>? pending = null;
        foreach (var line in lines)
        {
            if (line.StartsWith("#EXT-X-STREAM-INF:", StringComparison.Ordinal))
            {
                if (pending is not null) throw new PlaylistException("A variant URI is missing.");
                pending = ParseAttributes(AfterColon(line));
            }
            else if (line.StartsWith("#EXT-X-MEDIA:", StringComparison.Ordinal))
            {
                var a = ParseAttributes(AfterColon(line));
                if (!a.TryGetValue("TYPE", out var type) || !a.TryGetValue("GROUP-ID", out var group)) continue;
                renditions.Add(new(
                    type.ToUpperInvariant(), group, a.GetValueOrDefault("NAME") ?? group,
                    a.TryGetValue("URI", out var raw) ? UriUtilities.Resolve(baseUri, raw) : null,
                    IsYes(a.GetValueOrDefault("DEFAULT")), IsYes(a.GetValueOrDefault("AUTOSELECT"))));
            }
            else if (!line.StartsWith('#') && pending is not null)
            {
                variants.Add(new(
                    UriUtilities.Resolve(baseUri, line),
                    ParseLong(pending.GetValueOrDefault("BANDWIDTH"), 0),
                    TryLong(pending.GetValueOrDefault("AVERAGE-BANDWIDTH")),
                    pending.GetValueOrDefault("RESOLUTION"), pending.GetValueOrDefault("AUDIO")));
                pending = null;
            }
        }
        if (pending is not null) throw new PlaylistException("A variant URI is missing.");
        if (variants.Count == 0) throw new PlaylistException("The master playlist has no variants.");
        return new(baseUri, variants, renditions);
    }

    private static HlsMediaPlaylist ParseMedia(string[] lines, Uri baseUri, Uri? referer)
    {
        var segments = new List<HlsSegment>();
        ulong mediaSequence = 0;
        double? duration = null;
        (long Length, long? Offset)? pendingRange = null;
        (Uri Uri, long End)? previousRange = null;
        HlsEncryption? encryption = null;
        HlsInitializationMap? map = null;
        var discontinuity = false;
        var gap = false;
        var endList = false;

        foreach (var line in lines)
        {
            if (line.StartsWith("#EXT-X-MEDIA-SEQUENCE:", StringComparison.Ordinal))
            {
                if (!ulong.TryParse(AfterColon(line), NumberStyles.None, CultureInfo.InvariantCulture, out mediaSequence))
                    throw new PlaylistException("Invalid EXT-X-MEDIA-SEQUENCE.");
            }
            else if (line.StartsWith("#EXTINF:", StringComparison.Ordinal))
            {
                var raw = AfterColon(line).Split(',', 2)[0];
                if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ||
                    !double.IsFinite(parsed) || parsed < 0) throw new PlaylistException("Invalid EXTINF duration.");
                duration = parsed;
            }
            else if (line.StartsWith("#EXT-X-BYTERANGE:", StringComparison.Ordinal)) pendingRange = ParseRangeSpec(AfterColon(line));
            else if (line.StartsWith("#EXT-X-KEY:", StringComparison.Ordinal)) encryption = ParseEncryption(line, baseUri);
            else if (line.StartsWith("#EXT-X-MAP:", StringComparison.Ordinal))
            {
                var a = ParseAttributes(AfterColon(line));
                if (!a.TryGetValue("URI", out var raw)) throw new PlaylistException("EXT-X-MAP has no URI.");
                HlsByteRange? range = null;
                if (a.TryGetValue("BYTERANGE", out var rawRange))
                {
                    var spec = ParseRangeSpec(rawRange);
                    if (spec.Offset is null) throw new PlaylistException("EXT-X-MAP BYTERANGE requires an offset.");
                    range = MakeRange(spec.Offset.Value, spec.Length);
                }
                if (encryption?.Method == HlsEncryptionMethod.Aes128 && encryption.ExplicitIv is null)
                    throw new PlaylistException("Encrypted EXT-X-MAP requires an explicit IV for AES-128.");
                map = new(UriUtilities.Resolve(baseUri, raw), range, encryption);
            }
            else if (line == "#EXT-X-DISCONTINUITY") discontinuity = true;
            else if (line == "#EXT-X-GAP") gap = true;
            else if (line == "#EXT-X-ENDLIST") endList = true;
            else if (!line.StartsWith('#'))
            {
                if (gap) throw new PlaylistException("EXT-X-GAP segments are unsupported.");
                if (duration is null) throw new PlaylistException("A segment URI has no EXTINF.");
                var uri = UriUtilities.Resolve(baseUri, line);
                HlsByteRange? range = null;
                if (pendingRange is { } spec)
                {
                    var offset = spec.Offset ?? (previousRange is { } previous && previous.Uri == uri
                        ? previous.End : throw new PlaylistException("Implicit BYTERANGE has no matching predecessor."));
                    range = MakeRange(offset, spec.Length);
                    previousRange = (uri, range.ExclusiveEnd);
                }
                else previousRange = null;
                ulong sequence;
                try { sequence = checked(mediaSequence + (ulong)segments.Count); }
                catch (OverflowException) { throw new PlaylistException("Media sequence overflow."); }
                segments.Add(new(segments.Count, sequence, duration.Value, uri, range, encryption, map, discontinuity));
                duration = null;
                pendingRange = null;
                discontinuity = false;
                gap = false;
            }
        }
        if (duration is not null || pendingRange is not null) throw new PlaylistException("Incomplete final media segment.");
        if (segments.Count == 0) throw new PlaylistException("The media playlist has no segments.");
        return new(baseUri, segments, endList, referer);
    }

    private static HlsEncryption? ParseEncryption(string line, Uri baseUri)
    {
        var a = ParseAttributes(AfterColon(line));
        var method = a.GetValueOrDefault("METHOD")?.ToUpperInvariant() ?? "NONE";
        if (method == "NONE") return null;
        var parsed = method switch
        {
            "AES-128" => HlsEncryptionMethod.Aes128,
            "SAMPLE-AES" => HlsEncryptionMethod.SampleAes,
            _ => throw new PlaylistException($"Unsupported encryption method: {method}.")
        };
        var keyFormat = a.GetValueOrDefault("KEYFORMAT") ?? "identity";
        if (!keyFormat.Equals("identity", StringComparison.OrdinalIgnoreCase))
            throw new PlaylistException("FairPlay and other non-identity key formats are unsupported.");
        if (!a.TryGetValue("URI", out var raw)) throw new PlaylistException("EXT-X-KEY has no URI.");
        return new(parsed, UriUtilities.Resolve(baseUri, raw),
            a.TryGetValue("IV", out var iv) ? ParseIv(iv) : null);
    }

    internal static Dictionary<string, string> ParseAttributes(string value)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var i = 0;
        while (i < value.Length)
        {
            while (i < value.Length && (value[i] == ',' || char.IsWhiteSpace(value[i]))) i++;
            var equals = value.IndexOf('=', i);
            if (equals < 0) break;
            var name = value[i..equals].Trim();
            i = equals + 1;
            string parsed;
            if (i < value.Length && value[i] == '"')
            {
                i++;
                var chars = new List<char>();
                while (i < value.Length && value[i] != '"')
                {
                    if (value[i] == '\\' && i + 1 < value.Length) i++;
                    chars.Add(value[i++]);
                }
                if (i >= value.Length) throw new PlaylistException("Unterminated quoted attribute.");
                i++;
                parsed = new(chars.ToArray());
            }
            else
            {
                var comma = value.IndexOf(',', i);
                if (comma < 0) comma = value.Length;
                parsed = value[i..comma].Trim();
                i = comma;
            }
            if (name.Length > 0) result[name] = parsed;
            while (i < value.Length && value[i] != ',') i++;
            if (i < value.Length) i++;
        }
        return result;
    }

    private static byte[] ParseIv(string raw)
    {
        var hex = raw.StartsWith("0x", StringComparison.OrdinalIgnoreCase) ? raw[2..] : raw;
        if (hex.Length is 0 or > 32 || hex.Any(c => !Uri.IsHexDigit(c))) throw new PlaylistException("Invalid AES IV.");
        hex = hex.PadLeft(32, '0');
        return Convert.FromHexString(hex);
    }

    private static (long Length, long? Offset) ParseRangeSpec(string raw)
    {
        var parts = raw.Trim('"').Split('@', 2);
        if (!long.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var length) || length <= 0)
            throw new PlaylistException("Invalid BYTERANGE length.");
        long? offset = null;
        if (parts.Length == 2)
        {
            if (!long.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var parsed) || parsed < 0)
                throw new PlaylistException("Invalid BYTERANGE offset.");
            offset = parsed;
        }
        return (length, offset);
    }

    private static HlsByteRange MakeRange(long offset, long length)
    {
        if (offset < 0 || length <= 0) throw new PlaylistException("Invalid BYTERANGE.");
        try { _ = checked(offset + length); }
        catch (OverflowException) { throw new PlaylistException("BYTERANGE overflow."); }
        return new(offset, length);
    }

    private static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal)
        .Replace('\r', '\n').Trim('\uFEFF', ' ', '\t', '\n');
    private static string AfterColon(string line) => line[(line.IndexOf(':') + 1)..];
    private static bool IsYes(string? value) => value?.Equals("YES", StringComparison.OrdinalIgnoreCase) == true;
    private static long ParseLong(string? value, long fallback) => long.TryParse(value, out var parsed) ? parsed : fallback;
    private static long? TryLong(string? value) => long.TryParse(value, out var parsed) ? parsed : null;
}
