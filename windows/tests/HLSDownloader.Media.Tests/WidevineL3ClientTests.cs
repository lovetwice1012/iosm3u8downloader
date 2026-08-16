using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace HLSDownloader.Media.Tests;

public sealed class WidevineL3ClientTests
{
    private const long Now = 1_700_000_000;

    [Fact]
    public void AesCmacAndWidevineKdfMatchReferenceVectors()
    {
        byte[] key = Convert.FromHexString("2b7e151628aed2a6abf7158809cf4f3c");
        Assert.Equal("BB1D6929E95937287FA37D129B756746", Convert.ToHexString(WidevineL3Crypto.AesCmac([], key)));
        Assert.Equal(
            "070A16B46B4D4144F79BDD9DD04A287C",
            Convert.ToHexString(WidevineL3Crypto.AesCmac(
                Convert.FromHexString("6bc1bee22e409f96e93d7e117393172a"), key)));

        byte[] sessionKey = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        byte[] request = Convert.FromHexString("deadbeef01020304");
        Assert.Equal(
            "EF9BB4C7C0C07386F436CC99019967BC",
            Convert.ToHexString(WidevineL3Crypto.DeriveEncryptionKey(request, sessionKey)));
        Assert.Equal(
            "A1F068BBDA60891C99E9B45C0910C22134A04C31CA4129A1E2D09FF5779A84B8",
            Convert.ToHexString(WidevineL3Crypto.DeriveAuthenticationKey(request, sessionKey)));
    }

    [Fact]
    public void AndroidCredentialCreatesUppercaseHexRequestIdAndRedactsText()
    {
        using RSA rsa = RSA.Create(2048);
        byte[] wvd = MakeWvd(2, rsa.ExportRSAPrivateKey(), MakeClientIdentification(rsa.ExportRSAPublicKey()));
        using var client = new WidevineL3Client(
            wvd,
            () => Now,
            count => Enumerable.Repeat((byte)0xab, count).ToArray());
        using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(MakePsshPayload(Enumerable.Repeat((byte)0x11, 16).ToArray()));

        var signed = WidevineSignedMessage.Parse(challenge.RequestData.Span);
        using (signed)
        {
            Assert.Equal((ulong)1, signed.Type);
            Assert.NotNull(signed.Message);
            var requestReader = new WidevineProtobufReader(signed.Message);
            byte[]? requestId = null;
            while (requestReader.TryRead(out WidevineProtobufField field))
            {
                if (field.Number != 2 || field.Bytes is null) continue;
                var contentReader = new WidevineProtobufReader(field.Bytes);
                while (contentReader.TryRead(out WidevineProtobufField contentField))
                {
                    if (contentField.Number != 1 || contentField.Bytes is null) continue;
                    var psshReader = new WidevineProtobufReader(contentField.Bytes);
                    while (psshReader.TryRead(out WidevineProtobufField psshField))
                        if (psshField.Number == 3) requestId = psshField.Bytes;
                }
            }
            Assert.Equal("ABABABAB000000000100000000000000", Encoding.ASCII.GetString(Assert.IsType<byte[]>(requestId)));
        }

        Assert.Equal("WidevineLicenseChallenge(<redacted>)", challenge.ToString());
        Assert.DoesNotContain(Convert.ToBase64String(challenge.RequestData.Span), challenge.ToString(), StringComparison.Ordinal);
    }

    [Fact]
    public void AuthenticatedOfflineLicenseValidatesSigningKeyAndReturnsOnlyContentKey()
    {
        using RSA rsa = RSA.Create(2048);
        byte[] wvd = MakeWvd(1, rsa.ExportRSAPrivateKey(), MakeClientIdentification(rsa.ExportRSAPublicKey()));
        using var client = new WidevineL3Client(
            wvd,
            () => Now,
            count => Enumerable.Repeat((byte)count, count).ToArray());
        byte[] keyId = Enumerable.Range(0, 16).Select(value => (byte)value).ToArray();
        byte[] contentKey = Enumerable.Repeat((byte)0xc7, 16).ToArray();
        using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(MakePsshPayload(keyId));
        byte[] response = MakeLicenseResponse(rsa, challenge, keyId, contentKey);

        IReadOnlyList<WidevineContentKey> keys = client.ParseLicense(response, challenge);
        try
        {
            WidevineContentKey key = Assert.Single(keys);
            Assert.Equal(keyId, key.Id);
            Assert.Equal(contentKey, key.CopyValue());
            Assert.Equal(WidevineContentKeyType.Content, key.Type);
            Assert.Equal("WidevineContentKey(<redacted>)", key.ToString());
        }
        finally
        {
            foreach (WidevineContentKey key in keys) key.Dispose();
        }
    }

