using System.Buffers.Binary;
using System.Security.Cryptography;

namespace HLSDownloader.Media;

public enum WidevineLicenseType : ulong
{
    Streaming = 1,
    Offline = 2,
    Automatic = 3
}

public enum WidevineContentKeyType : ulong
{
    Signing = 1,
    Content = 2,
    KeyControl = 3,
    OperatorSession = 4,
    Entitlement = 5,
    OemContent = 6
}

public sealed class WidevineContentKey : IDisposable
{
    private byte[]? _value;

    public WidevineContentKey(byte[] id, byte[] value, WidevineContentKeyType type)
    {
        ArgumentNullException.ThrowIfNull(id);
        ArgumentNullException.ThrowIfNull(value);
        Id = id.ToArray();
        _value = value.ToArray();
        Type = type;
    }

    public byte[] Id { get; }
    public WidevineContentKeyType Type { get; }
    internal ReadOnlySpan<byte> Value => _value ?? throw new ObjectDisposedException(nameof(WidevineContentKey));

    public byte[] CopyValue() => Value.ToArray();

    public void Dispose()
    {
        if (_value is { } value)
        {
            CryptographicOperations.ZeroMemory(value);
            _value = null;
        }

        CryptographicOperations.ZeroMemory(Id);
        GC.SuppressFinalize(this);
    }

    public override string ToString() => "WidevineContentKey(<redacted>)";
}

public sealed class WidevineLicenseChallenge : IDisposable
{
    private byte[]? _requestData;
    private byte[]? _licenseRequestData;
    private byte[]? _requestId;

    internal WidevineLicenseChallenge(
        byte[] requestData,
        byte[] licenseRequestData,
        IReadOnlyCollection<ByteString>? expectedKeyIds,
        byte[] requestId)
    {
        _requestData = requestData;
        _licenseRequestData = licenseRequestData;
        ExpectedKeyIds = expectedKeyIds;
        _requestId = requestId;
    }

    public ReadOnlyMemory<byte> RequestData => _requestData ?? throw new ObjectDisposedException(nameof(WidevineLicenseChallenge));
    internal ReadOnlyMemory<byte> LicenseRequestData => _licenseRequestData ?? throw new ObjectDisposedException(nameof(WidevineLicenseChallenge));
    internal IReadOnlyCollection<ByteString>? ExpectedKeyIds { get; }
    internal ReadOnlyMemory<byte> RequestId => _requestId ?? throw new ObjectDisposedException(nameof(WidevineLicenseChallenge));

    public void Dispose()
    {
        ZeroAndRelease(ref _requestData);
        ZeroAndRelease(ref _licenseRequestData);
        ZeroAndRelease(ref _requestId);
        GC.SuppressFinalize(this);
    }

    public override string ToString() => "WidevineLicenseChallenge(<redacted>)";

    private static void ZeroAndRelease(ref byte[]? value)
    {
        if (value is null) return;
        CryptographicOperations.ZeroMemory(value);
        value = null;
    }
}

public sealed class WidevineL3ClientException : Exception
{
    public WidevineL3ClientException(string message) : base(message) { }
    public WidevineL3ClientException(string message, Exception innerException) : base(message, innerException) { }
}

/// <summary>
/// Minimal software-secure Widevine client used only by the exact-host gated
/// download provider. It supports WVD v2 L3 credentials, raw SignedMessage
/// requests, offline licenses, RSA-PSS/SHA-1 request signatures, RSA-OAEP/SHA-1
/// session keys and CENC content keys. It deliberately rejects privacy mode,
/// renewal, expiry, output-protection and any unknown policy constraint.
/// </summary>
public sealed class WidevineL3Client : IDisposable
{
    private const int MaximumWvdBytes = 256 * 1024;
    private const int MaximumPsshBytes = 2 * 1024 * 1024;
    private byte[]? _clientIdentification;
    private readonly RSA _privateKey;
    private readonly byte _deviceType;
    private readonly Func<long> _clock;
    private readonly Func<int, byte[]> _randomBytes;
    private bool _disposed;

    public WidevineL3Client(
        ReadOnlySpan<byte> wvdData,
        Func<long>? clock = null,
        Func<int, byte[]>? randomBytes = null)
    {
        if (wvdData.Length is <= 0 or > MaximumWvdBytes)
            throw Error("WVD credential size is invalid.");

        WvdFields fields = ParseWvd(wvdData);
        _privateKey = ImportPrivateKey(fields.PrivateKey);
        try
        {
            int keyBytes = _privateKey.KeySize / 8;
            if (keyBytes is < 256 or > 512)
                throw Error("The WVD RSA key size is unsupported.");
            ValidateClientIdentification(fields.ClientIdentification, _privateKey);
            _clientIdentification = fields.ClientIdentification;
            fields.ClientIdentification = [];
        }
        catch
        {
            _privateKey.Dispose();
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(fields.PrivateKey);
            CryptographicOperations.ZeroMemory(fields.ClientIdentification);
        }

        _deviceType = wvdData[4];
        _clock = clock ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        _randomBytes = randomBytes ?? RandomNumberGenerator.GetBytes;
    }

