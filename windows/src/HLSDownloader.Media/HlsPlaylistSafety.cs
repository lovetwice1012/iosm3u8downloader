namespace HLSDownloader.Media;

public enum HlsEncryptionKind
{
    Clear,
    Aes128,
    IdentitySampleAes
}

public static class HlsPlaylistSafety
{
    public static HlsEncryptionKind ValidateSupportedEncryption(string playlistText)
    {
        ArgumentNullException.ThrowIfNull(playlistText);
        HlsEncryptionKind result = HlsEncryptionKind.Clear;
        foreach (string rawLine in playlistText.Split('\n'))
        {
            string line = rawLine.Trim();
            if (!line.StartsWith("#EXT-X-KEY:", StringComparison.OrdinalIgnoreCase) &&
                !line.StartsWith("#EXT-X-SESSION-KEY:", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            IReadOnlyDictionary<string, string> attributes = ParseAttributes(line[(line.IndexOf(':') + 1)..]);
            if (!attributes.TryGetValue("METHOD", out string? method))
            {
                throw new InvalidDataException("An HLS key declaration is missing METHOD.");
            }

            if (method.Equals("NONE", StringComparison.OrdinalIgnoreCase))
            {
                continue;
            }

            string keyFormat = attributes.TryGetValue("KEYFORMAT", out string? declaredFormat)
                ? declaredFormat
                : "identity";
            if (!keyFormat.Equals("identity", StringComparison.OrdinalIgnoreCase))
            {
                throw new NotSupportedException("FairPlay and other non-identity HLS key formats are playback-only and cannot be exported by this pipeline.");
            }

            if (method.Equals("AES-128", StringComparison.OrdinalIgnoreCase))
            {
                if (result == HlsEncryptionKind.Clear)
                {
                    result = HlsEncryptionKind.Aes128;
                }
            }
            else if (method.Equals("SAMPLE-AES", StringComparison.OrdinalIgnoreCase))
            {
                result = HlsEncryptionKind.IdentitySampleAes;
            }
            else if (method.Equals("SAMPLE-AES-CTR", StringComparison.OrdinalIgnoreCase))
            {
                throw new NotSupportedException("SAMPLE-AES-CTR is not supported by the identity SAMPLE-AES export path.");
            }
            else
            {
                throw new NotSupportedException($"HLS encryption method {method} is not supported.");
            }
        }

        return result;
    }

    internal static IReadOnlyDictionary<string, string> ParseAttributes(string value)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        int start = 0;
        bool quoted = false;
        for (int index = 0; index <= value.Length; index++)
        {
            if (index < value.Length && value[index] == '"')
            {
                quoted = !quoted;
            }

            if (index < value.Length && (value[index] != ',' || quoted))
            {
                continue;
            }

            string part = value[start..index].Trim();
            int separator = part.IndexOf('=');
            if (separator > 0)
            {
                string key = part[..separator].Trim();
                string attributeValue = part[(separator + 1)..].Trim().Trim('"');
                result[key] = attributeValue;
            }

            start = index + 1;
        }

        return result;
    }
}
