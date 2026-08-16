using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace HLSDownloader.Core;

public static partial class DiagnosticRedactor
{
    public static string SummarizeUri(Uri? uri)
    {
        if (uri is null || !uri.IsAbsoluteUri) return "url=invalid";
        var pathHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(uri.AbsolutePath)))[..12].ToLowerInvariant();
        var port = uri.IsDefaultPort ? string.Empty : $" port={uri.Port}";
        return $"scheme={uri.Scheme.ToLowerInvariant()} host={uri.IdnHost.ToLowerInvariant()}{port} pathHash={pathHash}";
    }

    public static string Redact(string? message)
    {
        if (string.IsNullOrEmpty(message)) return string.Empty;
        var redacted = UrlPattern().Replace(message, match =>
            Uri.TryCreate(match.Value, UriKind.Absolute, out var uri) ? SummarizeUri(uri) : "url=redacted");
        redacted = SecretAssignmentPattern().Replace(redacted, "$1=[REDACTED]");
        redacted = BearerPattern().Replace(redacted, "Bearer [REDACTED]");
        return redacted.Length <= 2048 ? redacted : redacted[..2048];
    }

    [GeneratedRegex("""https?://[^\s"'<>]+""", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, 100)]
    private static partial Regex UrlPattern();

    [GeneratedRegex(@"(?i)\b(token|authorization|cookie|password|secret|key|signature)\s*[=:]\s*[^\s,;]+",
        RegexOptions.CultureInvariant, 100)]
    private static partial Regex SecretAssignmentPattern();

    [GeneratedRegex(@"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+", RegexOptions.CultureInvariant, 100)]
    private static partial Regex BearerPattern();
}