    public WidevineLicenseChallenge MakeLicenseChallenge(
        ReadOnlySpan<byte> psshData,
        WidevineLicenseType licenseType = WidevineLicenseType.Offline)
    {
        ThrowIfDisposed();
        byte[] payload = WidevinePssh.Payload(psshData, MaximumPsshBytes);
        try
        {
            IReadOnlyCollection<ByteString>? expectedKeyIds = WidevinePssh.KeyIdsFromPayload(payload);
            byte[] requestId = MakeRequestId();
            byte[] nonceBytes = _randomBytes(4);
            if (nonceBytes.Length != 4)
                throw Error("Widevine request entropy generation failed.");
            uint nonce = BinaryPrimitives.ReadUInt32BigEndian(nonceBytes) & 0x7fff_ffff;
            CryptographicOperations.ZeroMemory(nonceBytes);
            if (nonce == 0) nonce = 1;

            var pssh = new WidevineProtobufWriter();
            pssh.AppendBytes(1, payload);
            pssh.AppendVarint(2, (ulong)licenseType);
            pssh.AppendBytes(3, requestId);

            var contentIdentification = new WidevineProtobufWriter();
            contentIdentification.AppendMessage(1, pssh.ToArray());

            var request = new WidevineProtobufWriter();
            request.AppendMessage(1, _clientIdentification!);
            request.AppendMessage(2, contentIdentification.ToArray());
            request.AppendVarint(3, 1); // LicenseRequest.NEW
            request.AppendVarint(4, (ulong)Math.Max(_clock(), 0));
            request.AppendVarint(6, 21); // VERSION_2_1
            request.AppendVarint(7, nonce);
            byte[] requestData = request.ToArray();

            byte[] signature;
            try
            {
                signature = _privateKey.SignData(
                    requestData,
                    HashAlgorithmName.SHA1,
                    RSASignaturePadding.Pss);
            }
            catch (CryptographicException exception)
            {
                CryptographicOperations.ZeroMemory(requestData);
                CryptographicOperations.ZeroMemory(requestId);
                throw Error("Widevine request signing failed.", exception);
            }

            var signed = new WidevineProtobufWriter();
            signed.AppendVarint(1, 1); // SignedMessage.LICENSE_REQUEST
            signed.AppendBytes(2, requestData);
            signed.AppendBytes(3, signature);
            CryptographicOperations.ZeroMemory(signature);
            return new WidevineLicenseChallenge(
                signed.ToArray(),
                requestData,
                expectedKeyIds,
                requestId);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(payload);
        }
    }

    public IReadOnlyList<WidevineContentKey> ParseLicense(
        ReadOnlySpan<byte> response,
        WidevineLicenseChallenge challenge)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(challenge);
        WidevineSignedMessage signed = WidevineSignedMessage.Parse(response);
        if (signed.Type is 4 or 5 || signed.RemoteAttestation is not null)
            throw Error("Widevine privacy mode is unsupported.");
        if (signed.Type == 3)
            throw Error("The Widevine license server rejected the request.");
        if (signed.Type != 2)
            throw Error("The Widevine response message type is invalid.");
        if (signed.SessionKeyType is not null and not 1)
            throw Error("The Widevine session key type is unsupported.");
        if (signed.SessionKey is not { Length: > 0 })
            throw Error("The Widevine response has no session key.");
        if (signed.Signature is not { Length: 32 })
            throw Error("The Widevine response authentication value is invalid.");
        if (signed.Message is null)
            throw Error("The Widevine response has no license message.");

        byte[] sessionKey;
        try
        {
            sessionKey = _privateKey.Decrypt(signed.SessionKey, RSAEncryptionPadding.OaepSHA1);
        }
        catch (CryptographicException exception)
        {
            throw Error("The Widevine session key could not be decrypted.", exception);
        }

        if (sessionKey.Length != 16)
        {
            CryptographicOperations.ZeroMemory(sessionKey);
            throw Error("The Widevine session key length is invalid.");
        }

