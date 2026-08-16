namespace HLSDownloader.Media.Tests;

public sealed class HlsEncryptionTests
{
    [Theory]
    [InlineData("#EXTM3U\n#EXTINF:1,\na.ts", HlsEncryptionKind.Clear)]
    [InlineData("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"", HlsEncryptionKind.Aes128)]
    [InlineData("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"identity\",URI=\"key.bin\"", HlsEncryptionKind.IdentitySampleAes)]
    public void RecognizesSupportedEncryption(string playlist, HlsEncryptionKind expected)
    {
        Assert.Equal(expected, HlsPlaylistSafety.ValidateSupportedEncryption(playlist));
    }

    [Theory]
    [InlineData("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,KEYFORMAT=\"com.apple.streamingkeydelivery\",URI=\"skd://license\"")]
    [InlineData("#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"key.bin\"")]
    public void RejectsFairPlayAndSampleAesCtr(string playlist)
    {
        Assert.Throws<NotSupportedException>(() => HlsPlaylistSafety.ValidateSupportedEncryption(playlist));
    }

    [Fact]
    public void SampleAesCannotBeDowngradedByLaterAes128Declaration()
    {
        const string playlist = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"sample.key\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"aes.key\"";

        Assert.Equal(HlsEncryptionKind.IdentitySampleAes, HlsPlaylistSafety.ValidateSupportedEncryption(playlist));
    }

    [Fact]
    public async Task Aes128DecryptsWithExplicitIv()
    {
        using var scope = new TestFileScope();
        byte[] key = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        byte[] iv = Aes128CbcDecryptor.CreateMediaSequenceInitializationVector(42);
        byte[] clear = Enumerable.Range(0, 376).Select(value => (byte)(value % 251)).ToArray();
        string encryptedPath = scope.PathFor("encrypted.bin");
        string outputPath = scope.PathFor("clear.ts");

        using (System.Security.Cryptography.Aes aes = System.Security.Cryptography.Aes.Create())
        {
            aes.Key = key;
            aes.IV = iv;
            aes.Mode = System.Security.Cryptography.CipherMode.CBC;
            aes.Padding = System.Security.Cryptography.PaddingMode.PKCS7;
            using var transform = aes.CreateEncryptor();
            File.WriteAllBytes(encryptedPath, transform.TransformFinalBlock(clear, 0, clear.Length));
        }

        await Aes128CbcDecryptor.DecryptFileAsync(encryptedPath, outputPath, key, iv);

        Assert.Equal(clear, await File.ReadAllBytesAsync(outputPath));
        Assert.Equal(42UL, System.Buffers.Binary.BinaryPrimitives.ReadUInt64BigEndian(iv.AsSpan(8)));
    }
}
