using System.Buffers.Binary;
using System.Text;

namespace HLSDownloader.Media;

/// <summary>
/// Fail-closed bounded BMFF metadata scanner. Media payload bytes are skipped;
/// only box headers and encryption metadata are read. Sample-group encryption
/// overrides and PIFF UUID encryption are intentionally rejected.
/// </summary>
internal static class WidevineFmp4EncryptionValidator
{
    public static void Validate(WidevineDashTrackPlan? plan, string? path)
    {
        if (plan is null)
        {
            if (path is not null) throw Error();
            return;
        }
        if (path is null) throw Error();
        using var scanner = new Scanner(path, plan);
        scanner.Validate();
    }

    /// <summary>
    /// Validates the decrypted MP4 before it can leave the private job
    /// directory. This is deliberately separate from input validation: a
    /// valid encrypted input does not prove that ffmpeg removed every CENC or
    /// CBCS signaling box from its stream-copy output.
    /// </summary>
    public static void ValidateClearOutput(string path)
    {
        using var scanner = new ClearOutputScanner(path);
        scanner.Validate();
    }

    private static InvalidDataException Error() => new("The Widevine fMP4 encryption metadata is invalid or uses unsupported key rotation.");

    private sealed class Scanner : IDisposable
    {
        private const int MaximumBoxes = 100_000;
        private const int MaximumDepth = 16;
        private readonly FileStream _stream;
        private readonly WidevineDashTrackPlan _plan;
        private int _boxCount;
        private int _tencCount;
        private bool _hasFtyp;
        private bool _hasMoov;
        private bool _hasMoof;
        private bool _hasMdat;

