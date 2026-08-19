namespace HLSDownloader.Media.Tests;

public sealed class MediaOutputValidatorTests
{
    [Fact]
    public void AcceptsNonEmptyPcm16Wav()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("audio.wav");
        TestFileScope.WritePcm16Wav(path);

        Assert.True(MediaOutputValidator.IsValidPcm16Wav(path));
    }

    [Fact]
    public void RejectsEmptyWavDataChunk()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("empty.wav");
        TestFileScope.WritePcm16Wav(path, dataLength: 0);

        Assert.False(MediaOutputValidator.IsValidPcm16Wav(path));
    }

    [Fact]
    public void AcceptsMp4WithFtypAtom()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("video.mp4");
        TestFileScope.WriteMinimalMp4(path);

        Assert.True(MediaOutputValidator.IsValidMp4(path));
    }

    [Fact]
    public void RejectsTruncatedRiffDataChunk()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("truncated.wav");
        TestFileScope.WritePcm16Wav(path, dataLength: 4);
        byte[] bytes = File.ReadAllBytes(path);
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(40), 8);
        File.WriteAllBytes(path, bytes);

        Assert.False(MediaOutputValidator.IsValidPcm16Wav(path));
    }

    [Theory]
    [InlineData(4UL, 4, true)]
    [InlineData(8UL, 4, false)]
    [InlineData(0UL, 4, false)]
    public void ValidatesRf64DataLength(ulong declared, int actual, bool expected)
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("audio.rf64.wav");
        TestFileScope.WriteRf64Wav(path, declared, actual);

        Assert.Equal(expected, MediaOutputValidator.IsValidPcm16Wav(path));
    }

    [Fact]
    public void RejectsFtypOnlyMp4()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("ftyp-only.mp4");
        byte[] bytes = new byte[24];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(bytes, 24);
        System.Text.Encoding.ASCII.GetBytes("ftypisom").CopyTo(bytes, 4);
        File.WriteAllBytes(path, bytes);

        Assert.False(MediaOutputValidator.IsValidMp4(path));
    }

    [Fact]
    public void AcceptsWaveFormatExtensiblePcm16()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("surround.wav");
        TestFileScope.WriteExtensiblePcm16Wav(path);

        Assert.True(MediaOutputValidator.IsValidPcm16Wav(path));
    }

    [Fact]
    public void AcceptsMp4WithLargeMoovBeforeMdat()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("large-moov.mp4");
        const int moovSize = 1024 * 1024 + 128;
        using (FileStream stream = new(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
        {
            Span<byte> atom = stackalloc byte[24];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(atom, 24);
            System.Text.Encoding.ASCII.GetBytes("ftypisom").CopyTo(atom[4..]);
            System.Text.Encoding.ASCII.GetBytes("isomiso2").CopyTo(atom[12..]);
            stream.Write(atom);
            Span<byte> header = stackalloc byte[8];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(header, moovSize);
            System.Text.Encoding.ASCII.GetBytes("moov").CopyTo(header[4..]);
            stream.Write(header);
            stream.Position += moovSize - header.Length;
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(header, 9);
            System.Text.Encoding.ASCII.GetBytes("mdat").CopyTo(header[4..]);
            stream.Write(header);
            stream.WriteByte(1);
        }

        Assert.True(MediaOutputValidator.IsValidMp4(path));
    }

    [Fact]
    public void AcceptsWebMWithEbmlHeaderAndSegment()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("video.webm");
        TestFileScope.WriteMinimalWebM(path);

        Assert.True(MediaOutputValidator.IsValidWebM(path));
    }

    [Fact]
    public void RejectsWebMWithoutMediaBlock()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("empty.webm");
        TestFileScope.WriteMinimalWebM(path, includeMediaSample: false);

        Assert.False(MediaOutputValidator.IsValidWebM(path));
    }

    [Fact]
    public void RejectsEncryptedWebMBlock()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("encrypted.webm");
        TestFileScope.WriteMinimalWebM(path, encryptedBlock: true);

        Assert.False(MediaOutputValidator.IsValidWebM(path));
    }

    [Fact]
    public void RejectsUnknownSizeLeafThatWouldHideEncryptedBlock()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("unknown-leaf.webm");
        TestFileScope.WriteMinimalWebM(path);
        List<byte> bytes = File.ReadAllBytes(path).ToList();
        byte[] hiddenEncryptedCluster =
        [
            // Unknown-size Info leaf followed by a syntactically valid
            // EncryptedBlock Cluster. Treating arbitrary unknown-size leaves
            // as parent-sized would skip the encrypted Cluster.
            0x15, 0x49, 0xA9, 0x66, 0xFF,
            0x1F, 0x43, 0xB6, 0x75, 0x87,
            0xAF, 0x85, 0x81, 0x00, 0x00, 0x80, 0x01
        ];
        bytes.AddRange(hiddenEncryptedCluster);
        int segmentPayloadLength = (bytes[16] & 0x7F) + hiddenEncryptedCluster.Length;
        bytes[16] = checked((byte)(0x80 | segmentPayloadLength));
        File.WriteAllBytes(path, bytes.ToArray());

        Assert.False(MediaOutputValidator.IsValidWebM(path));
    }

    [Fact]
    public void RejectsEbmlHeaderWithoutWebMSegment()
    {
        using var scope = new TestFileScope();
        string path = scope.PathFor("not-webm.bin");
        byte[] bytes = new byte[32];
        new byte[] { 0x1A, 0x45, 0xDF, 0xA3 }.CopyTo(bytes, 0);
        File.WriteAllBytes(path, bytes);

        Assert.False(MediaOutputValidator.IsValidWebM(path));
    }
}
