using System.Diagnostics;
using System.Text;

namespace HLSDownloader.Media;

public sealed record ExternalToolInvocation(
    string ExecutablePath,
    IReadOnlyList<string> Arguments,
    TimeSpan Timeout,
    IReadOnlyCollection<string>? RedactedValues = null,
    string? WorkingDirectory = null);

public sealed record ExternalToolResult(int ExitCode, string StandardOutput, string StandardError);

public interface IExternalToolRunner
{
    Task<ExternalToolResult> RunAsync(ExternalToolInvocation invocation, CancellationToken cancellationToken = default);
}

public sealed class ExternalToolException(string message, int? exitCode = null) : Exception(message)
{
    public int? ExitCode { get; } = exitCode;
}

public sealed class ExternalToolRunner(Action<string>? log = null, int outputLimitCharacters = 4 * 1024 * 1024)
    : IExternalToolRunner
{
    private readonly Action<string>? _log = log;
    private readonly int _outputLimitCharacters = outputLimitCharacters > 0
        ? outputLimitCharacters
        : throw new ArgumentOutOfRangeException(nameof(outputLimitCharacters));

    public async Task<ExternalToolResult> RunAsync(
        ExternalToolInvocation invocation,
        CancellationToken cancellationToken = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(invocation.ExecutablePath);
        if (invocation.Timeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(invocation), "The external tool timeout must be positive.");
        }

        using var process = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = invocation.ExecutablePath,
                WorkingDirectory = invocation.WorkingDirectory ?? string.Empty,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            }
        };

        foreach (string argument in invocation.Arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        string displayCommand = string.Join(' ', new[] { invocation.ExecutablePath }.Concat(invocation.Arguments).Select(QuoteForLog));
        _log?.Invoke($"Starting external media tool: {Redact(displayCommand, invocation.RedactedValues)}");

        try
        {
            if (!process.Start())
            {
                throw new ExternalToolException("The external media tool could not be started.");
            }
        }
        catch (Exception ex) when (ex is not ExternalToolException)
        {
            throw new ExternalToolException($"The external media tool could not be started: {ex.Message}");
        }

        using var timeoutSource = new CancellationTokenSource(invocation.Timeout);
        using var linkedSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeoutSource.Token);
        Task<string> standardOutput = ReadBoundedAsync(process.StandardOutput, _outputLimitCharacters);
        Task<string> standardError = ReadBoundedAsync(process.StandardError, _outputLimitCharacters);

        try
        {
            await process.WaitForExitAsync(linkedSource.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryKillProcessTree(process);
            await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            if (timeoutSource.IsCancellationRequested && !cancellationToken.IsCancellationRequested)
            {
                throw new TimeoutException($"The external media tool exceeded {invocation.Timeout}.");
            }

            throw;
        }

        string stdout = await standardOutput.ConfigureAwait(false);
        string stderr = await standardError.ConfigureAwait(false);
        string safeError = Redact(stderr, invocation.RedactedValues);
        _log?.Invoke($"External media tool exited with code {process.ExitCode}: {safeError}");
        return new ExternalToolResult(process.ExitCode, stdout, safeError);
    }

    internal static string Redact(string value, IReadOnlyCollection<string>? secrets)
    {
        if (secrets is null)
        {
            return value;
        }

        string result = value;
        foreach (string secret in secrets.Where(item => !string.IsNullOrEmpty(item)).OrderByDescending(item => item.Length))
        {
            result = result.Replace(secret, "<redacted>", StringComparison.OrdinalIgnoreCase);
        }

        return result;
    }

    private static async Task<string> ReadBoundedAsync(StreamReader reader, int limit)
    {
        var builder = new StringBuilder(Math.Min(limit, 16 * 1024));
        char[] buffer = new char[4096];
        bool truncated = false;
        int count;
        while ((count = await reader.ReadAsync(buffer).ConfigureAwait(false)) > 0)
        {
            int remaining = limit - builder.Length;
            if (remaining > 0)
            {
                builder.Append(buffer, 0, Math.Min(remaining, count));
            }

            truncated |= count > remaining;
        }

        if (truncated)
        {
            builder.AppendLine().Append("[output truncated]");
        }

        return builder.ToString();
    }

    private static string QuoteForLog(string argument) => argument.Any(char.IsWhiteSpace)
        ? $"\"{argument.Replace("\"", "\\\"", StringComparison.Ordinal)}\""
        : argument;

    private static void TryKillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
            // The process exited between the checks.
        }
    }
}
