using System.Buffers.Binary;
using System.Text;

namespace HLSDownloader.Media.Tests;

internal sealed class TestFileScope : IDisposable
{
    public TestFileScope()
    {
        DirectoryPath = Path.Combine(Path.GetTempPath(), "HLSDownloader.Tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(DirectoryPath);
    }

    public string DirectoryPath { get; }

    public string PathFor(string leaf) => Path.Combine(DirectoryPath, leaf);

    public void Dispose()
    {
        if (Directory.Exists(DirectoryPath))
        {
            Directory.Delete(DirectoryPath, recursive: true);
        }
    }

    public static void WritePcm16Wav(string path, int dataLength = 4)
    {
        byte[] bytes = new byte[44 + dataLength];
        Encoding.ASCII.GetBytes("RIFF").CopyTo(bytes, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), (uint)(bytes.Length - 8));
        Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(bytes, 8);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(20), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(22), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(24), 48000);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(28), 96000);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(32), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(34), 16);
        Encoding.ASCII.GetBytes("data").CopyTo(bytes, 36);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), (uint)dataLength);
        File.WriteAllBytes(path, bytes);
    }

    public static void WriteMinimalMp4(string path)
    {
        byte[] bytes = new byte[41];
        BinaryPrimitives.WriteUInt32BigEndian(bytes, 24);
        Encoding.ASCII.GetBytes("ftypisom").CopyTo(bytes, 4);
        Encoding.ASCII.GetBytes("isomiso2").CopyTo(bytes, 12);
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(24), 8);
        Encoding.ASCII.GetBytes("moov").CopyTo(bytes, 28);
        BinaryPrimitives.WriteUInt32BigEndian(bytes.AsSpan(32), 9);
        Encoding.ASCII.GetBytes("mdat").CopyTo(bytes, 36);
        bytes[40] = 1;
        File.WriteAllBytes(path, bytes);
    }

    public static void WriteRf64Wav(string path, ulong declaredDataLength, int actualDataLength)
    {
        byte[] bytes = new byte[80 + actualDataLength];
        Encoding.ASCII.GetBytes("RF64").CopyTo(bytes, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), uint.MaxValue);
        Encoding.ASCII.GetBytes("WAVEds64").CopyTo(bytes, 8);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(16), 28);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(20), (ulong)Math.Max(0, bytes.Length - 8));
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(28), declaredDataLength);
        BinaryPrimitives.WriteUInt64LittleEndian(bytes.AsSpan(36), declaredDataLength / 2);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(44), 0);
        Encoding.ASCII.GetBytes("fmt ").CopyTo(bytes, 48);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(52), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(56), 1);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(58), 1);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(60), 48000);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), 96000);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(68), 2);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(70), 16);
        Encoding.ASCII.GetBytes("data").CopyTo(bytes, 72);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(76), uint.MaxValue);
        File.WriteAllBytes(path, bytes);
    }

    public static void WriteExtensiblePcm16Wav(string path)
    {
        byte[] bytes = new byte[72];
        Encoding.ASCII.GetBytes("RIFF").CopyTo(bytes, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(4), 64);
        Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(bytes, 8);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(16), 40);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(20), 0xFFFE);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(22), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(24), 48000);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(28), 192000);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(32), 4);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(34), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(36), 22);
        BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(38), 16);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), 3);
        byte[] pcmGuid = [
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
            0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
        ];
        pcmGuid.CopyTo(bytes, 44);
        Encoding.ASCII.GetBytes("data").CopyTo(bytes, 60);
        BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(64), 4);
        File.WriteAllBytes(path, bytes);
    }
}