    [Theory]
    [InlineData(0)]
    [InlineData(2)]
    public void OfflineLicenseRequiresExactlyOneSigningKey(int signingKeyCount)
    {
        using RSA rsa = RSA.Create(2048);
        byte[] wvd = MakeWvd(1, rsa.ExportRSAPrivateKey(), MakeClientIdentification(rsa.ExportRSAPublicKey()));
        using var client = new WidevineL3Client(wvd, () => Now, RandomNumberGenerator.GetBytes);
        byte[] keyId = Enumerable.Repeat((byte)0x71, 16).ToArray();
        using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(MakePsshPayload(keyId));
        byte[] response = MakeLicenseResponse(
            rsa,
            challenge,
            keyId,
            Enumerable.Repeat((byte)0x72, 16).ToArray(),
            signingKeyCount: signingKeyCount);

        Assert.Throws<WidevineL3ClientException>(() => client.ParseLicense(response, challenge));
    }

    [Theory]
    [InlineData(2, false)]
    [InlineData(1, true)]
    public void OfflineLicenseRejectsSigningKeyWithInvalidLevelOrConstraint(
        ulong signingSecurityLevel,
        bool signingHasConstraint)
    {
        using RSA rsa = RSA.Create(2048);
        byte[] wvd = MakeWvd(1, rsa.ExportRSAPrivateKey(), MakeClientIdentification(rsa.ExportRSAPublicKey()));
        using var client = new WidevineL3Client(wvd, () => Now, RandomNumberGenerator.GetBytes);
        byte[] keyId = Enumerable.Repeat((byte)0x81, 16).ToArray();
        using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(MakePsshPayload(keyId));
        byte[] response = MakeLicenseResponse(
            rsa,
            challenge,
            keyId,
            Enumerable.Repeat((byte)0x82, 16).ToArray(),
            signingSecurityLevel: signingSecurityLevel,
            signingHasConstraint: signingHasConstraint);

        Assert.Throws<WidevineL3ClientException>(() => client.ParseLicense(response, challenge));
    }

    [Fact]
    public void TamperedOrNonPersistentLicenseIsRejected()
    {
        using RSA rsa = RSA.Create(2048);
        byte[] wvd = MakeWvd(1, rsa.ExportRSAPrivateKey(), MakeClientIdentification(rsa.ExportRSAPublicKey()));
        using var client = new WidevineL3Client(wvd, () => Now, RandomNumberGenerator.GetBytes);
        byte[] keyId = Enumerable.Repeat((byte)0x51, 16).ToArray();
        using WidevineLicenseChallenge challenge = client.MakeLicenseChallenge(MakePsshPayload(keyId));
        byte[] denied = MakeLicenseResponse(rsa, challenge, keyId, Enumerable.Repeat((byte)0x61, 16).ToArray(), canPersist: false);
        Assert.Throws<WidevineL3ClientException>(() => client.ParseLicense(denied, challenge));

        byte[] valid = MakeLicenseResponse(rsa, challenge, keyId, Enumerable.Repeat((byte)0x62, 16).ToArray());
        valid[^1] ^= 1;
        Assert.Throws<WidevineL3ClientException>(() => client.ParseLicense(valid, challenge));
    }

    [Fact]
    public void CredentialCertificateMustMatchPrivateKey()
    {
        using RSA first = RSA.Create(2048);
        using RSA second = RSA.Create(2048);
        byte[] wvd = MakeWvd(1, first.ExportRSAPrivateKey(), MakeClientIdentification(second.ExportRSAPublicKey()));
        Assert.Throws<WidevineL3ClientException>(() => new WidevineL3Client(wvd));
    }