        byte[] encryptionKey = [];
        byte[] authenticationKey = [];
        try
        {
            encryptionKey = WidevineL3Crypto.DeriveEncryptionKey(challenge.LicenseRequestData.Span, sessionKey);
            authenticationKey = WidevineL3Crypto.DeriveAuthenticationKey(challenge.LicenseRequestData.Span, sessionKey);
            byte[] authenticated = new byte[(signed.OemcryptoCoreMessage?.Length ?? 0) + signed.Message.Length];
            int offset = 0;
            if (signed.OemcryptoCoreMessage is { } core)
            {
                core.CopyTo(authenticated, offset);
                offset += core.Length;
            }
            signed.Message.CopyTo(authenticated, offset);
            byte[] expectedSignature = HMACSHA256.HashData(authenticationKey, authenticated);
            CryptographicOperations.ZeroMemory(authenticated);
            bool authenticatedResponse = CryptographicOperations.FixedTimeEquals(expectedSignature, signed.Signature);
            CryptographicOperations.ZeroMemory(expectedSignature);
            if (!authenticatedResponse)
                throw Error("Widevine license response authentication failed.");

            using WidevineLicenseMessage license = WidevineLicenseMessage.Parse(signed.Message);
            if (license.Identification?.RequestId is null ||
                !CryptographicOperations.FixedTimeEquals(license.Identification.RequestId, challenge.RequestId.Span))
                throw Error("The Widevine response does not match its request.");
            if (license.Identification.LicenseType != (ulong)WidevineLicenseType.Offline)
                throw Error("The Widevine response is not an offline license.");
            if (license.HasUnsupportedConstraint)
                throw Error("The Widevine license contains an unsupported policy constraint.");
            ValidatePolicy(license.Policy, license.LicenseStartTime);

            var keys = new List<WidevineContentKey>();
            var seen = new HashSet<ByteString>();
            int signingKeyCount = 0;
            try
            {
                foreach (WidevineEncryptedKey encrypted in license.Keys)
                {
                    if (!Enum.IsDefined(typeof(WidevineContentKeyType), encrypted.Type))
                        throw Error("The Widevine key type is unsupported.");
                    var keyType = (WidevineContentKeyType)encrypted.Type;
                    if (keyType is not WidevineContentKeyType.Content and not WidevineContentKeyType.Signing)
                        throw Error("The Widevine license contains an unsupported key type.");
                    if (encrypted.HasUnsupportedConstraint)
                        throw Error("The Widevine key contains an unsupported protection constraint.");
                    if (encrypted.SecurityLevel != 1)
                        throw Error("The Widevine key requires stronger than software-secure crypto.");
                    if (encrypted.Iv is not { Length: 16 } iv ||
                        encrypted.Key is not { Length: > 0 } ciphertext ||
                        ciphertext.Length % 16 != 0)
                        throw Error("The encrypted Widevine key is malformed.");
                    byte[] value = WidevineL3Crypto.DecryptAesCbcPkcs7(ciphertext, encryptionKey, iv);
                    try
                    {
                        if (value.Length != 16)
                            throw Error("The Widevine key length is invalid.");

                        if (keyType == WidevineContentKeyType.Signing)
                        {
                            signingKeyCount++;
                            if (signingKeyCount > 1)
                                throw Error("The Widevine license contains multiple signing keys.");
                            continue;
                        }

                        if (encrypted.Id is not { Length: 16 } id)
                            throw Error("The Widevine content key ID is invalid.");
                        var idValue = new ByteString(id);
                        if (!seen.Add(idValue))
                            throw Error("The Widevine license contains a duplicate key ID.");
                        if (challenge.ExpectedKeyIds is { } expected && !expected.Contains(idValue))
                            throw Error("The Widevine license contains an unexpected key ID.");
                        keys.Add(new WidevineContentKey(id, value, keyType));
                    }
                    finally
                    {
                        CryptographicOperations.ZeroMemory(value);
                    }
                }

                if (signingKeyCount != 1)
                    throw Error("The Widevine license must contain exactly one signing key.");
                if (keys.Count == 0)
                    throw Error("The Widevine license contains no content keys.");
                return keys;
            }
            catch
            {
                foreach (WidevineContentKey key in keys) key.Dispose();
                throw;
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sessionKey);
            CryptographicOperations.ZeroMemory(encryptionKey);
            CryptographicOperations.ZeroMemory(authenticationKey);
            signed.Dispose();
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_clientIdentification is { } clientIdentification)
            CryptographicOperations.ZeroMemory(clientIdentification);
        _clientIdentification = null;
        _privateKey.Dispose();
        GC.SuppressFinalize(this);
    }

    private static void ValidatePolicy(WidevineLicensePolicy? policy, ulong? licenseStartTime)
    {
        if (policy is null || !policy.CanPlay)
            throw Error("The Widevine license does not permit playback.");
        if (!policy.CanPersist)
            throw Error("The Widevine license does not permit persistence.");
        if (policy.CanRenew || policy.HasUnsupportedConstraint ||
            (policy.RentalDurationSeconds ?? 0) != 0 ||
            (policy.PlaybackDurationSeconds ?? 0) != 0 ||
            (policy.LicenseDurationSeconds ?? 0) != 0)
            throw Error("The Widevine license contains constraints that cannot be enforced on an exported file.");
        if (licenseStartTime > long.MaxValue)
            throw Error("The Widevine license timestamp is invalid.");
    }

    private byte[] MakeRequestId()
    {
        if (_deviceType == 1)
        {
            byte[] value = _randomBytes(16);
            if (value.Length != 16) throw Error("Widevine request entropy generation failed.");
            return value;
        }

        byte[] prefix = _randomBytes(4);
        if (prefix.Length != 4) throw Error("Widevine request entropy generation failed.");
        Span<byte> binary = stackalloc byte[16];
        prefix.CopyTo(binary);
        CryptographicOperations.ZeroMemory(prefix);
        BinaryPrimitives.WriteUInt64LittleEndian(binary[8..], 1);
        return System.Text.Encoding.ASCII.GetBytes(Convert.ToHexString(binary));
    }

    private static WvdFields ParseWvd(ReadOnlySpan<byte> data)
    {
        if (data.Length < 7 || !data[..3].SequenceEqual("WVD"u8) || data[3] != 2 ||
            data[4] is not 1 and not 2 || data[5] != 3 || data[6] != 0)
            throw Error("The WVD v2 L3 credential header is invalid.");
        int cursor = 7;
        byte[] privateKey = ReadWvdField(data, ref cursor);
        byte[] clientIdentification = ReadWvdField(data, ref cursor);
        if (cursor != data.Length)
        {
            CryptographicOperations.ZeroMemory(privateKey);
            CryptographicOperations.ZeroMemory(clientIdentification);
            throw Error("The WVD credential has trailing data.");
        }
        return new WvdFields(privateKey, clientIdentification);
    }

    private static byte[] ReadWvdField(ReadOnlySpan<byte> data, ref int cursor)
    {
        if (cursor > data.Length - 2) throw Error("The WVD credential is truncated.");
        int length = BinaryPrimitives.ReadUInt16BigEndian(data[cursor..]);
        cursor += 2;
        if (length <= 0 || cursor > data.Length - length)
            throw Error("The WVD credential contains an invalid field.");
        byte[] value = data.Slice(cursor, length).ToArray();
        cursor += length;
        return value;
    }

    private static RSA ImportPrivateKey(ReadOnlySpan<byte> encoded)
    {
        RSA rsa = RSA.Create();
        try
        {
            try
            {
                rsa.ImportRSAPrivateKey(encoded, out int read);
                if (read != encoded.Length) throw new CryptographicException();
                return rsa;
            }
            catch (CryptographicException)
            {
                rsa.ImportPkcs8PrivateKey(encoded, out int read);
                if (read != encoded.Length) throw new CryptographicException();
                return rsa;
            }
        }
        catch (CryptographicException exception)
        {
            rsa.Dispose();
            throw Error("The WVD RSA private key is invalid.", exception);
        }
    }

    private static void ValidateClientIdentification(ReadOnlySpan<byte> clientIdentification, RSA privateKey)
    {
        try
        {
            byte[] signedCertificate = RequireSingleBytesField(clientIdentification, 2);
            byte[] certificate = RequireSingleBytesField(signedCertificate, 1);
            byte[] encodedPublicKey = RequireSingleBytesField(certificate, 4);
            using RSA publicKey = RSA.Create();
            try
            {
                try
                {
                    publicKey.ImportRSAPublicKey(encodedPublicKey, out int read);
                    if (read != encodedPublicKey.Length) throw new CryptographicException();
                }
                catch (CryptographicException)
                {
                    publicKey.ImportSubjectPublicKeyInfo(encodedPublicKey, out int read);
                    if (read != encodedPublicKey.Length) throw new CryptographicException();
                }

                RSAParameters certificateParameters = publicKey.ExportParameters(false);
                RSAParameters privateParameters = privateKey.ExportParameters(false);
                if (certificateParameters.Modulus is null || privateParameters.Modulus is null ||
                    certificateParameters.Exponent is null || privateParameters.Exponent is null ||
                    !CryptographicOperations.FixedTimeEquals(certificateParameters.Modulus, privateParameters.Modulus) ||
                    !CryptographicOperations.FixedTimeEquals(certificateParameters.Exponent, privateParameters.Exponent))
                    throw Error("The WVD certificate does not match its private key.");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(signedCertificate);
                CryptographicOperations.ZeroMemory(certificate);
                CryptographicOperations.ZeroMemory(encodedPublicKey);
            }
        }
        catch (WidevineL3ClientException)
        {
            throw;
        }
        catch (Exception exception) when (exception is InvalidDataException or CryptographicException)
        {
            throw Error("The WVD client identification is invalid.", exception);
        }
    }

    private static byte[] RequireSingleBytesField(ReadOnlySpan<byte> data, int number)
    {
        var reader = new WidevineProtobufReader(data);
        byte[]? result = null;
        while (reader.TryRead(out WidevineProtobufField field))
        {
            if (field.Number != number) continue;
            if (field.WireType != 2 || result is not null || field.Bytes is null)
                throw Error("The WVD client identification is invalid.");
            result = field.Bytes;
        }
        return result ?? throw Error("The WVD client identification is invalid.");
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    private static WidevineL3ClientException Error(string message, Exception? inner = null)
        => inner is null ? new(message) : new(message, inner);

    private sealed class WvdFields(byte[] privateKey, byte[] clientIdentification)
    {
        public byte[] PrivateKey { get; set; } = privateKey;
        public byte[] ClientIdentification { get; set; } = clientIdentification;
    }
}

