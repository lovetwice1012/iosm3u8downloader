namespace HLSDownloader.Worker;

using HLSDownloader.Core;

public enum WorkerJobState
{
    Queued,
    Running,
    Completed,
    Failed,
    Cancelled
}

public enum WorkerJobKind
{
    LocalMedia,
    HlsUrl
}

public sealed record WorkerJobRecord(
    Guid Id,
    string InputPath,
    string OutputBasePath,
    WorkerJobState State,
    double Progress,
    DateTimeOffset CreatedAt,
    DateTimeOffset UpdatedAt,
    int AttemptCount = 0,
    string? OutputPath = null,
    string? Error = null,
    WorkerJobKind Kind = WorkerJobKind.LocalMedia,
    string? CandidateUri = null,
    string? PageUri = null,
    string? RequestedUri = null)
{
    public static WorkerJobRecord Create(string inputPath, string outputBasePath) => new(
        Guid.NewGuid(),
        Path.GetFullPath(inputPath),
        Path.GetFullPath(outputBasePath),
        WorkerJobState.Queued,
        0,
        DateTimeOffset.UtcNow,
        DateTimeOffset.UtcNow);

    public static WorkerJobRecord CreateHls(
        Uri candidateUri,
        Uri requestedUri,
        Uri pageUri,
        string outputBasePath) => new(
        Guid.NewGuid(),
        string.Empty,
        Path.GetFullPath(outputBasePath),
        WorkerJobState.Queued,
        0,
        DateTimeOffset.UtcNow,
        DateTimeOffset.UtcNow,
        Kind: WorkerJobKind.HlsUrl,
        CandidateUri: candidateUri.AbsoluteUri,
        PageUri: pageUri.AbsoluteUri,
        RequestedUri: requestedUri.AbsoluteUri);

    public static WorkerJobRecord CreateHls(MediaCandidate candidate, string outputBasePath) =>
        CreateHls(candidate.Uri, candidate.RequestedUri ?? candidate.Uri, candidate.PageUri, outputBasePath);
}

public sealed record WorkerLedgerDocument(int Version, IReadOnlyList<WorkerJobRecord> Jobs)
{
    public static WorkerLedgerDocument Empty { get; } = new(1, Array.Empty<WorkerJobRecord>());
}

public sealed record WorkerProgressEvent(
    Guid JobId,
    WorkerJobState State,
    double Progress,
    string? OutputPath = null,
    string? Error = null);

public sealed record WorkerPipeCommand(string Type, WorkerJobRecord? Job = null, Guid? JobId = null);

public sealed record WorkerPipeResponse(
    bool Ok,
    string? Error = null,
    WorkerProgressEvent? Progress = null,
    IReadOnlyList<WorkerJobRecord>? Jobs = null);
