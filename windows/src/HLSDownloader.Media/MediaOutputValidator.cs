using System.Buffers.Binary;
using System.Text;

namespace HLSDownloader.Media;

public static class MediaOutputValidator
{
    public static void Validate(string path, MediaOutputFormat format)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        bool valid = format switch
        {
            MediaOutputFormat.Mp4 => IsValidMp4(path),
            MediaOutputFormat.Wav => IsValidPcm16Wav(path),
            MediaOutputFormat.WebM => IsValidWebM(path),
            _ => false
        };
        if (!valid)
        {
            throw new InvalidDataException($"The generated {format} output is invalid or empty.");
        }
    }

    public static bool IsValidMp4(string path)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        using FileStream stream = File.OpenRead(path);
        if (stream.Length < 16)
        {
            return false;
        }

        Span<byte> header = stackalloc byte[8];
        Span<byte> extended = stackalloc byte[8];
        bool hasFileType = false;
        bool hasMovieMetadata = false;
        bool hasMediaData = false;
        int atomCount = 0;
        while (stream.Position + header.Length <= stream.Length && atomCount++ < 100_000)
        {
            long atomStart = stream.Position;
            if (stream.Read(header) != header.Length)
            {
                return false;
            }

            uint size32 = BinaryPrimitives.ReadUInt32BigEndian(header);
            string type = Encoding.ASCII.GetString(header[4..8]);
            long atomSize = size32;
            int headerSize = 8;
            if (size32 == 0)
            {
                atomSize = stream.Length - atomStart;
            }
            else if (size32 == 1)
            {
                if (stream.Read(extended) != extended.Length)
                {
                    return false;
                }

                ulong size64 = BinaryPrimitives.ReadUInt64BigEndian(extended);
                if (size64 > long.MaxValue)
                {
                    return false;
                }

                atomSize = (long)size64;
                headerSize = 16;
            }

            if (atomSize < headerSize || atomStart + atomSize > stream.Length)
            {
                return false;
            }

            if (type == "ftyp")
            {
                hasFileType = atomSize >= 16;
            }

            hasMovieMetadata |= type == "moov" && atomSize >= headerSize;
            hasMediaData |= type == "mdat" && atomSize > headerSize;

            stream.Position = atomStart + atomSize;
        }

        return hasFileType && hasMovieMetadata && hasMediaData && stream.Position == stream.Length;
    }

    public static bool IsValidPcm16Wav(string path)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        using FileStream stream = File.OpenRead(path);
        if (stream.Length < 44)
        {
            return false;
        }

        Span<byte> header = stackalloc byte[12];
        if (stream.Read(header) != header.Length || Encoding.ASCII.GetString(header[8..12]) != "WAVE")
        {
            return false;
        }

        string container = Encoding.ASCII.GetString(header[..4]);
        if (container is not ("RIFF" or "RF64"))
        {
            return false;
        }

        bool pcm16 = false;
        bool nonEmptyData = false;
        ushort pcmBlockAlign = 0;
        ulong? rf64DataSize = null;
        Span<byte> chunkHeader = stackalloc byte[8];
        Span<byte> ds64 = stackalloc byte[24];
        Span<byte> format = stackalloc byte[16];
        Span<byte> extensibleFormat = stackalloc byte[24];
        ReadOnlySpan<byte> pcmSubFormat = [
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
        ];
        while (stream.Position + chunkHeader.Length <= stream.Length)
        {
            if (stream.Read(chunkHeader) != chunkHeader.Length)
            {
                return false;
            }

            string chunk = Encoding.ASCII.GetString(chunkHeader[..4]);
            uint chunkSize = BinaryPrimitives.ReadUInt32LittleEndian(chunkHeader[4..]);
            long available = stream.Length - stream.Position;
            if (chunk == "ds64" && chunkSize >= 28 && available >= chunkSize)
            {
                if (stream.Read(ds64) != ds64.Length)
                {
                    return false;
                }

                rf64DataSize = BinaryPrimitives.ReadUInt64LittleEndian(ds64[8..16]);
                stream.Seek(chunkSize - ds64.Length, SeekOrigin.Current);
            }
            else if (chunk == "fmt " && chunkSize >= 16 && available >= chunkSize)
            {
                if (stream.Read(format) != format.Length)
                {
                    return false;
                }

                ushort encoding = BinaryPrimitives.ReadUInt16LittleEndian(format);
                ushort channels = BinaryPrimitives.ReadUInt16LittleEndian(format[2..]);
                uint sampleRate = BinaryPrimitives.ReadUInt32LittleEndian(format[4..]);
                ushort blockAlign = BinaryPrimitives.ReadUInt16LittleEndian(format[12..]);
                ushort bits = BinaryPrimitives.ReadUInt16LittleEndian(format[14..]);
                bool isPcmEncoding = encoding == 1;
                int consumed = format.Length;
                if (encoding == 0xFFFE && chunkSize >= 40)
                {
                    if (stream.Read(extensibleFormat) != extensibleFormat.Length)
                    {
                        return false;
                    }

                    consumed += extensibleFormat.Length;
                    ushort extensionSize = BinaryPrimitives.ReadUInt16LittleEndian(extensibleFormat);
                    ushort validBits = BinaryPrimitives.ReadUInt16LittleEndian(extensibleFormat[2..]);
                    isPcmEncoding = extensionSize >= 22 && validBits == 16 &&
                        extensibleFormat[8..24].SequenceEqual(pcmSubFormat);
                }

                pcm16 = isPcmEncoding && channels > 0 && sampleRate > 0 && bits == 16 && blockAlign == channels * 2;
                pcmBlockAlign = pcm16 ? blockAlign : (ushort)0;
                stream.Seek(chunkSize - consumed, SeekOrigin.Current);
            }
            else if (chunk == "data")
            {
                ulong declared = chunkSize == uint.MaxValue && container == "RF64"
                    ? rf64DataSize ?? 0
                    : chunkSize;
                nonEmptyData = declared > 0 && pcmBlockAlign > 0 && declared <= (ulong)available &&
                    declared % pcmBlockAlign == 0;
                break;
            }
            else
            {
                if (chunkSize > available)
                {
                    return false;
                }

                stream.Seek(chunkSize, SeekOrigin.Current);
            }

            if ((chunkSize & 1) != 0 && stream.Position < stream.Length)
            {
                stream.Seek(1, SeekOrigin.Current);
            }
        }

        return pcm16 && nonEmptyData;
    }

    public static bool IsValidWebM(string path)
    {
        return WebMMediaValidator.TryInspect(path, out WebMMediaInspection inspection) &&
            !inspection.IsEncrypted;
    }
}