internal static class WidevineL3Crypto
{
    public static byte[] DeriveEncryptionKey(ReadOnlySpan<byte> request, ReadOnlySpan<byte> sessionKey)
    {
        if (sessionKey.Length != 16) throw new WidevineL3ClientException("The Widevine session key length is invalid.");
        byte[] input = new byte[1 + 10 + 1 + request.Length + 4];
        input[0] = 1;
        "ENCRYPTION"u8.CopyTo(input.AsSpan(1));
        request.CopyTo(input.AsSpan(12));
        input[^1] = 0x80;
        byte[] result = AesCmac(input, sessionKey);
        CryptographicOperations.ZeroMemory(input);
        return result;
    }

    public static byte[] DeriveAuthenticationKey(ReadOnlySpan<byte> request, ReadOnlySpan<byte> sessionKey)
    {
        if (sessionKey.Length != 16) throw new WidevineL3ClientException("The Widevine session key length is invalid.");
        byte[] input = new byte[1 + 14 + 1 + request.Length + 4];
        input[0] = 1;
        "AUTHENTICATION"u8.CopyTo(input.AsSpan(1));
        request.CopyTo(input.AsSpan(16));
        input[^2] = 0x02;
        byte[] first = AesCmac(input, sessionKey);
        input[0] = 2;
        byte[] second = AesCmac(input, sessionKey);
        CryptographicOperations.ZeroMemory(input);
        byte[] result = new byte[32];
        first.CopyTo(result, 0);
        second.CopyTo(result, 16);
        CryptographicOperations.ZeroMemory(first);
        CryptographicOperations.ZeroMemory(second);
        return result;
    }

