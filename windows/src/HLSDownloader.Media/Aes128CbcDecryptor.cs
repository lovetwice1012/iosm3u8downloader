using System.Security.Cryptography;

namespace HLSDownloader.Media;

public static class Aes128CbcDecryptor
{
    public static async Task DecryptFileAsync(
        string encryptedPath,
        string outputPath,
        ReadOnlyMemory<byte> key,
        ReadOnlyMemory<byte> initializationVector,
        CancellationToken cancellationToken = default)
    {
        if (key.Length != 16)
        {
            throw new ArgumentException("HLS AES-128 requires a 16-byte key.", nameof(key));
        }

        if (initializationVector.Length != 16)
        {
            throw new ArgumentException("AES-CBC requires a 16-byte initialization vector.", nameof(initializationVector));
        }

        string fullOutputPath = Path.GetFullPath(outputPath);
        Directory.CreateDirectory(Path.GetDirectoryName(fullOutputPath)!);
        string partialPath = fullOutputPath + ".part";
        File.Delete(partialPath);
        try
        {
            using Aes aes = Aes.Create();
            aes.KeySize = 128;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            aes.Key = key.ToArray();
            aes.IV = initializationVector.ToArray();
            await using (FileStream source = new(encryptedPath, FileMode.Open, FileAccess.Read, FileShare.Read, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            await using (FileStream target = new(partialPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await using (var crypto = new CryptoStream(source, aes.CreateDecryptor(), CryptoStreamMode.Read, leaveOpen: false))
                {
                    await crypto.CopyToAsync(target, cancellationToken).ConfigureAwait(false);
                }

                await target.FlushAsync(cancellationToken).ConfigureAwait(false);
            }

            File.Move(partialPath, fullOutputPath, overwrite: true);
        }
        finally
        {
            File.Delete(partialPath);
        }
    }

    public static byte[] CreateMediaSequenceInitializationVector(ulong mediaSequence)
    {
        byte[] result = new byte[16];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(result.AsSpan(8), mediaSequence);
        return result;
    }
}
