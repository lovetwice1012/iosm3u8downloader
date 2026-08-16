using System.Buffers.Binary;

namespace HLSDownloader.Windows.Services;

public enum WvdDeviceType : byte
{
    Chrome = 1,
    Android = 2
}

public sealed record WvdFileMetadata(byte Version, WvdDeviceType DeviceType, byte SecurityLevel);

public static class WvdFileValidator
{
    public const int MaximumFileBytes = 256 * 1024;
    private const int HeaderLength = 7;

    public static WvdFileMetadata Validate(ReadOnlySpan<byte> data)
    {
        if (data.Length > MaximumFileBytes)
        {
            throw new InvalidDataException("WVDファイルが許容サイズを超えています。");
        }

        if (data.Length < HeaderLength)
        {
            throw new InvalidDataException("WVDファイルのヘッダーが不完全です。");
        }

        if (!data[..3].SequenceEqual("WVD"u8))
        {
            throw new InvalidDataException("WVDファイルの識別子が正しくありません。");
        }

        if (data[3] != 2)
        {
            throw new InvalidDataException("対応していないWVDファイルバージョンです。");
        }

        if (data[4] is not ((byte)WvdDeviceType.Chrome) and not ((byte)WvdDeviceType.Android))
        {
            throw new InvalidDataException("対応していないWVDデバイス種別です。");
        }

        if (data[5] != 3)
        {
            throw new InvalidDataException("このWVD資格情報はWidevine L3ではありません。");
        }

        if (data[6] != 0)
        {
            throw new InvalidDataException("対応していないWVDフラグが設定されています。");
        }

        var cursor = HeaderLength;
        var privateKeyLength = ReadLength(data, ref cursor);
        if (privateKeyLength == 0)
        {
            throw new InvalidDataException("WVDファイルにデバイス秘密鍵が含まれていません。");
        }

        Skip(data, ref cursor, privateKeyLength);
        var clientIdentificationLength = ReadLength(data, ref cursor);
        if (clientIdentificationLength == 0)
        {
            throw new InvalidDataException("WVDファイルにクライアント識別情報が含まれていません。");
        }

        Skip(data, ref cursor, clientIdentificationLength);
        if (cursor != data.Length)
        {
            throw new InvalidDataException("WVDファイルの構造が正しくありません。");
        }

        return new WvdFileMetadata(2, (WvdDeviceType)data[4], 3);
    }

    private static ushort ReadLength(ReadOnlySpan<byte> data, ref int cursor)
    {
        if (cursor > data.Length - sizeof(ushort))
        {
            throw new InvalidDataException("WVDファイルの構造が正しくありません。");
        }

        var length = BinaryPrimitives.ReadUInt16BigEndian(data[cursor..]);
        cursor += sizeof(ushort);
        return length;
    }

    private static void Skip(ReadOnlySpan<byte> data, ref int cursor, int length)
    {
        if (cursor > data.Length || length > data.Length - cursor)
        {
            throw new InvalidDataException("WVDファイルの構造が正しくありません。");
        }

        cursor += length;
    }
}