    public static byte[] AesCmac(ReadOnlySpan<byte> message, ReadOnlySpan<byte> key)
    {
        if (key.Length != 16) throw new WidevineL3ClientException("The Widevine session key length is invalid.");
        byte[] zero = new byte[16];
        byte[] l = EncryptEcb(zero, key);
        byte[] firstSubkey = Double(l);
        byte[] secondSubkey = Double(firstSubkey);
        CryptographicOperations.ZeroMemory(l);
        int blockCount = Math.Max(1, (message.Length + 15) / 16);
        bool complete = message.Length > 0 && message.Length % 16 == 0;
        byte[] last = new byte[16];
        int lastOffset = (blockCount - 1) * 16;
        if (complete)
        {
            message.Slice(lastOffset, 16).CopyTo(last);
            Xor(last, firstSubkey);
        }
        else
        {
            message[lastOffset..].CopyTo(last);
            last[message.Length - lastOffset] = 0x80;
            Xor(last, secondSubkey);
        }
        CryptographicOperations.ZeroMemory(firstSubkey);
        CryptographicOperations.ZeroMemory(secondSubkey);
        byte[] state = new byte[16];
        for (int block = 0; block < blockCount - 1; block++)
        {
            byte[] value = message.Slice(block * 16, 16).ToArray();
            Xor(value, state);
            CryptographicOperations.ZeroMemory(state);
            state = EncryptEcb(value, key);
            CryptographicOperations.ZeroMemory(value);
        }
        Xor(last, state);
        CryptographicOperations.ZeroMemory(state);
        byte[] result = EncryptEcb(last, key);
        CryptographicOperations.ZeroMemory(last);
        return result;
    }

    public static byte[] DecryptAesCbcPkcs7(ReadOnlySpan<byte> ciphertext, ReadOnlySpan<byte> key, ReadOnlySpan<byte> iv)
    {
        if (key.Length != 16 || iv.Length != 16 || ciphertext.Length == 0 || ciphertext.Length % 16 != 0)
            throw new WidevineL3ClientException("The encrypted Widevine content key is malformed.");
        using Aes aes = Aes.Create();
        aes.Key = key.ToArray();
        aes.IV = iv.ToArray();
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        try
        {
            return aes.DecryptCbc(ciphertext, iv, PaddingMode.PKCS7);
        }
        catch (CryptographicException exception)
        {
            throw new WidevineL3ClientException("The Widevine content key could not be decrypted.", exception);
        }
    }

    private static byte[] EncryptEcb(ReadOnlySpan<byte> block, ReadOnlySpan<byte> key)
    {
        using Aes aes = Aes.Create();
        aes.Key = key.ToArray();
        aes.Mode = CipherMode.ECB;
        aes.Padding = PaddingMode.None;
        return aes.EncryptEcb(block, PaddingMode.None);
    }

    private static byte[] Double(ReadOnlySpan<byte> block)
    {
        byte[] output = new byte[block.Length];
        byte carry = 0;
        for (int index = block.Length - 1; index >= 0; index--)
        {
            byte value = block[index];
            output[index] = (byte)((value << 1) | carry);
            carry = (byte)((value & 0x80) == 0 ? 0 : 1);
        }
        if (carry != 0) output[^1] ^= 0x87;
        return output;
    }

    private static void Xor(Span<byte> value, ReadOnlySpan<byte> mask)
    {
        for (int index = 0; index < value.Length; index++) value[index] ^= mask[index];
    }
}

internal readonly record struct ByteString
{
    private readonly byte[] _bytes;
    public ByteString(ReadOnlySpan<byte> bytes) => _bytes = bytes.ToArray();
    public ReadOnlySpan<byte> Span => _bytes;
    public bool Equals(ByteString other) => _bytes is not null && other._bytes is not null && _bytes.AsSpan().SequenceEqual(other._bytes);
    public override int GetHashCode()
    {
        var hash = new HashCode();
        foreach (byte value in _bytes) hash.Add(value);
        return hash.ToHashCode();
    }
}

