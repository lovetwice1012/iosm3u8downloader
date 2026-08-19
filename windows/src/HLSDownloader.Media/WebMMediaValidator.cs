using System.Text;

namespace HLSDownloader.Media;

internal readonly record struct WebMMediaInspection(bool IsEncrypted);

/// <summary>
/// Performs a bounded structural walk of an EBML/WebM file. This deliberately
/// does not treat a file extension, MIME type, or ffprobe track metadata as
/// proof that the file contains a decodable media sample.
/// </summary>
internal static class WebMMediaValidator
{
    private readonly record struct Element(ulong Identifier, long PayloadStart, long End, bool IsUnknownSize);

    private const ulong EbmlIdentifier = 0x1A45DFA3;
    private const ulong DocTypeIdentifier = 0x4282;
    private const ulong SegmentIdentifier = 0x18538067;
    private const ulong ClusterIdentifier = 0x1F43B675;
    private const ulong TracksIdentifier = 0x1654AE6B;
    private const ulong TrackEntryIdentifier = 0xAE;
    private const ulong BlockGroupIdentifier = 0xA0;
    private const ulong SimpleBlockIdentifier = 0xA3;
    private const ulong BlockIdentifier = 0xA1;
    private const ulong EncryptedBlockIdentifier = 0xAF;
    private const ulong ContentEncodingsIdentifier = 0x6D80;
    private const ulong ContentEncodingIdentifier = 0x6240;
    private const ulong ContentEncryptionIdentifier = 0x5035;
    private const int MaximumDepth = 16;
    private const int MaximumElements = 2_000_000;
    private const long MinimumBlockPayloadBytes = 5; // block header plus at least one media byte