    private static byte[] MakeLicenseResponse(
        RSA rsa,
        WidevineLicenseChallenge challenge,
        byte[] keyId,
        byte[] contentKey,
        bool canPersist = true,
        int signingKeyCount = 1,
        ulong signingSecurityLevel = 1,
        bool signingHasConstraint = false)
    {
        byte[] sessionKey = Enumerable.Repeat((byte)0xa1, 16).ToArray();
        byte[] encryptionKey = WidevineL3Crypto.DeriveEncryptionKey(challenge.LicenseRequestData.Span, sessionKey);

        var policy = new WidevineProtobufWriter();
        policy.AppendVarint(1, 1);
        policy.AppendVarint(2, canPersist ? 1UL : 0UL);
        policy.AppendVarint(6, 0);

        var identification = new WidevineProtobufWriter();
        identification.AppendBytes(1, challenge.RequestId.Span);
        identification.AppendVarint(4, (ulong)WidevineLicenseType.Offline);

        var license = new WidevineProtobufWriter();
        license.AppendMessage(1, identification.ToArray());
        license.AppendMessage(2, policy.ToArray());
        for (int index = 0; index < signingKeyCount; index++)
        {
            license.AppendMessage(
                3,
                MakeEncryptedKeyContainer(
                    null,
                    Enumerable.Repeat((byte)(0xd0 + index), 16).ToArray(),
                    encryptionKey,
                    WidevineContentKeyType.Signing,
                    signingSecurityLevel,
                    signingHasConstraint,
                    (byte)(0xc0 + index)));
        }
        license.AppendMessage(
            3,
            MakeEncryptedKeyContainer(
                keyId,
                contentKey,
                encryptionKey,
                WidevineContentKeyType.Content,
                securityLevel: 1,
                hasUnsupportedConstraint: false,
                ivValue: 0xb2));
        license.AppendVarint(4, (ulong)Now);
        byte[] licenseBytes = license.ToArray();

        byte[] authenticationKey = WidevineL3Crypto.DeriveAuthenticationKey(challenge.LicenseRequestData.Span, sessionKey);
        byte[] core = [0x10, 0x20, 0x30];
        byte[] authenticated = new byte[core.Length + licenseBytes.Length];
        core.CopyTo(authenticated, 0);
        licenseBytes.CopyTo(authenticated, core.Length);
        byte[] hmac = HMACSHA256.HashData(authenticationKey, authenticated);
        byte[] wrappedSession = rsa.Encrypt(sessionKey, RSAEncryptionPadding.OaepSHA1);

        var response = new WidevineProtobufWriter();
        response.AppendVarint(1, 2);
        response.AppendBytes(2, licenseBytes);
        response.AppendBytes(3, hmac);
        response.AppendBytes(4, wrappedSession);
        response.AppendVarint(8, 1);
        response.AppendBytes(9, core);
        return response.ToArray();
    }

    private static byte[] MakeEncryptedKeyContainer(
        byte[]? keyId,
        byte[] clearKey,
        byte[] encryptionKey,
        WidevineContentKeyType keyType,
        ulong securityLevel,
        bool hasUnsupportedConstraint,
        byte ivValue)
    {
        byte[] iv = Enumerable.Repeat(ivValue, 16).ToArray();
        byte[] encryptedKey;
        using (Aes aes = Aes.Create())
        {
            aes.Key = encryptionKey;
            encryptedKey = aes.EncryptCbc(clearKey, iv, PaddingMode.PKCS7);
        }

        var keyContainer = new WidevineProtobufWriter();
        if (keyId is not null)
        {
            keyContainer.AppendBytes(1, keyId);
        }
        keyContainer.AppendBytes(2, iv);
        keyContainer.AppendBytes(3, encryptedKey);
        keyContainer.AppendVarint(4, (ulong)keyType);
        keyContainer.AppendVarint(5, securityLevel);
        if (hasUnsupportedConstraint)
        {
            keyContainer.AppendMessage(6, [0x08, 0x01]);
        }
        return keyContainer.ToArray();
    }

    private static byte[] MakePsshPayload(byte[] keyId)
    {
        var writer = new WidevineProtobufWriter();
        writer.AppendBytes(2, keyId);
        return writer.ToArray();
    }

    private static byte[] MakeClientIdentification(byte[] publicKey)
    {
        var certificate = new WidevineProtobufWriter();
        certificate.AppendBytes(4, publicKey);
        var signedCertificate = new WidevineProtobufWriter();
        signedCertificate.AppendMessage(1, certificate.ToArray());
        var client = new WidevineProtobufWriter();
        client.AppendVarint(1, 1);
        client.AppendMessage(2, signedCertificate.ToArray());
        return client.ToArray();
    }

    private static byte[] MakeWvd(byte deviceType, byte[] privateKey, byte[] clientIdentification)
    {
        using var stream = new MemoryStream();
        stream.Write([0x57, 0x56, 0x44, 0x02, deviceType, 0x03, 0x00]);
        Span<byte> length = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)privateKey.Length));
        stream.Write(length);
        stream.Write(privateKey);
        BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)clientIdentification.Length));
        stream.Write(length);
        stream.Write(clientIdentification);
        return stream.ToArray();
    }
}
