namespace HLSDownloader.Core;

public abstract record HlsPlaylist(Uri EffectiveUri);

public sealed record HlsMasterPlaylist(
    Uri EffectiveUri,
    IReadOnlyList<HlsVariant> Variants,
    IReadOnlyList<HlsRendition> Renditions) : HlsPlaylist(EffectiveUri);

public sealed record HlsVariant(
    Uri Uri,
    long Bandwidth,
    long? AverageBandwidth,
    string? Resolution,
    string? AudioGroupId);

public sealed record HlsRendition(
    string Type,
    string GroupId,
    string Name,
    Uri? Uri,
    bool IsDefault,
    bool IsAutoSelect);

public enum HlsEncryptionMethod
{
    Aes128,
    SampleAes
}

public sealed record HlsEncryption(
    HlsEncryptionMethod Method,
    Uri KeyUri,
    byte[]? ExplicitIv);

public sealed record HlsByteRange(long Offset, long Length)
{
    public long ExclusiveEnd => checked(Offset + Length);
}

public sealed record HlsInitializationMap(
    Uri Uri,
    HlsByteRange? ByteRange,
    HlsEncryption? Encryption);

public sealed record HlsSegment(
    int Ordinal,
    ulong MediaSequence,
    double Duration,
    Uri Uri,
    HlsByteRange? ByteRange,
    HlsEncryption? Encryption,
    HlsInitializationMap? InitializationMap,
    bool HasDiscontinuity);

public sealed record HlsMediaPlaylist(
    Uri EffectiveUri,
    IReadOnlyList<HlsSegment> Segments,
    bool HasEndList,
    Uri? Referer = null) : HlsPlaylist(EffectiveUri)
{
    public bool UsesSampleAes => Segments.Any(s =>
        s.Encryption?.Method == HlsEncryptionMethod.SampleAes ||
        s.InitializationMap?.Encryption?.Method == HlsEncryptionMethod.SampleAes);
}