internal sealed class WidevineProtobufWriter
{
    private readonly MemoryStream _stream = new();
    public void AppendVarint(int field, ulong value)
    {
        AppendRawVarint(((ulong)field << 3) | 0);
        AppendRawVarint(value);
    }
    public void AppendBytes(int field, ReadOnlySpan<byte> value)
    {
        AppendRawVarint(((ulong)field << 3) | 2);
        AppendRawVarint((ulong)value.Length);
        _stream.Write(value);
    }
    public void AppendMessage(int field, ReadOnlySpan<byte> value) => AppendBytes(field, value);
    public byte[] ToArray() => _stream.ToArray();
    private void AppendRawVarint(ulong value)
    {
        while (value >= 0x80)
        {
            _stream.WriteByte((byte)((value & 0x7f) | 0x80));
            value >>= 7;
        }
        _stream.WriteByte((byte)value);
    }
}

internal readonly record struct WidevineProtobufField(int Number, byte WireType, ulong? Varint, byte[]? Bytes);

internal ref struct WidevineProtobufReader
{
    private readonly ReadOnlySpan<byte> _data;
    private int _cursor;
    public WidevineProtobufReader(ReadOnlySpan<byte> data)
    {
        if (data.Length > 16 * 1024 * 1024) throw new WidevineL3ClientException("The Widevine protobuf message is too large.");
        _data = data;
        _cursor = 0;
    }
    public bool TryRead(out WidevineProtobufField field)
    {
        if (_cursor == _data.Length) { field = default; return false; }
        ulong key = ReadVarint();
        int number = checked((int)(key >> 3));
        byte wire = (byte)(key & 7);
        if (number <= 0) throw new WidevineL3ClientException("The Widevine protobuf field is invalid.");
        switch (wire)
        {
            case 0:
                field = new(number, wire, ReadVarint(), null);
                return true;
            case 1:
                Skip(8);
                field = new(number, wire, null, null);
                return true;
            case 2:
                int length = checked((int)ReadVarint());
                if (length < 0 || _cursor > _data.Length - length) throw new WidevineL3ClientException("The Widevine protobuf field is truncated.");
                byte[] value = _data.Slice(_cursor, length).ToArray();
                _cursor += length;
                field = new(number, wire, null, value);
                return true;
            case 5:
                Skip(4);
                field = new(number, wire, null, null);
                return true;
            default:
                throw new WidevineL3ClientException("The Widevine protobuf wire type is unsupported.");
        }
    }
    private ulong ReadVarint()
    {
        ulong value = 0;
        for (int shift = 0; shift <= 63; shift += 7)
        {
            if (_cursor >= _data.Length) throw new WidevineL3ClientException("The Widevine protobuf varint is truncated.");
            byte current = _data[_cursor++];
            if (shift == 63 && current > 1) throw new WidevineL3ClientException("The Widevine protobuf varint overflows.");
            value |= (ulong)(current & 0x7f) << shift;
            if ((current & 0x80) == 0) return value;
        }
        throw new WidevineL3ClientException("The Widevine protobuf varint is invalid.");
    }
    private void Skip(int count)
    {
        if (count < 0 || _cursor > _data.Length - count) throw new WidevineL3ClientException("The Widevine protobuf field is truncated.");
        _cursor += count;
    }
}

internal sealed class WidevineSignedMessage : IDisposable
{
    public ulong? Type { get; private set; }
    public byte[]? Message { get; private set; }
    public byte[]? Signature { get; private set; }
    public byte[]? SessionKey { get; private set; }
    public ulong? SessionKeyType { get; private set; }
    public byte[]? RemoteAttestation { get; private set; }
    public byte[]? OemcryptoCoreMessage { get; private set; }

    public static WidevineSignedMessage Parse(ReadOnlySpan<byte> data)
    {
        var result = new WidevineSignedMessage();
        var reader = new WidevineProtobufReader(data);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            switch (field.Number)
            {
                case 1 when field.WireType == 0 && result.Type is null: result.Type = field.Varint; break;
                case 2 when field.WireType == 2 && result.Message is null: result.Message = field.Bytes; break;
                case 3 when field.WireType == 2 && result.Signature is null: result.Signature = field.Bytes; break;
                case 4 when field.WireType == 2 && result.SessionKey is null: result.SessionKey = field.Bytes; break;
                case 5 when field.WireType == 2 && result.RemoteAttestation is null: result.RemoteAttestation = field.Bytes; break;
                case 8 when field.WireType == 0 && result.SessionKeyType is null: result.SessionKeyType = field.Varint; break;
                case 9 when field.WireType == 2 && result.OemcryptoCoreMessage is null: result.OemcryptoCoreMessage = field.Bytes; break;
                case 1 or 2 or 3 or 4 or 5 or 8 or 9: result.Dispose(); throw new WidevineL3ClientException("The Widevine signed message is malformed.");
            }
        }
        return result;
    }

    public void Dispose()
    {
        Zero(Message); Zero(Signature); Zero(SessionKey); Zero(RemoteAttestation); Zero(OemcryptoCoreMessage);
        Message = null;
        Signature = null;
        SessionKey = null;
        RemoteAttestation = null;
        OemcryptoCoreMessage = null;
    }
    private static void Zero(byte[]? value) { if (value is not null) CryptographicOperations.ZeroMemory(value); }
}

