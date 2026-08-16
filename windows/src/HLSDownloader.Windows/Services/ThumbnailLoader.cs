using HLSDownloader.Core;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace HLSDownloader.Windows.Services;

public sealed class ThumbnailLoader : IDisposable
{
    private const int MaximumThumbnailBytes = 4 * 1024 * 1024;
    private readonly BoundedHttpClient _client = new(new BoundedHttpOptions(
        MaximumResponseBytes: MaximumThumbnailBytes,
        MaximumRedirects: 3,
        RequestTimeout: TimeSpan.FromSeconds(12),
        UserAgent: "HLSDownloader-Windows/1.0 thumbnail"));

    public async Task<BitmapImage?> LoadAsync(Uri thumbnailUri, Uri referer, CancellationToken cancellationToken)
    {
        var resource = await _client.FetchAsync(
            thumbnailUri,
            referer,
            cancellationToken: cancellationToken);
        if (!IsSupportedImage(resource.Data, resource.MediaType))
        {
            return null;
        }

        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream))
        {
            writer.WriteBytes(resource.Data);
            await writer.StoreAsync();
            await writer.FlushAsync();
            writer.DetachStream();
        }

        stream.Seek(0);
        var image = new BitmapImage();
        await image.SetSourceAsync(stream);
        return image;
    }

    public void Dispose() => _client.Dispose();

    private static bool IsSupportedImage(ReadOnlySpan<byte> data, string? mediaType)
    {
        if (data.Length < 12 || data.Length > MaximumThumbnailBytes)
        {
            return false;
        }

        var mimeAllowed = mediaType is null
            || mediaType.Equals("image/jpeg", StringComparison.OrdinalIgnoreCase)
            || mediaType.Equals("image/png", StringComparison.OrdinalIgnoreCase)
            || mediaType.Equals("image/webp", StringComparison.OrdinalIgnoreCase)
            || mediaType.Equals("image/gif", StringComparison.OrdinalIgnoreCase);
        if (!mimeAllowed)
        {
            return false;
        }

        return data.StartsWith(new byte[] { 0xFF, 0xD8, 0xFF })
            || data.StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A })
            || data.StartsWith("GIF87a"u8)
            || data.StartsWith("GIF89a"u8)
            || (data.StartsWith("RIFF"u8) && data[8..].StartsWith("WEBP"u8));
    }
}
