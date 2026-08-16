using System.Globalization;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Xml;
using System.Xml.Linq;

namespace HLSDownloader.Media;

internal enum WidevineDashMediaType { Video, Audio }
internal enum WidevineCommonEncryptionScheme { Cenc, Cbcs }

internal sealed record WidevineDashSegmentReference(
    Uri Uri,
    Uri Referer,
    long? RangeOffset = null,
    long? RangeLength = null);

internal sealed record WidevineDashTrackPlan(
    WidevineDashMediaType MediaType,
    string RepresentationId,
    ulong? Bandwidth,
    byte[] KeyId,
    WidevineCommonEncryptionScheme? Scheme,
    IReadOnlyList<byte[]> PsshData,
    IReadOnlyList<Uri> LicenseUris,
    WidevineDashSegmentReference Initialization,
    IReadOnlyList<WidevineDashSegmentReference> Segments);

internal sealed record WidevineDashDownloadPlan(
    WidevineDashTrackPlan? Video,
    WidevineDashTrackPlan? Audio,
    Uri LicenseUri)
{
    public MediaOutputFormat OutputFormat => Video is null ? MediaOutputFormat.Wav : MediaOutputFormat.Mp4;
    public IEnumerable<WidevineDashTrackPlan> Tracks => new[] { Video, Audio }.Where(track => track is not null)!;
}

internal sealed class WidevineDashManifestException(string message) : Exception(message);

internal static partial class WidevineDashManifestParser
{
    private const int MaximumManifestBytes = 4 * 1024 * 1024;
    private const int MaximumElements = 100_000;
    private const int MaximumSegmentsPerTrack = 100_000;
    private const string WidevineSystemId = "edef8ba9-79d6-4ace-a3c8-27dcd51d21ed";
    private const string WidevineUrn = "urn:uuid:" + WidevineSystemId;
    private const string Mp4ProtectionUrn = "urn:mpeg:dash:mp4protection:2011";

    public static WidevineDashDownloadPlan Parse(
        ReadOnlyMemory<byte> document,
        Uri effectiveUri,
        Func<Uri, bool> isPermittedUri,
        Uri? observedLicenseUri = null)
    {
        ArgumentNullException.ThrowIfNull(effectiveUri);
        ArgumentNullException.ThrowIfNull(isPermittedUri);
        if (document.Length is <= 0 or > MaximumManifestBytes)
            throw Error("The Widevine MPD size is invalid.");
        EnsurePermitted(effectiveUri, isPermittedUri, "manifest");

        XDocument xml;
        try
        {
            using var stream = new MemoryStream(document.ToArray(), writable: false);
            using XmlReader reader = XmlReader.Create(stream, new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Prohibit,
                XmlResolver = null,
                MaxCharactersInDocument = MaximumManifestBytes,
                IgnoreComments = true,
                IgnoreProcessingInstructions = true
            });
            xml = XDocument.Load(reader, LoadOptions.None);
        }
        catch (Exception exception) when (exception is XmlException or InvalidOperationException)
        {
            throw new WidevineDashManifestException($"The Widevine MPD XML is invalid: {exception.Message}");
        }

        XElement root = xml.Root ?? throw Error("The Widevine MPD has no root element.");
        if (!NameIs(root, "MPD")) throw Error("The document root is not MPD.");
        if (root.DescendantsAndSelf().Take(MaximumElements + 1).Count() > MaximumElements)
            throw Error("The Widevine MPD exceeds the element complexity limit.");
        if (string.Equals(Attribute(root, "type"), "dynamic", StringComparison.OrdinalIgnoreCase))
            throw Error("Dynamic Widevine MPD export is unsupported.");

        XElement[] periods = Children(root, "Period").Where(period => Children(period, "AdaptationSet").Any()).ToArray();
        if (periods.Length != 1) throw Error("Exactly one media Period is required.");
        XElement period = periods[0];
        WidevineDashTrackPlan? video = SelectTrack(root, period, WidevineDashMediaType.Video, effectiveUri, isPermittedUri);
        WidevineDashTrackPlan? audio = SelectTrack(root, period, WidevineDashMediaType.Audio, effectiveUri, isPermittedUri);
        if (video is null && audio is null) throw Error("The Widevine MPD has no supported MP4 audio or video track.");