internal sealed record WidevineEncryptedKey(byte[]? Id, byte[]? Iv, byte[]? Key, ulong Type, ulong SecurityLevel, bool HasUnsupportedConstraint);
internal sealed record WidevineLicenseIdentification(byte[]? RequestId, ulong LicenseType);
internal sealed record WidevineLicensePolicy(bool CanPlay, bool CanPersist, bool CanRenew, ulong? RentalDurationSeconds, ulong? PlaybackDurationSeconds, ulong? LicenseDurationSeconds, bool HasUnsupportedConstraint);

internal sealed record WidevineLicenseMessage(
    IReadOnlyList<WidevineEncryptedKey> Keys,
    WidevineLicenseIdentification? Identification,
    WidevineLicensePolicy? Policy,
    ulong? LicenseStartTime,
    bool HasUnsupportedConstraint) : IDisposable
{
    public static WidevineLicenseMessage Parse(ReadOnlySpan<byte> data)
    {
        var keys = new List<WidevineEncryptedKey>();
        WidevineLicenseIdentification? identification = null;
        WidevineLicensePolicy? policy = null;
        ulong? startTime = null;
        bool unsupported = false;
        var reader = new WidevineProtobufReader(data);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            switch (field.Number)
            {
                case 1 when field.WireType == 2 && identification is null && field.Bytes is not null:
                    identification = ParseIdentification(field.Bytes); break;
                case 2 when field.WireType == 2 && policy is null && field.Bytes is not null:
                    policy = ParsePolicy(field.Bytes); break;
                case 3 when field.WireType == 2 && field.Bytes is not null:
                    keys.Add(ParseKey(field.Bytes)); break;
                case 4 when field.WireType == 0 && startTime is null:
                    startTime = field.Varint; break;
                case 6 when field.WireType == 2: break;
                case 7 when field.WireType == 0: break;
                case 11 when field.WireType == 2: break;
                case 5 or 8 or 9 or 10: unsupported = true; break;
                default: unsupported = true; break;
            }
        }
        return new(keys, identification, policy, startTime, unsupported);
    }

    private static WidevineEncryptedKey ParseKey(ReadOnlySpan<byte> data)
    {
        byte[]? id = null, iv = null, key = null;
        ulong type = 1, securityLevel = 1;
        bool sawType = false, sawLevel = false, unsupported = false;
        var reader = new WidevineProtobufReader(data);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            switch (field.Number)
            {
                case 1 when field.WireType == 2 && id is null: id = field.Bytes; break;
                case 2 when field.WireType == 2 && iv is null: iv = field.Bytes; break;
                case 3 when field.WireType == 2 && key is null: key = field.Bytes; break;
                case 4 when field.WireType == 0 && !sawType: type = field.Varint!.Value; sawType = true; break;
                case 5 when field.WireType == 0 && !sawLevel: securityLevel = field.Varint!.Value; sawLevel = true; break;
                case >= 6 and <= 11: unsupported = true; break;
                case 12 when field.WireType == 2: break;
                default: throw new WidevineL3ClientException("The Widevine content key container is malformed.");
            }
        }
        return new(id, iv, key, type, securityLevel, unsupported);
    }

    private static WidevineLicenseIdentification ParseIdentification(ReadOnlySpan<byte> data)
    {
        byte[]? requestId = null;
        ulong licenseType = 1;
        bool sawType = false;
        var reader = new WidevineProtobufReader(data);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            switch (field.Number)
            {
                case 1 when field.WireType == 2 && requestId is null: requestId = field.Bytes; break;
                case 4 when field.WireType == 0 && !sawType: licenseType = field.Varint!.Value; sawType = true; break;
            }
        }
        return new(requestId, licenseType);
    }

    private static WidevineLicensePolicy ParsePolicy(ReadOnlySpan<byte> data)
    {
        bool? canPlay = null, canPersist = null, canRenew = null;
        ulong? rental = null, playback = null, duration = null;
        bool unsupported = false;
        var reader = new WidevineProtobufReader(data);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            switch (field.Number)
            {
                case 1 when field.WireType == 0 && canPlay is null && field.Varint <= 1: canPlay = field.Varint == 1; break;
                case 2 when field.WireType == 0 && canPersist is null && field.Varint <= 1: canPersist = field.Varint == 1; break;
                case 3 when field.WireType == 0 && canRenew is null && field.Varint <= 1: canRenew = field.Varint == 1; break;
                case 4 when field.WireType == 0 && rental is null: rental = field.Varint; break;
                case 5 when field.WireType == 0 && playback is null: playback = field.Varint; break;
                case 6 when field.WireType == 0 && duration is null: duration = field.Varint; break;
                case >= 7 and <= 15: unsupported = true; break;
                default: throw new WidevineL3ClientException("The Widevine license policy is malformed.");
            }
        }
        return new(canPlay ?? false, canPersist ?? false, canRenew ?? false, rental, playback, duration, unsupported);
    }

    public void Dispose()
    {
        foreach (WidevineEncryptedKey key in Keys)
        {
            if (key.Id is not null) CryptographicOperations.ZeroMemory(key.Id);
            if (key.Iv is not null) CryptographicOperations.ZeroMemory(key.Iv);
            if (key.Key is not null) CryptographicOperations.ZeroMemory(key.Key);
        }
        if (Identification?.RequestId is not null) CryptographicOperations.ZeroMemory(Identification.RequestId);
    }
}