    public static bool TryInspect(string path, out WebMMediaInspection inspection)
    {
        inspection = default;
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            using FileStream stream = new(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                128 * 1024,
                FileOptions.RandomAccess);
            if (stream.Length < 16 ||
                !TryReadElement(stream, 0, stream.Length, out Element header) ||
                header.Identifier != EbmlIdentifier ||
                header.PayloadStart >= header.End ||
                !HasWebMDocType(stream, header))
            {
                return false;
            }

            long cursor = header.End;
            Element? segment = null;
            int topLevelElements = 0;
            while (cursor < stream.Length)
            {
                if (++topLevelElements > MaximumElements ||
                    !TryReadElement(stream, cursor, stream.Length, out Element element) ||
                    element.End <= cursor ||
                    (element.IsUnknownSize && element.Identifier != SegmentIdentifier))
                {
                    return false;
                }

                if (element.Identifier == SegmentIdentifier)
                {
                    if (segment is not null)
                    {
                        return false;
                    }

                    segment = element;
                }
                else if (element.Identifier is not (0xEC or 0xBF)) // Void / CRC-32
                {
                    return false;
                }

                cursor = element.End;
            }

            if (cursor != stream.Length || segment is not Element mediaSegment ||
                mediaSegment.PayloadStart >= mediaSegment.End || mediaSegment.End != stream.Length)
            {
                return false;
            }

            int elementCount = 0;
            bool isEncrypted = false;
            bool sawTracks = false;
            bool sawTrackEntry = false;
            bool sawMediaBlock = false;
            if (!ScanMaster(
                    stream,
                    mediaSegment.PayloadStart,
                    mediaSegment.End,
                    SegmentIdentifier,
                    0,
                    ref elementCount,
                    ref isEncrypted,
                    ref sawTracks,
                    ref sawTrackEntry,
                    ref sawMediaBlock) ||
                !sawTracks || !sawTrackEntry || !sawMediaBlock)
            {
                return false;
            }

            inspection = new WebMMediaInspection(isEncrypted);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static bool HasWebMDocType(FileStream stream, Element header)
    {
        long cursor = header.PayloadStart;
        int count = 0;
        bool found = false;
        while (cursor < header.End)
        {
            if (++count > 128 || !TryReadElement(stream, cursor, header.End, out Element child) ||
                child.End <= cursor || child.IsUnknownSize)
            {
                return false;
            }

            if (child.Identifier == DocTypeIdentifier)
            {
                long length = child.End - child.PayloadStart;
                if (found || length is <= 0 or > 16)
                {
                    return false;
                }

                byte[] value = new byte[(int)length];
                if (!TryReadExactlyAt(stream, child.PayloadStart, value) ||
                    !string.Equals(Encoding.ASCII.GetString(value), "webm", StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                found = true;
            }

            cursor = child.End;
        }

        return cursor == header.End && found;
    }

    private static bool ScanMaster(
        FileStream stream,
        long start,
        long end,
        ulong parentIdentifier,
        int depth,
        ref int elementCount,
        ref bool isEncrypted,
        ref bool sawTracks,
        ref bool sawTrackEntry,
        ref bool sawMediaBlock)
    {
        if (depth > MaximumDepth)
        {
            return false;
        }

        long cursor = start;
        while (cursor < end)
        {
            if (++elementCount > MaximumElements ||
                !TryReadElement(stream, cursor, end, out Element child) ||
                child.End <= cursor ||
                (child.IsUnknownSize && child.Identifier != ClusterIdentifier))
            {
                return false;
            }

            long payloadLength = child.End - child.PayloadStart;
            if (child.Identifier == TracksIdentifier && parentIdentifier == SegmentIdentifier)
            {
                sawTracks = true;
            }
            else if (child.Identifier == TrackEntryIdentifier && parentIdentifier == TracksIdentifier)
            {
                if (payloadLength <= 0)
                {
                    return false;
                }

                sawTrackEntry = true;
            }

            if ((child.Identifier is SimpleBlockIdentifier or EncryptedBlockIdentifier) &&
                parentIdentifier == ClusterIdentifier)
            {
                if (payloadLength < MinimumBlockPayloadBytes)
                {
                    return false;
                }

                sawMediaBlock = true;
            }
            else if (child.Identifier == BlockIdentifier && parentIdentifier == BlockGroupIdentifier)
            {
                if (payloadLength < MinimumBlockPayloadBytes)
                {
                    return false;
                }

                sawMediaBlock = true;
            }

            if (child.Identifier is ContentEncryptionIdentifier or EncryptedBlockIdentifier)
            {
                isEncrypted = true;
            }

            bool recurse = child.Identifier switch
            {
                ClusterIdentifier => parentIdentifier is SegmentIdentifier or ClusterIdentifier,
                TracksIdentifier => parentIdentifier == SegmentIdentifier,
                TrackEntryIdentifier => parentIdentifier == TracksIdentifier,
                BlockGroupIdentifier => parentIdentifier == ClusterIdentifier,
                ContentEncodingsIdentifier => parentIdentifier == TrackEntryIdentifier,
                ContentEncodingIdentifier => parentIdentifier == ContentEncodingsIdentifier,
                _ => false
            };
            if (recurse && !ScanMaster(
                    stream,
                    child.PayloadStart,
                    child.End,
                    child.Identifier,
                    depth + 1,
                    ref elementCount,
                    ref isEncrypted,
                    ref sawTracks,
                    ref sawTrackEntry,
                    ref sawMediaBlock))
            {
                return false;
            }

            cursor = child.End;
        }

        return cursor == end;
    }

    private static bool TryReadElement(FileStream stream, long offset, long parentEnd, out Element element)
    {
        element = default;
        if (!TryReadVariableInteger(stream, offset, parentEnd, 4, retainMarker: true, out ulong identifier, out int idLength, out _))
        {
            return false;
        }

        long sizeOffset;
        try
        {
            sizeOffset = checked(offset + idLength);
        }
        catch (OverflowException)
        {
            return false;
        }

        if (!TryReadVariableInteger(stream, sizeOffset, parentEnd, 8, retainMarker: false, out ulong size, out int sizeLength, out bool unknown))
        {
            return false;
        }

        long payloadStart;
        try
        {
            payloadStart = checked(sizeOffset + sizeLength);
        }
        catch (OverflowException)
        {
            return false;
        }

        if (payloadStart > parentEnd)
        {
            return false;
        }

        long elementEnd;
        if (unknown)
        {
            elementEnd = parentEnd;
        }
        else if (size > (ulong)(parentEnd - payloadStart))
        {
            return false;
        }
        else
        {
            elementEnd = payloadStart + (long)size;
        }

        element = new Element(identifier, payloadStart, elementEnd, unknown);
        return true;
    }

    private static bool TryReadVariableInteger(
        FileStream stream,
        long offset,
        long parentEnd,
        int maximumLength,
        bool retainMarker,
        out ulong value,
        out int length,
        out bool isUnknown)
    {
        value = 0;
        length = 0;
        isUnknown = false;
        if (offset < 0 || offset >= parentEnd)
        {
            return false;
        }

        Span<byte> firstBuffer = stackalloc byte[1];
        if (!TryReadExactlyAt(stream, offset, firstBuffer) || firstBuffer[0] == 0)
        {
            return false;
        }

        byte first = firstBuffer[0];
        byte mask = 0x80;
        length = 1;
        while (length <= 8 && (first & mask) == 0)
        {
            mask >>= 1;
            length++;
        }

        if (length > maximumLength || length > parentEnd - offset)
        {
            return false;
        }

        Span<byte> bytes = stackalloc byte[8];
        Span<byte> encoded = bytes[..length];
        if (!TryReadExactlyAt(stream, offset, encoded))
        {
            return false;
        }

        value = retainMarker ? encoded[0] : (byte)(encoded[0] & ~mask);
        for (int index = 1; index < encoded.Length; index++)
        {
            value = (value << 8) | encoded[index];
        }

        int dataBits = 7 * length;
        ulong unknownValue = (1UL << dataBits) - 1;
        isUnknown = !retainMarker && value == unknownValue;
        return true;
    }

    private static bool TryReadExactlyAt(FileStream stream, long offset, Span<byte> destination)
    {
        if (offset < 0 || offset > stream.Length - destination.Length)
        {
            return false;
        }

        stream.Position = offset;
        int read = 0;
        while (read < destination.Length)
        {
            int count = stream.Read(destination[read..]);
            if (count == 0)
            {
                return false;
            }

            read += count;
        }

        return true;
    }
}
