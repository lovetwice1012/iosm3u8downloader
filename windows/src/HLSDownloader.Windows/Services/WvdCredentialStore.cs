using System.Security.Cryptography;
using HLSDownloader.Media;
using Windows.Security.Cryptography;
using Windows.Security.Cryptography.DataProtection;

namespace HLSDownloader.Windows.Services;

public sealed class WvdCredentialStore : IWidevineCredentialSource
{
    private readonly string _path = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "HLSDownloader.Windows",
        "widevine.wvd.protected");

    public bool HasCredential
    {
        get
        {
            try
            {
                return File.Exists(_path) && new FileInfo(_path).Length > 0;
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
    }

    bool IWidevineCredentialSource.IsAvailable => HasCredential;

    public async Task ImportAsync(string sourcePath, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(sourcePath);
        if (!string.Equals(Path.GetExtension(sourcePath), ".wvd", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(".wvd ファイルを選択してください。");
        }

        var fileInfo = new FileInfo(sourcePath);
        if (!fileInfo.Exists || fileInfo.Length is <= 0 or > WvdFileValidator.MaximumFileBytes)
        {
            throw new InvalidDataException("WVDファイルのサイズが不正です。");
        }

        var clearBytes = await File.ReadAllBytesAsync(sourcePath, cancellationToken).ConfigureAwait(false);
        try
        {
            WvdFileValidator.Validate(clearBytes);
            using (var client = new WidevineL3Client(clearBytes))
            {
                // Constructor validation proves the certificate and RSA private key match.
            }
            var protector = new DataProtectionProvider("LOCAL=user");
            var encrypted = await protector.ProtectAsync(CryptographicBuffer.CreateFromByteArray(clearBytes));
            CryptographicBuffer.CopyToByteArray(encrypted, out var encryptedBytes);
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            await File.WriteAllBytesAsync(_path, encryptedBytes, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }

    async Task<WidevineCredentialLease> IWidevineCredentialSource.LoadAsync(
        CancellationToken cancellationToken)
    {
        var clearBytes = await LoadClearBytesAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return new WidevineCredentialLease(clearBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(clearBytes);
        }
    }

    private async Task<byte[]> LoadClearBytesAsync(CancellationToken cancellationToken)
    {
        var encryptedBytes = await File.ReadAllBytesAsync(_path, cancellationToken).ConfigureAwait(false);
        try
        {
            var protector = new DataProtectionProvider();
            var clear = await protector.UnprotectAsync(CryptographicBuffer.CreateFromByteArray(encryptedBytes));
            CryptographicBuffer.CopyToByteArray(clear, out var clearBytes);
            try
            {
                WvdFileValidator.Validate(clearBytes);
                using (var client = new WidevineL3Client(clearBytes))
                {
                    // Reject corrupted or mismatched credentials before leasing them.
                }
                return clearBytes;
            }
            catch
            {
                CryptographicOperations.ZeroMemory(clearBytes);
                throw;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(encryptedBytes);
        }
    }

    public void Remove()
    {
        if (File.Exists(_path))
        {
            File.Delete(_path);
        }
    }
}