internal static class WidevinePssh
{
    private static ReadOnlySpan<byte> SystemId => [
        0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce,
        0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed];

    public static byte[] Payload(ReadOnlySpan<byte> input, int maximumBytes)
    {
        if (input.Length is <= 0 || input.Length > maximumBytes)
            throw new WidevineL3ClientException("The Widevine PSSH is invalid.");
        if (input.Length < 8 || !input.Slice(4, 4).SequenceEqual("pssh"u8)) return input.ToArray();
        int cursor = 0;
        uint size32 = ReadUInt32(input, ref cursor);
        if (!input.Slice(cursor, 4).SequenceEqual("pssh"u8)) throw new WidevineL3ClientException("The Widevine PSSH is invalid.");
        cursor += 4;
        ulong boxSize = size32 switch
        {
            0 => (ulong)input.Length,
            1 => ReadUInt64(input, ref cursor),
            _ => size32
        };
        if (boxSize != (ulong)input.Length || input.Length - cursor < 20)
            throw new WidevineL3ClientException("The Widevine PSSH box size is invalid.");
        byte version = input[cursor];
        if (version is not 0 and not 1 || input[cursor + 1] != 0 || input[cursor + 2] != 0 || input[cursor + 3] != 0)
            throw new WidevineL3ClientException("The Widevine PSSH version or flags are invalid.");
        cursor += 4;
        if (!input.Slice(cursor, 16).SequenceEqual(SystemId)) throw new WidevineL3ClientException("The PSSH is not Widevine.");
        cursor += 16;
        var outerKeyIds = new HashSet<ByteString>();
        if (version == 1)
        {
            uint count = ReadUInt32(input, ref cursor);
            if (count > 100_000 || (ulong)(input.Length - cursor) < (ulong)count * 16)
                throw new WidevineL3ClientException("The Widevine PSSH key list is invalid.");
            for (int index = 0; index < count; index++)
            {
                var id = new ByteString(input.Slice(cursor, 16));
                if (!outerKeyIds.Add(id)) throw new WidevineL3ClientException("The Widevine PSSH contains a duplicate key ID.");
                cursor += 16;
            }
        }
        uint dataLength = ReadUInt32(input, ref cursor);
        if (dataLength != input.Length - cursor) throw new WidevineL3ClientException("The Widevine PSSH payload length is invalid.");
        if (dataLength == 0)
        {
            if (outerKeyIds.Count == 0) throw new WidevineL3ClientException("The Widevine PSSH has no payload.");
            var writer = new WidevineProtobufWriter();
            foreach (ByteString id in outerKeyIds) writer.AppendBytes(2, id.Span);
            return writer.ToArray();
        }
        byte[] payload = input[cursor..].ToArray();
        IReadOnlyCollection<ByteString>? payloadIds = KeyIdsFromPayload(payload);
        if (payloadIds is not null && outerKeyIds.Count > 0 && !outerKeyIds.SetEquals(payloadIds))
        {
            CryptographicOperations.ZeroMemory(payload);
            throw new WidevineL3ClientException("The Widevine PSSH key IDs disagree.");
        }
        return payload;
    }

    public static IReadOnlyCollection<ByteString>? KeyIdsFromPayload(ReadOnlySpan<byte> payload)
    {
        var ids = new HashSet<ByteString>();
        var reader = new WidevineProtobufReader(payload);
        while (reader.TryRead(out WidevineProtobufField field))
        {
            if (field.Number != 2) continue;
            if (field.WireType != 2 || field.Bytes is not { Length: 16 })
                throw new WidevineL3ClientException("The Widevine PSSH key ID is invalid.");
            var id = new ByteString(field.Bytes);
            if (!ids.Add(id)) throw new WidevineL3ClientException("The Widevine PSSH contains a duplicate key ID.");
        }
        return ids.Count == 0 ? null : ids;
    }

    private static uint ReadUInt32(ReadOnlySpan<byte> input, ref int cursor)
    {
        if (cursor > input.Length - 4) throw new WidevineL3ClientException("The Widevine PSSH is truncated.");
        uint value = BinaryPrimitives.ReadUInt32BigEndian(input[cursor..]);
        cursor += 4;
        return value;
    }
    private static ulong ReadUInt64(ReadOnlySpan<byte> input, ref int cursor)
    {
        if (cursor > input.Length - 8) throw new WidevineL3ClientException("The Widevine PSSH is truncated.");
        ulong value = BinaryPrimitives.ReadUInt64BigEndian(input[cursor..]);
        cursor += 8;
        return value;
    }
}