        var licenseCandidates = new HashSet<string>(StringComparer.Ordinal);
        foreach (WidevineDashTrackPlan track in new[] { video, audio }.OfType<WidevineDashTrackPlan>())
        {
            foreach (Uri candidate in track.LicenseUris)
            {
                EnsurePermitted(candidate, isPermittedUri, "license");
                licenseCandidates.Add(candidate.AbsoluteUri);
            }
        }
        if (licenseCandidates.Count > 1)
            throw Error("The Widevine MPD identifies multiple license URLs.");

        if (observedLicenseUri is not null)
        {
            EnsurePermitted(observedLicenseUri, isPermittedUri, "observed license");
        }

        Uri licenseUri;
        if (licenseCandidates.Count == 1)
        {
            licenseUri = new Uri(licenseCandidates.Single(), UriKind.Absolute);
            if (observedLicenseUri is not null
                && Uri.Compare(
                    licenseUri,
                    observedLicenseUri,
                    UriComponents.HttpRequestUrl,
                    UriFormat.UriEscaped,
                    StringComparison.Ordinal) != 0)
            {
                throw Error("The observed Widevine license URL does not match the MPD license URL.");
            }
        }
        else
        {
            licenseUri = observedLicenseUri
                ?? throw Error("The Widevine MPD does not identify a license URL and no verified playback observation was supplied.");
        }

