using System.Text.Json;
using System.Security.Cryptography;
using System.Runtime.Versioning;
using System.Text;

namespace HLSDownloader.Worker;

public sealed class JobLedger
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };
    private static readonly byte[] Header = "HLJ1"u8.ToArray();
    private static readonly byte[] Entropy = SHA256.HashData("HLSDownloader.Worker.JobLedger.v1"u8.ToArray());
    private const int MaximumTerminalHistory = 100;
    private static readonly TimeSpan MaximumTerminalAge = TimeSpan.FromDays(30);

    private readonly string _path;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public JobLedger(string path)
    {
        _path = Path.GetFullPath(path);
    }

    public async Task<IReadOnlyList<WorkerJobRecord>> GetJobsAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return (await ReadUnsafeAsync(cancellationToken).ConfigureAwait(false)).Jobs.ToArray();
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task AddAsync(WorkerJobRecord job, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(job);
        await MutateAsync(document =>
        {
            if (document.Jobs.Any(existing => existing.Id == job.Id))
            {
                throw new InvalidOperationException($"Worker job {job.Id} already exists.");
            }

            return document with { Jobs = document.Jobs.Append(job).ToArray() };
        }, cancellationToken).ConfigureAwait(false);
    }

    public Task UpdateAsync(Guid id, Func<WorkerJobRecord, WorkerJobRecord> update, CancellationToken cancellationToken = default) =>
        MutateAsync(document =>
        {
            bool found = false;
            WorkerJobRecord[] jobs = document.Jobs.Select(job =>
            {
                if (job.Id != id)
                {
                    return job;
                }

                found = true;
                return update(job) with { UpdatedAt = DateTimeOffset.UtcNow };
            }).ToArray();
            if (!found)
            {
                throw new KeyNotFoundException($"Worker job {id} was not found.");
            }

            return document with { Jobs = jobs };
        }, cancellationToken);

    public Task RequeueInterruptedJobsAsync(CancellationToken cancellationToken = default) =>
        MutateAsync(document => document with
        {
            Jobs = document.Jobs.Select(job => job.State == WorkerJobState.Running
                ? job with
                {
                    State = WorkerJobState.Queued,
                    Progress = 0,
                    Error = "The previous worker stopped before completion; the job was resumed.",
                    UpdatedAt = DateTimeOffset.UtcNow
                }
                : job).ToArray()
        }, cancellationToken);

    private async Task MutateAsync(
        Func<WorkerLedgerDocument, WorkerLedgerDocument> mutation,
        CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            WorkerLedgerDocument current = await ReadUnsafeAsync(cancellationToken).ConfigureAwait(false);
            await WriteUnsafeAsync(mutation(current), cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<WorkerLedgerDocument> ReadUnsafeAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_path))
        {
            return WorkerLedgerDocument.Empty;
        }

        byte[] stored = await File.ReadAllBytesAsync(_path, cancellationToken).ConfigureAwait(false);
        byte[]? encrypted = null;
        byte[]? serialized = null;
        try
        {
            if (!stored.AsSpan().StartsWith(Header))
            {
                throw new InvalidDataException("The background worker job ledger is not DPAPI protected.");
            }

            if (!OperatingSystem.IsWindows())
            {
                throw new PlatformNotSupportedException("The background worker ledger uses Windows DPAPI and is only supported on Windows.");
            }

            encrypted = stored.AsSpan(Header.Length).ToArray();
            try
            {
                serialized = UnprotectForCurrentWindowsUser(encrypted);
            }
            catch (CryptographicException ex)
            {
                throw new InvalidDataException("The background worker job ledger could not be decrypted for the current Windows user.", ex);
            }

            WorkerLedgerDocument? document = JsonSerializer.Deserialize<WorkerLedgerDocument>(serialized, JsonOptions);
            if (document is null || document.Version != 1)
            {
                throw new InvalidDataException("The background worker job ledger is invalid or unsupported.");
            }

            return document;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(stored);
            if (encrypted is not null)
            {
                CryptographicOperations.ZeroMemory(encrypted);
            }

            if (serialized is not null)
            {
                CryptographicOperations.ZeroMemory(serialized);
            }
        }
    }

    private async Task WriteUnsafeAsync(WorkerLedgerDocument document, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("The background worker ledger uses Windows DPAPI and is only supported on Windows.");
        }

        string directory = Path.GetDirectoryName(_path)!;
        Directory.CreateDirectory(directory);
        string temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        byte[]? serialized = null;
        byte[]? protectedBytes = null;
        try
        {
            WorkerLedgerDocument pruned = PruneHistory(document);
            serialized = JsonSerializer.SerializeToUtf8Bytes(pruned, JsonOptions);
            protectedBytes = ProtectForCurrentWindowsUser(serialized);
            await using (FileStream stream = new(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                32 * 1024,
                FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(Header, cancellationToken).ConfigureAwait(false);
                await stream.WriteAsync(protectedBytes, cancellationToken).ConfigureAwait(false);
                await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, _path, overwrite: true);
        }
        finally
        {
            File.Delete(temporaryPath);
            if (serialized is not null)
            {
                CryptographicOperations.ZeroMemory(serialized);
            }

            if (protectedBytes is not null)
            {
                CryptographicOperations.ZeroMemory(protectedBytes);
            }
        }
    }

    private static WorkerLedgerDocument PruneHistory(WorkerLedgerDocument document)
    {
        DateTimeOffset threshold = DateTimeOffset.UtcNow - MaximumTerminalAge;
        WorkerJobRecord[] active = document.Jobs.Where(job => job.State is WorkerJobState.Queued or WorkerJobState.Running).ToArray();
        WorkerJobRecord[] terminal = document.Jobs
            .Where(job => job.State is not (WorkerJobState.Queued or WorkerJobState.Running) && job.UpdatedAt >= threshold)
            .OrderByDescending(job => job.UpdatedAt)
            .Take(MaximumTerminalHistory)
            .ToArray();
        return document with { Jobs = active.Concat(terminal).OrderBy(job => job.CreatedAt).ToArray() };
    }

    [SupportedOSPlatform("windows")]
    private static byte[] ProtectForCurrentWindowsUser(byte[] value) =>
        ProtectedData.Protect(value, Entropy, DataProtectionScope.CurrentUser);

    [SupportedOSPlatform("windows")]
    private static byte[] UnprotectForCurrentWindowsUser(byte[] value) =>
        ProtectedData.Unprotect(value, Entropy, DataProtectionScope.CurrentUser);
}