        public Scanner(string path, WidevineDashTrackPlan plan)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length is <= 0 or > 32L * 1024 * 1024 * 1024 || info.LinkTarget is not null)
                throw Error();
            _stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.RandomAccess);
            if (_stream.Length != info.Length) { _stream.Dispose(); throw Error(); }
            _plan = plan;
        }

        public void Validate()
        {
            long cursor = 0;
            while (cursor < _stream.Length)
            {
                Box box = NextBox(cursor, _stream.Length);
                switch (box.Type)
                {
                    case "ftyp": _hasFtyp = box.PayloadLength >= 8; break;
                    case "moov":
                        if (_hasMoov || _hasMoof) throw Error();
                        _hasMoov = true;
                        ScanHierarchy(box.PayloadStart, box.End, 1, Context.Hierarchy);
                        break;
                    case "moof":
                        if (!_hasMoov) throw Error();
                        _hasMoof = true;
                        ScanFragment(box, 1);
                        break;
                    case "mdat":
                        if (!_hasMoof || box.PayloadLength == 0) throw Error();
                        _hasMdat = true;
                        break;
                    case "uuid": throw Error();
                }
                cursor = box.End;
            }
            if (cursor != _stream.Length || !_hasFtyp || !_hasMoov || !_hasMoof || !_hasMdat || _tencCount != 1)
                throw Error();
        }

        private void ScanHierarchy(long start, long end, int depth, Context context)
        {
            CheckDepth(depth);
            long cursor = start;
            while (cursor < end)
            {
                Box box = NextBox(cursor, end);
                switch ((context, box.Type))
                {
                    case (Context.Hierarchy, "trak"):
                    case (Context.Hierarchy, "mdia"):
                    case (Context.Hierarchy, "minf"):
                    case (Context.Hierarchy, "stbl"):
                    case (Context.Hierarchy, "moov"):
                        ScanHierarchy(box.PayloadStart, box.End, depth + 1, Context.Hierarchy);
                        break;
                    case (Context.Hierarchy, "stsd"):
                        ScanSampleDescription(box, depth + 1);
                        break;
                    case (Context.EncryptedSampleEntry, "sinf"):
                        ScanHierarchy(box.PayloadStart, box.End, depth + 1, Context.ProtectionScheme);
                        break;
                    case (Context.ProtectionScheme, "schi"):
                        ScanHierarchy(box.PayloadStart, box.End, depth + 1, Context.SchemeInformation);
                        break;
                    case (Context.SchemeInformation, "tenc"):
                        ValidateTenc(box);
                        _tencCount++;
                        break;
                    case (_, "tenc"):
                    case (_, "uuid"):
                    case (_, "sgpd"):
                    case (_, "sbgp"):
                    case (_, "moof"):
                    case (_, "mdat"):
                        throw Error();
                }
                cursor = box.End;
            }
            if (cursor != end) throw Error();
        }

        private void ScanSampleDescription(Box box, int depth)
        {
            CheckDepth(depth);
            if (box.PayloadLength < 8) throw Error();
            Span<byte> prefix = stackalloc byte[8];
            ReadAt(box.PayloadStart, prefix);
            if (!prefix[..4].SequenceEqual(new byte[4])) throw Error();
            uint count = BinaryPrimitives.ReadUInt32BigEndian(prefix[4..]);
            if (count != 1) throw Error();
            Box entry = NextBox(box.PayloadStart + 8, box.End);
            int headerLength = (_plan.MediaType, entry.Type) switch
            {
                (WidevineDashMediaType.Video, "encv") => 78,
                (WidevineDashMediaType.Audio, "enca") => 28,
                _ => throw Error()
            };
            if (entry.PayloadLength < headerLength || entry.End != box.End) throw Error();
            int previous = _tencCount;
            ScanHierarchy(entry.PayloadStart + headerLength, entry.End, depth + 1, Context.EncryptedSampleEntry);
            if (_tencCount != previous + 1) throw Error();
        }

        private void ValidateTenc(Box box)
        {
            if (box.PayloadLength is < 24 or > 41) throw Error();
            Span<byte> prefix = stackalloc byte[24];
            ReadAt(box.PayloadStart, prefix);
            byte version = prefix[0];
            if (version is not 0 and not 1 || prefix[1] != 0 || prefix[2] != 0 || prefix[3] != 0 ||
                prefix[4] != 0 || (version == 0 && prefix[5] != 0) || prefix[6] != 1) throw Error();
            byte ivSize = prefix[7];
            if (ivSize is not 0 and not 8 and not 16 || !prefix[8..24].SequenceEqual(_plan.KeyId)) throw Error();
            if (ivSize == 0)
            {
                Span<byte> constantSize = stackalloc byte[1];
                ReadAt(box.PayloadStart + 24, constantSize);
                if (constantSize[0] is not 8 and not 16 || box.PayloadLength != 25 + constantSize[0]) throw Error();
            }
            else if (box.PayloadLength != 24) throw Error();
        }

        private void ScanFragment(Box moof, int depth)
        {
            CheckDepth(depth);
            long cursor = moof.PayloadStart;
            bool hasTraf = false;
            while (cursor < moof.End)
            {
                Box box = NextBox(cursor, moof.End);
                if (box.Type == "traf")
                {
                    hasTraf = true;
                    ScanTraf(box, depth + 1);
                }
                else if (box.Type == "uuid") throw Error();
                cursor = box.End;
            }
            if (cursor != moof.End || !hasTraf) throw Error();
        }

        private void ScanTraf(Box traf, int depth)
        {
            CheckDepth(depth);
            long cursor = traf.PayloadStart;
            Span<byte> fullBox = stackalloc byte[4];
            while (cursor < traf.End)
            {
                Box box = NextBox(cursor, traf.End);
                switch (box.Type)
                {
                    case "uuid":
                    case "sgpd":
                    case "sbgp":
                        throw Error();
                    case "senc":
                        if (box.PayloadLength < 8) throw Error();
                        ReadAt(box.PayloadStart, fullBox);
                        uint flags = (uint)(fullBox[1] << 16 | fullBox[2] << 8 | fullBox[3]);
                        if (fullBox[0] != 0 || (flags & ~0x000003u) != 0 || (flags & 0x000001u) != 0) throw Error();
                        break;
                }
                cursor = box.End;
            }
            if (cursor != traf.End) throw Error();
        }

        private Box NextBox(long offset, long parentEnd)
        {
            if (_boxCount++ >= MaximumBoxes || offset < 0 || parentEnd < offset || parentEnd - offset < 8) throw Error();
            Span<byte> header = stackalloc byte[16];
            ReadAt(offset, header[..8]);
            uint size32 = BinaryPrimitives.ReadUInt32BigEndian(header);
            string type = Encoding.ASCII.GetString(header[4..8]);
            long headerLength = 8;
            long length;
            if (size32 == 0) length = parentEnd - offset;
            else if (size32 == 1)
            {
                if (parentEnd - offset < 16) throw Error();
                ReadAt(offset + 8, header[8..16]);
                ulong size64 = BinaryPrimitives.ReadUInt64BigEndian(header[8..16]);
                if (size64 > long.MaxValue) throw Error();
                length = (long)size64;
                headerLength = 16;
            }
            else length = size32;
            if (length < headerLength || length > parentEnd - offset) throw Error();
            return new(type, offset + headerLength, offset + length);
        }

        private void ReadAt(long offset, Span<byte> destination)
        {
            _stream.Position = offset;
            if (_stream.Read(destination) != destination.Length) throw Error();
        }
        private static void CheckDepth(int depth) { if (depth > MaximumDepth) throw Error(); }
        public void Dispose() => _stream.Dispose();
        private enum Context { Hierarchy, EncryptedSampleEntry, ProtectionScheme, SchemeInformation }
        private readonly record struct Box(string Type, long PayloadStart, long End)
        {
            public long PayloadLength => End - PayloadStart;
        }
    }

    private sealed class ClearOutputScanner : IDisposable
    {
        private const int MaximumBoxes = 100_000;
        private const int MaximumDepth = 16;
        private readonly FileStream _stream;
        private int _boxCount;

        public ClearOutputScanner(string path)
        {
            var info = new FileInfo(path);
            if (!info.Exists || info.Length is < 16 or > 32L * 1024 * 1024 * 1024 ||
                (info.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw ClearError();
            }

            _stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                64 * 1024,
                FileOptions.RandomAccess);
            if (_stream.Length != info.Length)
            {
                _stream.Dispose();
                throw ClearError();
            }
        }

        public void Validate()
        {
            bool hasFileType = false;
            bool hasMovieMetadata = false;
            bool hasMediaData = false;
            long cursor = 0;
            while (cursor < _stream.Length)
            {
                ClearBox box = NextBox(cursor, _stream.Length);
                RejectEncryptionBox(box.Type);
                switch (box.Type)
                {
                    case "ftyp":
                        if (hasFileType || box.PayloadLength < 8) throw ClearError();
                        hasFileType = true;
                        break;
                    case "moov":
                        if (hasMovieMetadata) throw ClearError();
                        hasMovieMetadata = true;
                        ScanChildren(box.PayloadStart, box.End, 1);
                        break;
                    case "moof":
                        ScanChildren(box.PayloadStart, box.End, 1);
                        break;
                    case "mdat":
                        hasMediaData |= box.PayloadLength > 0;
                        break;
                }
                cursor = box.End;
            }

            if (cursor != _stream.Length || !hasFileType || !hasMovieMetadata || !hasMediaData)
                throw ClearError();
        }

        private void ScanChildren(long start, long end, int depth)
        {
            CheckDepth(depth);
            long cursor = start;
            while (cursor < end)
            {
                ClearBox box = NextBox(cursor, end);
                RejectEncryptionBox(box.Type);
                switch (box.Type)
                {
                    case "moov":
                    case "trak":
                    case "mdia":
                    case "minf":
                    case "stbl":
                    case "edts":
                    case "dinf":
                    case "mvex":
                    case "moof":
                    case "traf":
                    case "mfra":
                    case "udta":
                    case "wave":
                        ScanChildren(box.PayloadStart, box.End, depth + 1);
                        break;
                    case "meta":
                        if (box.PayloadLength < 4) throw ClearError();
                        ScanChildren(box.PayloadStart + 4, box.End, depth + 1);
                        break;
                    case "stsd":
                        ScanSampleDescriptions(box, depth + 1);
                        break;
                    case "mdat":
                    case "ftyp":
                        throw ClearError();
                }
                cursor = box.End;
            }
            if (cursor != end) throw ClearError();
        }

        private void ScanSampleDescriptions(ClearBox box, int depth)
        {
            CheckDepth(depth);
            if (box.PayloadLength < 8) throw ClearError();
            Span<byte> prefix = stackalloc byte[8];
            ReadAt(box.PayloadStart, prefix);
            if (!prefix[..4].SequenceEqual(new byte[4])) throw ClearError();
            uint entryCount = BinaryPrimitives.ReadUInt32BigEndian(prefix[4..]);
            if (entryCount is 0 or > 64) throw ClearError();

            long cursor = box.PayloadStart + 8;
            for (uint index = 0; index < entryCount; index++)
            {
                ClearBox entry = NextBox(cursor, box.End);
                RejectEncryptionBox(entry.Type);
                int fixedHeaderLength = entry.Type switch
                {
                    "avc1" or "avc3" or "hvc1" or "hev1" or "vp08" or "vp09" or
                        "av01" or "mp4v" or "dvh1" or "dvhe" => 78,
                    "mp4a" or "ac-3" or "ec-3" or "Opus" or "fLaC" or "alac" =>
                        AudioSampleEntryHeaderLength(entry),
                    _ => throw ClearError()
                };
                if (entry.PayloadLength < fixedHeaderLength) throw ClearError();
                ScanChildren(entry.PayloadStart + fixedHeaderLength, entry.End, depth + 1);
                cursor = entry.End;
            }
            if (cursor != box.End) throw ClearError();
        }

        private int AudioSampleEntryHeaderLength(ClearBox entry)
        {
            if (entry.PayloadLength < 28) throw ClearError();
            Span<byte> versionBytes = stackalloc byte[2];
            ReadAt(entry.PayloadStart + 8, versionBytes);
            ushort version = BinaryPrimitives.ReadUInt16BigEndian(versionBytes);
            return version switch
            {
                0 => 28,
                1 => 44,
                _ => throw ClearError()
            };
        }

        private static void RejectEncryptionBox(string type)
        {
            if (type is "pssh" or "tenc" or "senc" or "saiz" or "saio" or
                "encv" or "enca" or "sinf" or "schi" or "schm" or "frma" or
                "ipro" or "sgpd" or "sbgp" or "uuid" or "cenc" or "cens" or
                "cbc1" or "cbcs")
            {
                throw ClearError();
            }
        }

        private ClearBox NextBox(long offset, long parentEnd)
        {
            if (_boxCount++ >= MaximumBoxes || offset < 0 || parentEnd < offset || parentEnd - offset < 8)
                throw ClearError();
            Span<byte> header = stackalloc byte[16];
            ReadAt(offset, header[..8]);
            uint size32 = BinaryPrimitives.ReadUInt32BigEndian(header);
            string type = Encoding.ASCII.GetString(header[4..8]);
            long headerLength = 8;
            long length;
            if (size32 == 0)
            {
                length = parentEnd - offset;
            }
            else if (size32 == 1)
            {
                if (parentEnd - offset < 16) throw ClearError();
                ReadAt(offset + 8, header[8..16]);
                ulong size64 = BinaryPrimitives.ReadUInt64BigEndian(header[8..16]);
                if (size64 > long.MaxValue) throw ClearError();
                length = (long)size64;
                headerLength = 16;
            }
            else
            {
                length = size32;
            }
            if (length < headerLength || length > parentEnd - offset) throw ClearError();
            return new ClearBox(type, offset + headerLength, offset + length);
        }

        private void ReadAt(long offset, Span<byte> destination)
        {
            _stream.Position = offset;
            if (_stream.Read(destination) != destination.Length) throw ClearError();
        }

        private static void CheckDepth(int depth)
        {
            if (depth > MaximumDepth) throw ClearError();
        }

        public void Dispose() => _stream.Dispose();

        private readonly record struct ClearBox(string Type, long PayloadStart, long End)
        {
            public long PayloadLength => End - PayloadStart;
        }
    }

    private static InvalidDataException ClearError() =>
        new("The decrypted Widevine MP4 is malformed or still contains encryption metadata.");
}