        return new(video, audio, licenseUri);
    }

    private static WidevineDashTrackPlan? SelectTrack(
        XElement root,
        XElement period,
        WidevineDashMediaType requestedType,
        Uri effectiveUri,
        Func<Uri, bool> isPermittedUri)
    {
        var candidates = new List<(XElement Adaptation, XElement Representation, ulong Score)>();
        foreach (XElement adaptation in Children(period, "AdaptationSet"))
        {
            foreach (XElement representation in Children(adaptation, "Representation"))
            {
                if (ResolveMediaType(adaptation, representation) != requestedType || !IsMp4(adaptation, representation)) continue;
                ulong bandwidth = UnsignedAttribute(representation, "bandwidth") ?? 0;
                ulong score = requestedType == WidevineDashMediaType.Video
                    ? checked(Math.Min(UnsignedAttribute(representation, "width") ?? 0, 100_000) *
                              Math.Min(UnsignedAttribute(representation, "height") ?? 0, 100_000) * 1_000_000 + bandwidth)
                    : bandwidth;
                candidates.Add((adaptation, representation, score));
            }
        }
        if (candidates.Count == 0) return null;
        (XElement selectedAdaptation, XElement selectedRepresentation, _) = candidates.MaxBy(candidate => candidate.Score);
        string representationId = Attribute(selectedRepresentation, "id")?.Trim() ?? string.Empty;
        if (string.IsNullOrEmpty(representationId) || representationId.Length > 1_024)
            throw Error("The selected Widevine representation has no safe ID.");

        XElement[][] protectionLevels =
        [
            DirectProtections(selectedRepresentation),
            DirectProtections(selectedAdaptation),
            DirectProtections(period),
            DirectProtections(root)
        ];
        byte[][] declaredIds = protectionLevels
            .Select(level => level.SelectMany(DefaultKeyIds).Distinct(ByteArrayComparer.Instance).ToArray())
            .FirstOrDefault(ids => ids.Length > 0) ?? [];

        var pssh = new List<byte[]>();
        var psshKeyIds = new HashSet<byte[]>(ByteArrayComparer.Instance);
        foreach (XElement protection in ProtectionChain(root, period, selectedAdaptation, selectedRepresentation).Where(IsWidevineProtection))
        {
            foreach (XElement psshElement in protection.Descendants().Where(element => NameIs(element, "pssh")))
            {
                string compact = string.Concat(psshElement.Value.Where(character => !char.IsWhiteSpace(character)));
                if (compact.Length == 0 || compact.Length > 2 * MaximumManifestBytes)
                    throw Error("The Widevine PSSH text is invalid.");
                byte[] box;
                try { box = Convert.FromBase64String(compact); }
                catch (FormatException) { throw Error("The Widevine PSSH is not valid base64."); }
                if (!IsWidevinePsshBox(box)) throw Error("A Widevine ContentProtection element contains a non-Widevine or malformed PSSH box.");
                byte[] payload = WidevinePssh.Payload(box, 2 * 1024 * 1024);
                IReadOnlyCollection<ByteString>? ids = WidevinePssh.KeyIdsFromPayload(payload);
                if (ids is not null)
                    foreach (ByteString id in ids) psshKeyIds.Add(id.Span.ToArray());
                if (!pssh.Any(existing => existing.AsSpan().SequenceEqual(box))) pssh.Add(box);
                CryptographicOperations.ZeroMemory(payload);
            }
        }
        if (pssh.Count == 0) throw Error("The selected Widevine representation has no PSSH.");
        byte[][] keyIds = declaredIds.Length > 0 ? declaredIds : psshKeyIds.ToArray();
        if (keyIds.Length != 1) throw Error("Widevine key rotation inside one selected representation is unsupported.");

        WidevineCommonEncryptionScheme? scheme = ResolveScheme(ProtectionChain(root, period, selectedAdaptation, selectedRepresentation));
        Uri[] licenseUris = ProtectionChain(root, period, selectedAdaptation, selectedRepresentation)
            .Where(IsWidevineProtection)
            .SelectMany(protection => LicenseUris(protection, effectiveUri))
            .DistinctBy(uri => uri.AbsoluteUri, StringComparer.Ordinal)
            .ToArray();
        foreach (Uri licenseUri in licenseUris) EnsurePermitted(licenseUri, isPermittedUri, "license");
        Uri baseUri = ResolveBaseUri(root, period, selectedAdaptation, selectedRepresentation, effectiveUri, isPermittedUri);
        SegmentTemplateData? template = MergeTemplates(root, period, selectedAdaptation, selectedRepresentation);
        SegmentListData? list = MergeLists(root, period, selectedAdaptation, selectedRepresentation);
        (WidevineDashSegmentReference initialization, IReadOnlyList<WidevineDashSegmentReference> segments) references;
        if (template is not null)
        {
            references = TemplateReferences(
                template,
                representationId,
                UnsignedAttribute(selectedRepresentation, "bandwidth"),
                baseUri,
                effectiveUri,
                Attribute(period, "duration") ?? Attribute(root, "mediaPresentationDuration"),
                isPermittedUri);
        }
        else if (list is not null)
        {
            references = ListReferences(list, baseUri, effectiveUri, isPermittedUri);
        }
        else
        {
            throw Error("The selected Widevine representation has no SegmentTemplate or SegmentList.");
        }

        return new(
            requestedType,
            representationId,
            UnsignedAttribute(selectedRepresentation, "bandwidth"),
            keyIds[0],
            scheme,
            pssh,
            licenseUris,
            references.initialization,
            references.segments);
    }

    private static WidevineDashMediaType? ResolveMediaType(XElement adaptation, XElement representation)
    {
        string? value = Attribute(representation, "contentType") ?? Attribute(adaptation, "contentType");
        if (string.Equals(value, "video", StringComparison.OrdinalIgnoreCase)) return WidevineDashMediaType.Video;
        if (string.Equals(value, "audio", StringComparison.OrdinalIgnoreCase)) return WidevineDashMediaType.Audio;
        string mime = Attribute(representation, "mimeType") ?? Attribute(adaptation, "mimeType") ?? string.Empty;
        if (mime.StartsWith("video/", StringComparison.OrdinalIgnoreCase)) return WidevineDashMediaType.Video;
        if (mime.StartsWith("audio/", StringComparison.OrdinalIgnoreCase)) return WidevineDashMediaType.Audio;
        string codecs = Attribute(representation, "codecs") ?? Attribute(adaptation, "codecs") ?? string.Empty;
        if (codecs.StartsWith("avc", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("hvc", StringComparison.OrdinalIgnoreCase) ||
            codecs.StartsWith("hev", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("av01", StringComparison.OrdinalIgnoreCase))
            return WidevineDashMediaType.Video;
        if (codecs.StartsWith("mp4a", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("ac-3", StringComparison.OrdinalIgnoreCase) ||
            codecs.StartsWith("ec-3", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("opus", StringComparison.OrdinalIgnoreCase))
            return WidevineDashMediaType.Audio;
        return null;
    }

    private static bool IsMp4(XElement adaptation, XElement representation)
    {
        string mime = Attribute(representation, "mimeType") ?? Attribute(adaptation, "mimeType") ?? string.Empty;
        if (mime.Contains("webm", StringComparison.OrdinalIgnoreCase)) return false;
        if (mime.Contains("mp4", StringComparison.OrdinalIgnoreCase)) return true;
        string codecs = Attribute(representation, "codecs") ?? Attribute(adaptation, "codecs") ?? string.Empty;
        return codecs.StartsWith("avc", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("hvc", StringComparison.OrdinalIgnoreCase) ||
               codecs.StartsWith("hev", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("av01", StringComparison.OrdinalIgnoreCase) ||
               codecs.StartsWith("mp4a", StringComparison.OrdinalIgnoreCase) || codecs.StartsWith("ac-3", StringComparison.OrdinalIgnoreCase) ||
               codecs.StartsWith("ec-3", StringComparison.OrdinalIgnoreCase);
    }

    private static XElement[] ProtectionChain(XElement root, XElement period, XElement adaptation, XElement representation)
        => DirectProtections(root).Concat(DirectProtections(period)).Concat(DirectProtections(adaptation)).Concat(DirectProtections(representation)).ToArray();
    private static XElement[] DirectProtections(XElement parent) => Children(parent, "ContentProtection").ToArray();

    private static bool IsWidevineProtection(XElement protection)
    {
        if (string.Equals(Attribute(protection, "schemeIdUri")?.Trim(), WidevineUrn, StringComparison.OrdinalIgnoreCase)) return true;
        foreach (XElement pssh in protection.Descendants().Where(element => NameIs(element, "pssh")))
        {
            try
            {
                byte[] data = Convert.FromBase64String(string.Concat(pssh.Value.Where(character => !char.IsWhiteSpace(character))));
                if (IsWidevinePsshBox(data)) return true;
            }
            catch (Exception exception) when (exception is FormatException or WidevineL3ClientException) { }
        }
        return false;
    }

    private static bool IsWidevinePsshBox(ReadOnlySpan<byte> data)
    {
        if (data.Length < 32 || !data.Slice(4, 4).SequenceEqual("pssh"u8)) return false;
        uint size32 = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(data);
        int versionOffset;
        ulong declaredSize;
        if (size32 == 1)
        {
            if (data.Length < 40) return false;
            declaredSize = System.Buffers.Binary.BinaryPrimitives.ReadUInt64BigEndian(data[8..]);
            versionOffset = 16;
        }
        else
        {
            declaredSize = size32 == 0 ? (ulong)data.Length : size32;
            versionOffset = 8;
        }
        if (declaredSize != (ulong)data.Length || data.Length - versionOffset < 20) return false;
        ReadOnlySpan<byte> systemId = [
            0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce,
            0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed];
        return data.Slice(versionOffset + 4, 16).SequenceEqual(systemId);
    }

    private static IEnumerable<byte[]> DefaultKeyIds(XElement protection)
    {
        string? raw = protection.Attributes().FirstOrDefault(attribute => attribute.Name.LocalName.Equals("default_KID", StringComparison.OrdinalIgnoreCase))?.Value;
        if (string.IsNullOrWhiteSpace(raw)) yield break;
        foreach (string value in raw.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            string compact = value.Trim().Replace("urn:uuid:", string.Empty, StringComparison.OrdinalIgnoreCase).Replace("-", string.Empty, StringComparison.Ordinal);
            if (compact.Length != 32) throw Error("A Widevine default_KID is invalid.");
            byte[] id;
            try { id = Convert.FromHexString(compact); }
            catch (FormatException) { throw Error("A Widevine default_KID is invalid."); }
            yield return id;
        }
    }

    private static WidevineCommonEncryptionScheme? ResolveScheme(IEnumerable<XElement> protections)
    {
        var schemes = new HashSet<WidevineCommonEncryptionScheme>();
        foreach (XElement protection in protections)
        {
            if (!string.Equals(Attribute(protection, "schemeIdUri")?.Trim(), Mp4ProtectionUrn, StringComparison.OrdinalIgnoreCase)) continue;
            string value = (Attribute(protection, "value") ?? string.Empty).Split(':')[0].Trim();
            if (value.Equals("cenc", StringComparison.OrdinalIgnoreCase)) schemes.Add(WidevineCommonEncryptionScheme.Cenc);
            else if (value.Equals("cbcs", StringComparison.OrdinalIgnoreCase)) schemes.Add(WidevineCommonEncryptionScheme.Cbcs);
            else throw Error("The MPD declares an unsupported common-encryption scheme.");
        }
        if (schemes.Count > 1) throw Error("The selected representation declares conflicting encryption schemes.");
        return schemes.Count == 0 ? null : schemes.Single();
    }

    private static IEnumerable<Uri> LicenseUris(XElement protection, Uri baseUri)
    {
        foreach (XElement element in protection.DescendantsAndSelf())
        {
            string name = element.Name.LocalName;
            if (element != protection && !name.Contains("license", StringComparison.OrdinalIgnoreCase) && !name.Contains("laurl", StringComparison.OrdinalIgnoreCase)) continue;
            foreach (string attributeName in new[] { "licenseUrl", "licenseURL", "laurl", "href" })
            {
                string? raw = element.Attributes().FirstOrDefault(attribute => attribute.Name.LocalName.Equals(attributeName, StringComparison.OrdinalIgnoreCase))?.Value;
                if (TryResolveWebUri(raw, baseUri, out Uri? value)) yield return value!;
            }
            if (element != protection && TryResolveWebUri(element.Value.Trim(), baseUri, out Uri? textValue)) yield return textValue!;
        }
    }

    private static Uri ResolveBaseUri(
        XElement root,
        XElement period,
        XElement adaptation,
        XElement representation,
        Uri effectiveUri,
        Func<Uri, bool> policy)
    {
        Uri current = effectiveUri;
        foreach (XElement level in new[] { root, period, adaptation, representation })
        {
            XElement? baseElement = Children(level, "BaseURL").FirstOrDefault();
            if (baseElement is null) continue;
            string raw = baseElement.Value.Trim();
            if (raw.Length is <= 0 or > 16_384 || !Uri.TryCreate(current, raw, out Uri? resolved))
                throw Error("A Widevine BaseURL is invalid.");
            current = NormalizeNetworkUri(resolved);
            EnsurePermitted(current, policy, "BaseURL");
        }
        return current;
    }

    private static SegmentTemplateData? MergeTemplates(params XElement[] levels)
    {
        SegmentTemplateData? result = null;
        foreach (XElement level in levels)
        {
            XElement? element = Children(level, "SegmentTemplate").FirstOrDefault();
            if (element is null) continue;
            SegmentTemplateData value = SegmentTemplateData.Parse(element);
            result = result is null ? value : result.Merge(value);
        }
        return result;
    }

    private static SegmentListData? MergeLists(params XElement[] levels)
    {
        SegmentListData? result = null;
        foreach (XElement level in levels)
        {
            XElement? element = Children(level, "SegmentList").FirstOrDefault();
            if (element is null) continue;
            SegmentListData value = SegmentListData.Parse(element);
            result = result is null ? value : result.Merge(value);
        }
        return result;
    }

    private static (WidevineDashSegmentReference initialization, IReadOnlyList<WidevineDashSegmentReference> segments) TemplateReferences(
        SegmentTemplateData template,
        string representationId,
        ulong? bandwidth,
        Uri baseUri,
        Uri referer,
        string? periodDuration,
        Func<Uri, bool> policy)
    {
        if (string.IsNullOrWhiteSpace(template.Initialization) || string.IsNullOrWhiteSpace(template.Media))
            throw Error("The Widevine SegmentTemplate is incomplete.");
        ulong startNumber = template.StartNumber ?? 1;
        IReadOnlyList<SegmentPoint> points = SegmentPoints(template, periodDuration, startNumber);
        if (points.Count is <= 0 or > MaximumSegmentsPerTrack) throw Error("The Widevine segment count is invalid.");
        string initializationText = ExpandTemplate(template.Initialization, representationId, bandwidth, startNumber, points[0].Time);
        var initialization = new WidevineDashSegmentReference(ResolveSegment(initializationText, baseUri, policy), referer);
        var segments = new List<WidevineDashSegmentReference>(points.Count);
        foreach (SegmentPoint point in points)
        {
            string value = ExpandTemplate(template.Media, representationId, bandwidth, point.Number, point.Time);
            segments.Add(new(ResolveSegment(value, baseUri, policy), referer));
        }
        return (initialization, segments);
    }

    private static IReadOnlyList<SegmentPoint> SegmentPoints(SegmentTemplateData template, string? periodDuration, ulong startNumber)
    {
        if (template.Timeline.Count > 0)
        {
            var result = new List<SegmentPoint>();
            ulong currentTime = 0, number = startNumber;
            for (int index = 0; index < template.Timeline.Count; index++)
            {
                TimelineEntry entry = template.Timeline[index];
                if (entry.Duration is not > 0) throw Error("A Widevine SegmentTimeline duration is invalid.");
                if (entry.StartTime is < 0) throw Error("A Widevine SegmentTimeline time is invalid.");
                if (entry.StartTime is { } start) currentTime = checked((ulong)start);
                ulong repeat;
                if ((entry.RepeatCount ?? 0) >= 0) repeat = checked((ulong)(entry.RepeatCount ?? 0) + 1);
                else if (entry.RepeatCount == -1)
                {
                    if (index + 1 < template.Timeline.Count && template.Timeline[index + 1].StartTime is { } next && next > (long)currentTime)
                        repeat = Ceiling(checked((ulong)next - currentTime), entry.Duration.Value);
                    else if (template.EndNumber is { } timelineEnd && timelineEnd >= number) repeat = checked(timelineEnd - number + 1);
                    else if (ParseDuration(periodDuration) is { } seconds)
                    {
                        double scaled = Math.Ceiling(seconds * (template.Timescale ?? 1));
                        if (!double.IsFinite(scaled) || scaled <= currentTime || scaled > ulong.MaxValue) throw Error("A Widevine SegmentTimeline repeat is invalid.");
                        repeat = Ceiling((ulong)scaled - currentTime, entry.Duration.Value);
                    }
                    else throw Error("An open-ended Widevine SegmentTimeline cannot be bounded.");
                }
                else throw Error("A Widevine SegmentTimeline repeat is invalid.");
                if (repeat == 0 || repeat > (ulong)(MaximumSegmentsPerTrack - result.Count)) throw Error("The Widevine segment limit was exceeded.");
                for (ulong occurrence = 0; occurrence < repeat; occurrence++)
                {
                    result.Add(new(number, currentTime));
                    number = checked(number + 1);
                    currentTime = checked(currentTime + entry.Duration.Value);
                }
            }
            return result;
        }
        if (template.Duration is not > 0) throw Error("The Widevine SegmentTemplate duration is missing.");
        ulong count;
        if (template.EndNumber is { } endNumber && endNumber >= startNumber) count = checked(endNumber - startNumber + 1);
        else if (ParseDuration(periodDuration) is { } seconds)
        {
            double calculated = Math.Ceiling(seconds * (template.Timescale ?? 1) / template.Duration.Value);
            if (!double.IsFinite(calculated) || calculated <= 0 || calculated > MaximumSegmentsPerTrack) throw Error("The Widevine segment count is invalid.");
            count = (ulong)calculated;
        }
        else throw Error("The Widevine SegmentTemplate cannot be bounded.");
        if (count == 0 || count > MaximumSegmentsPerTrack) throw Error("The Widevine segment limit was exceeded.");
        return Enumerable.Range(0, (int)count)
            .Select(offset => new SegmentPoint(checked(startNumber + (ulong)offset), checked((ulong)offset * template.Duration.Value)))
            .ToArray();
    }

    private static (WidevineDashSegmentReference initialization, IReadOnlyList<WidevineDashSegmentReference> segments) ListReferences(
        SegmentListData list,
        Uri baseUri,
        Uri referer,
        Func<Uri, bool> policy)
    {
        if (list.Segments.Count is <= 0 or > MaximumSegmentsPerTrack) throw Error("The Widevine SegmentList count is invalid.");
        Uri initializationUri;
        if (!string.IsNullOrWhiteSpace(list.InitializationSource)) initializationUri = ResolveSegment(list.InitializationSource, baseUri, policy);
        else if (list.InitializationRange is not null) initializationUri = baseUri;
        else throw Error("The Widevine SegmentList initialization is missing.");
        (long? initOffset, long? initLength) = ParseRange(list.InitializationRange);
        var initialization = new WidevineDashSegmentReference(initializationUri, referer, initOffset, initLength);
        var segments = new List<WidevineDashSegmentReference>(list.Segments.Count);
        foreach (SegmentListEntry entry in list.Segments)
        {
            Uri uri = !string.IsNullOrWhiteSpace(entry.Media) ? ResolveSegment(entry.Media, baseUri, policy)
                : entry.MediaRange is not null ? baseUri
                : throw Error("A Widevine SegmentURL is incomplete.");
            (long? offset, long? length) = ParseRange(entry.MediaRange);
            segments.Add(new(uri, referer, offset, length));
        }
        return (initialization, segments);
    }

    private static Uri ResolveSegment(string raw, Uri baseUri, Func<Uri, bool> policy)
    {
        if (raw.Length is <= 0 or > 16_384 || !Uri.TryCreate(baseUri, raw, out Uri? uri)) throw Error("A Widevine segment URL is invalid.");
        uri = NormalizeNetworkUri(uri);
        EnsurePermitted(uri, policy, "segment");
        return uri;
    }

    private static Uri NormalizeNetworkUri(Uri value)
    {
        if (!value.IsAbsoluteUri || !value.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrEmpty(value.IdnHost) || !string.IsNullOrEmpty(value.UserInfo)) throw Error("A Widevine network URL is unsafe.");
        var builder = new UriBuilder(value) { Fragment = string.Empty };
        return builder.Uri;
    }

    private static void EnsurePermitted(Uri uri, Func<Uri, bool> policy, string kind)
    {
        if (!policy(uri)) throw Error($"The Widevine {kind} URL is outside the permitted exact HTTPS host.");
    }

    private static bool TryResolveWebUri(string? raw, Uri baseUri, out Uri? value)
    {
        value = null;
        if (string.IsNullOrWhiteSpace(raw) || raw.Length > 16_384 || !Uri.TryCreate(baseUri, raw.Trim(), out Uri? resolved)) return false;
        try { value = NormalizeNetworkUri(resolved); return true; }
        catch (WidevineDashManifestException) { return false; }
    }

    private static string ExpandTemplate(string template, string representationId, ulong? bandwidth, ulong number, ulong time)
    {
        var result = new System.Text.StringBuilder(template.Length + 32);
        for (int index = 0; index < template.Length;)
        {
            if (template[index] != '$') { result.Append(template[index++]); continue; }
            if (index + 1 < template.Length && template[index + 1] == '$') { result.Append('$'); index += 2; continue; }
            int end = template.IndexOf('$', index + 1);
            if (end < 0) throw Error("A Widevine segment template token is unterminated.");
            string token = template[(index + 1)..end];
            string[] pieces = token.Split('%', 2);
            string value;
            if (pieces[0] == "RepresentationID")
            {
                if (pieces.Length != 1) throw Error("RepresentationID cannot use numeric formatting.");
                value = representationId;
            }
            else
            {
                ulong numeric = pieces[0] switch
                {
                    "Bandwidth" when bandwidth is not null => bandwidth.Value,
                    "Number" => number,
                    "Time" => time,
                    _ => throw Error("A Widevine segment template token is unsupported.")
                };
                if (pieces.Length == 1) value = numeric.ToString(CultureInfo.InvariantCulture);
                else
                {
                    Match match = NumericFormatRegex().Match(pieces[1]);
                    if (!match.Success || !int.TryParse(match.Groups[1].Value, out int width) || width is < 1 or > 20)
                        throw Error("A Widevine numeric segment template format is invalid.");
                    value = numeric.ToString("D" + width, CultureInfo.InvariantCulture);
                }
            }
            result.Append(value);
            index = end + 1;
        }
        if (result.Length is <= 0 or > 16_384) throw Error("The expanded Widevine segment URL is invalid.");
        return result.ToString();
    }

    private static (long? Offset, long? Length) ParseRange(string? raw)
    {
        if (raw is null) return (null, null);
        string[] pieces = raw.Trim().Split('-', 2);
        if (pieces.Length != 2 || !long.TryParse(pieces[0], NumberStyles.None, CultureInfo.InvariantCulture, out long start) ||
            !long.TryParse(pieces[1], NumberStyles.None, CultureInfo.InvariantCulture, out long end) || start < 0 || end < start)
            throw Error("A Widevine segment byte range is invalid.");
        return (start, checked(end - start + 1));
    }

    private static double? ParseDuration(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        Match match = DurationRegex().Match(raw);
        if (!match.Success) return null;
        double Value(int index) => match.Groups[index].Success
            ? double.Parse(match.Groups[index].Value, CultureInfo.InvariantCulture) : 0;
        double result = Value(1) * 86_400 + Value(2) * 3_600 + Value(3) * 60 + Value(4);
        return double.IsFinite(result) ? result : null;
    }

    private static ulong Ceiling(ulong value, ulong divisor) => checked(value / divisor + (value % divisor == 0 ? 0UL : 1UL));
    private static IEnumerable<XElement> Children(XElement parent, string localName) => parent.Elements().Where(element => NameIs(element, localName));
    private static bool NameIs(XElement element, string localName) => element.Name.LocalName.Equals(localName, StringComparison.Ordinal);
    private static string? Attribute(XElement element, string localName) => element.Attributes().FirstOrDefault(attribute => attribute.Name.LocalName.Equals(localName, StringComparison.OrdinalIgnoreCase))?.Value;
    private static ulong? UnsignedAttribute(XElement element, string localName)
        => ulong.TryParse(Attribute(element, localName), NumberStyles.None, CultureInfo.InvariantCulture, out ulong value) ? value : null;
    private static WidevineDashManifestException Error(string message) => new(message);

    [GeneratedRegex(@"^0(\d+)d$", RegexOptions.CultureInvariant)]
    private static partial Regex NumericFormatRegex();
    [GeneratedRegex(@"^P(?:(\d+(?:\.\d+)?)D)?(?:T(?:(\d+(?:\.\d+)?)H)?(?:(\d+(?:\.\d+)?)M)?(?:(\d+(?:\.\d+)?)S)?)?$", RegexOptions.CultureInvariant)]
    private static partial Regex DurationRegex();

    private sealed record TimelineEntry(long? StartTime, ulong? Duration, long? RepeatCount);
    private sealed record SegmentPoint(ulong Number, ulong Time);

    private sealed record SegmentTemplateData(
        string? Initialization,
        string? Media,
        ulong? Timescale,
        ulong? Duration,
        ulong? StartNumber,
        ulong? EndNumber,
        IReadOnlyList<TimelineEntry> Timeline)
    {
        public static SegmentTemplateData Parse(XElement element)
        {
            XElement? timeline = Children(element, "SegmentTimeline").FirstOrDefault();
            TimelineEntry[] entries = timeline is null ? [] : Children(timeline, "S").Select(item => new TimelineEntry(
                long.TryParse(Attribute(item, "t"), NumberStyles.Integer, CultureInfo.InvariantCulture, out long start) ? start : null,
                UnsignedAttribute(item, "d"),
                long.TryParse(Attribute(item, "r"), NumberStyles.Integer, CultureInfo.InvariantCulture, out long repeat) ? repeat : null)).ToArray();
            return new(Attribute(element, "initialization"), Attribute(element, "media"), UnsignedAttribute(element, "timescale"),
                UnsignedAttribute(element, "duration"), UnsignedAttribute(element, "startNumber"), UnsignedAttribute(element, "endNumber"), entries);
        }
        public SegmentTemplateData Merge(SegmentTemplateData value) => new(
            value.Initialization ?? Initialization, value.Media ?? Media, value.Timescale ?? Timescale, value.Duration ?? Duration,
            value.StartNumber ?? StartNumber, value.EndNumber ?? EndNumber, value.Timeline.Count > 0 ? value.Timeline : Timeline);
    }

    private sealed record SegmentListEntry(string? Media, string? MediaRange);
    private sealed record SegmentListData(
        string? InitializationSource,
        string? InitializationRange,
        IReadOnlyList<SegmentListEntry> Segments)
    {
        public static SegmentListData Parse(XElement element)
        {
            XElement? initialization = Children(element, "Initialization").FirstOrDefault();
            SegmentListEntry[] segments = Children(element, "SegmentURL")
                .Select(item => new SegmentListEntry(Attribute(item, "media"), Attribute(item, "mediaRange"))).ToArray();
            return new(initialization is null ? null : Attribute(initialization, "sourceURL"),
                initialization is null ? null : Attribute(initialization, "range"), segments);
        }
        public SegmentListData Merge(SegmentListData value) => new(
            value.InitializationSource ?? InitializationSource,
            value.InitializationRange ?? InitializationRange,
            value.Segments.Count > 0 ? value.Segments : Segments);
    }

    private sealed class ByteArrayComparer : IEqualityComparer<byte[]>
    {
        public static ByteArrayComparer Instance { get; } = new();
        public bool Equals(byte[]? left, byte[]? right) => ReferenceEquals(left, right) || left is not null && right is not null && left.AsSpan().SequenceEqual(right);
        public int GetHashCode(byte[] value)
        {
            var hash = new HashCode();
            foreach (byte item in value) hash.Add(item);
            return hash.ToHashCode();
        }
    }
}
