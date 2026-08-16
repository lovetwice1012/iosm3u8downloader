using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using HLSDownloader.Core;

namespace HLSDownloader.Media.Tests;

public sealed class WidevineL3MediaProviderTests
{
    private const long Now = 1_700_000_000;

    [Fact]
    public void DownloadRequestTextDoesNotExposeUrisOrOutputPath()
    {
        var request = new WidevineL3DownloadRequest(
            new Uri("https://widevine.sprink.cloud/private/manifest.mpd?token=manifest-secret"),
            new Uri("https://widevine.sprink.cloud/private/effective.mpd?token=effective-secret"),
            Path.Combine("private", "output-secret"),
            _ => true,
            new Uri("https://widevine.sprink.cloud/private/license?session=license-secret"));

        Assert.Equal("WidevineL3DownloadRequest(<redacted>)", request.ToString());
        Assert.DoesNotContain("secret", $"{request}", StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("/private/", string.Concat(request), StringComparison.Ordinal);
        var debuggerDisplay = Assert.IsType<System.Diagnostics.DebuggerDisplayAttribute>(Assert.Single(
            typeof(WidevineL3DownloadRequest).GetCustomAttributes(
                typeof(System.Diagnostics.DebuggerDisplayAttribute),
                inherit: false)));
        Assert.Equal("WidevineL3DownloadRequest(<redacted>)", debuggerDisplay.Value);
    }

    [Fact]
    public async Task RawOfflineLicenseDownloadsValidatesDecryptsAndPublishesMp4()
    {
        string root = Path.Combine(Path.GetTempPath(), "HLSDownloader-WidevineProviderTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            using RSA rsa = RSA.Create(2048);
            byte[] keyId = Enumerable.Repeat((byte)0x21, 16).ToArray();
            byte[] contentKey = Enumerable.Repeat((byte)0x31, 16).ToArray();
            byte[] wvd = MakeWvd(rsa);
            Uri manifestUri = new("https://widevine.sprink.cloud/video/manifest.mpd");
            byte[] manifest = Encoding.UTF8.GetBytes(MakeManifest(keyId));
            var manifestDownloader = new FixtureDownloader((uri, _, _, _) =>
                new HttpResource(manifest, uri, uri, HttpStatusCode.OK, "application/dash+xml"));
            byte[] initialization = MakeEncryptedInitialization(keyId, WidevineDashMediaType.Video);
            byte[] fragment = MakeEncryptedFragment();
            var segmentDownloader = new FixtureDownloader((uri, _, _, _) =>
            {
                byte[] data = uri.AbsolutePath.EndsWith("init.mp4", StringComparison.Ordinal) ? initialization : fragment;
                return new HttpResource(data, uri, uri, HttpStatusCode.OK, "video/mp4");
            });
            var license = new FixtureLicenseTransport(rsa, keyId, contentKey);
            string ffmpeg = Path.Combine(root, "ffmpeg.exe");
            await File.WriteAllBytesAsync(ffmpeg, [0]);
            var runner = new FixtureToolRunner();
            var provider = new WidevineL3MediaProvider(
                manifestDownloader,
                segmentDownloader,
                new FixtureCredentialSource(wvd),
                license,
                ffmpeg,
                new FixtureTrackProbe(),
                runner,
                new WidevineL3MediaOptions(TemporaryRoot: Path.Combine(root, "jobs")));

            Assert.True(provider.IsConfigured);
            MediaComposeResult result = await provider.DownloadAndComposeAsync(new WidevineL3DownloadRequest(
                manifestUri,
                manifestUri,
                Path.Combine(root, "result"),
                WidevineDownloadPolicy.IsDownloadableWidevineDomain));

            Assert.Equal(MediaOutputFormat.Mp4, result.OutputFormat);
            Assert.True(File.Exists(result.OutputPath));
            Assert.True(MediaOutputValidator.IsValidMp4(result.OutputPath));
            Assert.Equal(1, license.CallCount);
            ExternalToolInvocation invocation = Assert.Single(runner.Invocations);
            string keyHex = Convert.ToHexString(contentKey).ToLowerInvariant();
            Assert.Contains(keyHex, invocation.Arguments);
            Assert.Contains(keyHex, invocation.RedactedValues!);
            Assert.DoesNotContain(keyHex, invocation.ToString(), StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealFfmpegCencFixtureIsDecryptedAndExportedWithoutLoggingKey()
    {
        string root = Path.Combine(Path.GetTempPath(), "HLSDownloader-WidevineRealTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var locator = new FFmpegToolLocator();
            var logs = new List<string>();
            var runner = new ExternalToolRunner(logs.Add);
            string ffmpeg = locator.ResolveFFmpeg();
            byte[] keyId = Convert.FromHexString("102132435465768798a9bacbdcedfe0f");
            byte[] contentKey = Convert.FromHexString("00112233445566778899aabbccddeeff");
            string keyHex = Convert.ToHexString(contentKey).ToLowerInvariant();
            string kidHex = Convert.ToHexString(keyId).ToLowerInvariant();
            string encryptedPath = Path.Combine(root, "encrypted.mp4");
            ExternalToolResult fixture = await runner.RunAsync(new ExternalToolInvocation(
                ffmpeg,
                [
                    "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "testsrc=size=64x64:rate=5",
                    "-t", "1", "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "1",
                    "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                    "-encryption_scheme", "cenc-aes-ctr", "-encryption_key", keyHex,
                    "-encryption_kid", kidHex, encryptedPath
                ],
                TimeSpan.FromSeconds(30),
                [keyHex]));
            Assert.True(fixture.ExitCode == 0, fixture.StandardError);
            (byte[] initialization, byte[] fragments) = SplitFmp4(await File.ReadAllBytesAsync(encryptedPath));

            using RSA rsa = RSA.Create(2048);
            byte[] manifest = Encoding.UTF8.GetBytes(MakeManifest(keyId));
            var manifestDownloader = new FixtureDownloader((uri, _, _, _) =>
                new HttpResource(manifest, uri, uri, HttpStatusCode.OK, "application/dash+xml"));
            var segmentDownloader = new FixtureDownloader((uri, _, _, _) =>
            {
                byte[] data = uri.AbsolutePath.EndsWith("init.mp4", StringComparison.Ordinal) ? initialization : fragments;
                return new HttpResource(data, uri, uri, HttpStatusCode.OK, "video/mp4");
            });
            var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
            var provider = new WidevineL3MediaProvider(
                manifestDownloader,
                segmentDownloader,
                new FixtureCredentialSource(MakeWvd(rsa)),
                new FixtureLicenseTransport(rsa, keyId, contentKey),
                ffmpeg,
                probe,
                runner,
                new WidevineL3MediaOptions(TemporaryRoot: Path.Combine(root, "jobs"), ComposeTimeout: TimeSpan.FromSeconds(30)));
            Uri manifestUri = new("https://widevine.sprink.cloud/video/manifest.mpd");
            MediaComposeResult output = await provider.DownloadAndComposeAsync(new WidevineL3DownloadRequest(
                manifestUri,
                manifestUri,
                Path.Combine(root, "real-result"),
                WidevineDownloadPolicy.IsDownloadableWidevineDomain));

            Assert.True(MediaOutputValidator.IsValidMp4(output.OutputPath));
            Assert.True(output.Tracks.HasVideo);
            Assert.DoesNotContain(logs, line => line.Contains(keyHex, StringComparison.OrdinalIgnoreCase));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    [Trait("Category", "Integration")]
    public async Task RealAudioOnlyCencFixtureIsExportedAsPcm16Wav()
    {
        string root = Path.Combine(Path.GetTempPath(), "HLSDownloader-WidevineAudioTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            var locator = new FFmpegToolLocator();
            var runner = new ExternalToolRunner();
            string ffmpeg = locator.ResolveFFmpeg();
            byte[] keyId = Convert.FromHexString("202132435465768798a9bacbdcedfe0f");
            byte[] contentKey = Convert.FromHexString("10112233445566778899aabbccddeeff");
            string keyHex = Convert.ToHexString(contentKey).ToLowerInvariant();
            string kidHex = Convert.ToHexString(keyId).ToLowerInvariant();
            string encryptedPath = Path.Combine(root, "encrypted-audio.mp4");
            ExternalToolResult fixture = await runner.RunAsync(new ExternalToolInvocation(
                ffmpeg,
                [
                    "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "sine=frequency=880:sample_rate=48000",
                    "-t", "0.6", "-vn", "-c:a", "aac",
                    "-movflags", "+frag_keyframe+empty_moov+default_base_moof",
                    "-encryption_scheme", "cenc-aes-ctr", "-encryption_key", keyHex,
                    "-encryption_kid", kidHex, encryptedPath
                ],
                TimeSpan.FromSeconds(30),
                [keyHex]));
            Assert.True(fixture.ExitCode == 0, fixture.StandardError);
            (byte[] initialization, byte[] fragments) = SplitFmp4(await File.ReadAllBytesAsync(encryptedPath));
            using RSA rsa = RSA.Create(2048);
            byte[] manifest = Encoding.UTF8.GetBytes(MakeAudioManifest(keyId));
            var manifestDownloader = new FixtureDownloader((uri, _, _, _) => new HttpResource(manifest, uri, uri, HttpStatusCode.OK, "application/dash+xml"));
            var segmentDownloader = new FixtureDownloader((uri, _, _, _) => new HttpResource(
                uri.AbsolutePath.EndsWith("init.mp4", StringComparison.Ordinal) ? initialization : fragments,
                uri, uri, HttpStatusCode.OK, "audio/mp4"));
            var probe = new FFprobeMediaTrackProbe(locator.ResolveFFprobe(), runner);
            var provider = new WidevineL3MediaProvider(
                manifestDownloader, segmentDownloader, new FixtureCredentialSource(MakeWvd(rsa)),
                new FixtureLicenseTransport(rsa, keyId, contentKey), ffmpeg, probe, runner,
                new WidevineL3MediaOptions(TemporaryRoot: Path.Combine(root, "jobs"), ComposeTimeout: TimeSpan.FromSeconds(30)));
            Uri manifestUri = new("https://widevine.sprink.cloud/audio/manifest.mpd");
            MediaComposeResult output = await provider.DownloadAndComposeAsync(new WidevineL3DownloadRequest(
                manifestUri, manifestUri, Path.Combine(root, "audio-result"), WidevineDownloadPolicy.IsDownloadableWidevineDomain));

            Assert.Equal(MediaOutputFormat.Wav, output.OutputFormat);
            Assert.True(MediaOutputValidator.IsValidPcm16Wav(output.OutputPath));
            Assert.False(output.Tracks.HasVideo);
            Assert.True(output.Tracks.HasAudio);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void Fmp4ValidatorRejectsWrongEmbeddedKidAndSampleGroupOverride()
    {
        string root = Path.Combine(Path.GetTempPath(), "HLSDownloader-WidevineValidatorTests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            byte[] expected = Enumerable.Repeat((byte)0x41, 16).ToArray();
            var track = new WidevineDashTrackPlan(
                WidevineDashMediaType.Audio,
                "audio",
                1,
                expected,
                WidevineCommonEncryptionScheme.Cenc,
                [MakePssh(expected)],
                [new Uri("https://widevine.sprink.cloud/license")],
                new(new Uri("https://widevine.sprink.cloud/init.mp4"), new Uri("https://widevine.sprink.cloud/manifest.mpd")),
                [new(new Uri("https://widevine.sprink.cloud/one.m4s"), new Uri("https://widevine.sprink.cloud/manifest.mpd"))]);
            string wrong = Path.Combine(root, "wrong.mp4");
            File.WriteAllBytes(wrong, MakeEncryptedInitialization(Enumerable.Repeat((byte)0x42, 16).ToArray(), WidevineDashMediaType.Audio)
                .Concat(MakeEncryptedFragment()).ToArray());
            Assert.Throws<InvalidDataException>(() => WidevineFmp4EncryptionValidator.Validate(track, wrong));

            string rotation = Path.Combine(root, "rotation.mp4");
            File.WriteAllBytes(rotation, MakeEncryptedInitialization(expected, WidevineDashMediaType.Audio)
                .Concat(MakeEncryptedFragment(includeSampleGroup: true)).ToArray());
            Assert.Throws<InvalidDataException>(() => WidevineFmp4EncryptionValidator.Validate(track, rotation));
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }

    private static string MakeManifest(byte[] keyId)
    {
        string uuid = Convert.ToHexString(keyId).ToLowerInvariant();
        uuid = $"{uuid[..8]}-{uuid[8..12]}-{uuid[12..16]}-{uuid[16..20]}-{uuid[20..]}";
        return $"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT2S">
              <Period><AdaptationSet contentType="video" mimeType="video/mp4">
                <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="{uuid}"/>
                <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
                  <cenc:pssh>{Convert.ToBase64String(MakePssh(keyId))}</cenc:pssh>
                  <Laurl licenseUrl="https://widevine.sprink.cloud/license"/>
                </ContentProtection>
                <Representation id="video" bandwidth="1000" width="1280" height="720">
                  <SegmentTemplate initialization="init.mp4" media="$Number$.m4s" duration="2" startNumber="1"/>
                </Representation>
              </AdaptationSet></Period>
            </MPD>
            """;
    }

    private static string MakeAudioManifest(byte[] keyId)
    {
        string uuid = Convert.ToHexString(keyId).ToLowerInvariant();
        uuid = $"{uuid[..8]}-{uuid[8..12]}-{uuid[12..16]}-{uuid[16..20]}-{uuid[20..]}";
        return $"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT1S">
              <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
                <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="{uuid}"/>
                <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
                  <cenc:pssh>{Convert.ToBase64String(MakePssh(keyId))}</cenc:pssh>
                  <Laurl licenseUrl="https://widevine.sprink.cloud/license"/>
                </ContentProtection>
                <Representation id="audio" bandwidth="128000"><SegmentTemplate initialization="init.mp4" media="$Number$.m4s" duration="1"/></Representation>
              </AdaptationSet></Period>
            </MPD>
            """;
    }

    private static byte[] MakeEncryptedInitialization(byte[] keyId, WidevineDashMediaType mediaType)
    {
        byte[] tencPayload = new byte[24];
        tencPayload[6] = 1;
        tencPayload[7] = 8;
        keyId.CopyTo(tencPayload, 8);
        byte[] tenc = Box("tenc", tencPayload);
        byte[] schi = Box("schi", tenc);
        byte[] sinf = Box("sinf", schi);
        int mediaHeader = mediaType == WidevineDashMediaType.Video ? 78 : 28;
        byte[] entryPayload = new byte[mediaHeader + sinf.Length];
        sinf.CopyTo(entryPayload, mediaHeader);
        byte[] entry = Box(mediaType == WidevineDashMediaType.Video ? "encv" : "enca", entryPayload);
        byte[] stsdPayload = new byte[8 + entry.Length];
        BinaryPrimitives.WriteUInt32BigEndian(stsdPayload.AsSpan(4), 1);
        entry.CopyTo(stsdPayload, 8);
        byte[] stsd = Box("stsd", stsdPayload);
        byte[] stbl = Box("stbl", stsd);
        byte[] minf = Box("minf", stbl);
        byte[] mdia = Box("mdia", minf);
        byte[] trak = Box("trak", mdia);
        byte[] moov = Box("moov", trak);
        return Box("ftyp", "isom0000"u8.ToArray()).Concat(moov).ToArray();
    }

    private static byte[] MakeEncryptedFragment(bool includeSampleGroup = false)
    {
        byte[] senc = Box("senc", new byte[8]);
        byte[] trafPayload = includeSampleGroup ? senc.Concat(Box("sgpd", new byte[8])).ToArray() : senc;
        byte[] moof = Box("moof", Box("traf", trafPayload));
        return moof.Concat(Box("mdat", [1, 2, 3, 4])).ToArray();
    }

    private static byte[] MakeClearMp4()
        => Box("ftyp", "isom0000"u8.ToArray()).Concat(Box("moov", [])).Concat(Box("mdat", [1])).ToArray();

    private static byte[] Box(string type, byte[] payload)
    {
        byte[] result = new byte[8 + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(result, checked((uint)result.Length));
        Encoding.ASCII.GetBytes(type).CopyTo(result, 4);
        payload.CopyTo(result, 8);
        return result;
    }

    private static (byte[] Initialization, byte[] Fragments) SplitFmp4(byte[] file)
    {
        int offset = 0;
        while (offset <= file.Length - 8)
        {
            uint size = BinaryPrimitives.ReadUInt32BigEndian(file.AsSpan(offset));
            if (size < 8 || size > file.Length - offset) throw new InvalidDataException("Generated fMP4 box size is invalid.");
            string type = Encoding.ASCII.GetString(file, offset + 4, 4);
            if (type == "moof")
                return (file[..offset], file[offset..]);
            offset = checked(offset + (int)size);
        }
        throw new InvalidDataException("Generated encrypted MP4 was not fragmented.");
    }

    private static byte[] MakePssh(byte[] keyId)
    {
        var payload = new WidevineProtobufWriter();
        payload.AppendBytes(2, keyId);
        byte[] payloadBytes = payload.ToArray();
        byte[] result = new byte[32 + payloadBytes.Length];
        BinaryPrimitives.WriteUInt32BigEndian(result, checked((uint)result.Length));
        "pssh"u8.CopyTo(result.AsSpan(4));
        new byte[] { 0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce, 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed }.CopyTo(result, 12);
        BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(28), checked((uint)payloadBytes.Length));
        payloadBytes.CopyTo(result, 32);
        return result;
    }

    private static byte[] MakeWvd(RSA rsa)
    {
        byte[] privateKey = rsa.ExportRSAPrivateKey();
        var certificate = new WidevineProtobufWriter();
        certificate.AppendBytes(4, rsa.ExportRSAPublicKey());
        var signedCertificate = new WidevineProtobufWriter();
        signedCertificate.AppendMessage(1, certificate.ToArray());
        var client = new WidevineProtobufWriter();
        client.AppendVarint(1, 1);
        client.AppendMessage(2, signedCertificate.ToArray());
        byte[] clientBytes = client.ToArray();
        using var stream = new MemoryStream();
        stream.Write([0x57, 0x56, 0x44, 0x02, 0x01, 0x03, 0x00]);
        Span<byte> length = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)privateKey.Length));
        stream.Write(length); stream.Write(privateKey);
        BinaryPrimitives.WriteUInt16BigEndian(length, checked((ushort)clientBytes.Length));
        stream.Write(length); stream.Write(clientBytes);
        return stream.ToArray();
    }

    private sealed class FixtureCredentialSource(byte[] credential) : IWidevineCredentialSource
    {
        public bool IsAvailable => true;
        public Task<WidevineCredentialLease> LoadAsync(CancellationToken cancellationToken = default)
            => Task.FromResult(new WidevineCredentialLease(credential));
    }

    private sealed class FixtureDownloader(Func<Uri, Uri?, long?, long?, HttpResource> factory) : IResourceDownloader
    {
        public Task<HttpResource> FetchAsync(Uri uri, Uri? referer = null, long? rangeOffset = null, long? rangeLength = null, CancellationToken cancellationToken = default)
            => Task.FromResult(factory(uri, referer, rangeOffset, rangeLength));
    }

    private sealed class FixtureLicenseTransport(RSA rsa, byte[] keyId, byte[] contentKey) : IWidevineRawLicenseTransport
    {
        public int CallCount { get; private set; }
        public Task<byte[]> SendAsync(Uri licenseUri, ReadOnlyMemory<byte> challengeBytes, Uri? referer, Func<Uri, bool> isPermittedUri, CancellationToken cancellationToken = default)
        {
            Assert.True(isPermittedUri(licenseUri));
            CallCount++;
            using WidevineSignedMessage signed = WidevineSignedMessage.Parse(challengeBytes.Span);
            byte[] request = Assert.IsType<byte[]>(signed.Message).ToArray();
            byte[] requestId = ExtractRequestId(request);
            using var challenge = new WidevineLicenseChallenge(challengeBytes.ToArray(), request, null, requestId);
            return Task.FromResult(MakeLicenseResponse(rsa, challenge, keyId, contentKey));
        }
    }

    private sealed class FixtureToolRunner : IExternalToolRunner
    {
        public List<ExternalToolInvocation> Invocations { get; } = [];
        public Task<ExternalToolResult> RunAsync(ExternalToolInvocation invocation, CancellationToken cancellationToken = default)
        {
            Invocations.Add(invocation);
            File.WriteAllBytes(invocation.Arguments[^1], MakeClearMp4());
            return Task.FromResult(new ExternalToolResult(0, string.Empty, string.Empty));
        }
    }

    private sealed class FixtureTrackProbe : IMediaTrackProbe
    {
        public Task<MediaTrackInfo> ProbeAsync(string inputPath, TimeSpan timeout, CancellationToken cancellationToken = default)
            => Task.FromResult(new MediaTrackInfo(true, true, 48_000, 2));
    }

    private static byte[] ExtractRequestId(byte[] request)
    {
        var requestReader = new WidevineProtobufReader(request);
        while (requestReader.TryRead(out WidevineProtobufField field))
        {
            if (field.Number != 2 || field.Bytes is null) continue;
            var contentReader = new WidevineProtobufReader(field.Bytes);
            while (contentReader.TryRead(out WidevineProtobufField content))
            {
                if (content.Number != 1 || content.Bytes is null) continue;
                var psshReader = new WidevineProtobufReader(content.Bytes);
                while (psshReader.TryRead(out WidevineProtobufField pssh))
                    if (pssh.Number == 3 && pssh.Bytes is not null) return pssh.Bytes;
            }
        }
        throw new InvalidDataException();
    }

    private static byte[] MakeLicenseResponse(RSA rsa, WidevineLicenseChallenge challenge, byte[] keyId, byte[] contentKey)
    {
        byte[] sessionKey = Enumerable.Repeat((byte)0xa1, 16).ToArray();
        byte[] iv = Enumerable.Repeat((byte)0xb2, 16).ToArray();
        byte[] signingIv = Enumerable.Repeat((byte)0xc3, 16).ToArray();
        byte[] signingKey = Enumerable.Repeat((byte)0xd4, 16).ToArray();
        byte[] encryptionKey = WidevineL3Crypto.DeriveEncryptionKey(challenge.LicenseRequestData.Span, sessionKey);
        byte[] encryptedKey;
        byte[] encryptedSigningKey;
        using (Aes aes = Aes.Create())
        {
            aes.Key = encryptionKey;
            encryptedKey = aes.EncryptCbc(contentKey, iv, PaddingMode.PKCS7);
            encryptedSigningKey = aes.EncryptCbc(signingKey, signingIv, PaddingMode.PKCS7);
        }
        var signing = new WidevineProtobufWriter();
        signing.AppendBytes(2, signingIv); signing.AppendBytes(3, encryptedSigningKey); signing.AppendVarint(4, 1); signing.AppendVarint(5, 1);
        var key = new WidevineProtobufWriter();
        key.AppendBytes(1, keyId); key.AppendBytes(2, iv); key.AppendBytes(3, encryptedKey); key.AppendVarint(4, 2); key.AppendVarint(5, 1);
        var policy = new WidevineProtobufWriter();
        policy.AppendVarint(1, 1); policy.AppendVarint(2, 1); policy.AppendVarint(6, 0);
        var identification = new WidevineProtobufWriter();
        identification.AppendBytes(1, challenge.RequestId.Span); identification.AppendVarint(4, 2);
        var license = new WidevineProtobufWriter();
        license.AppendMessage(1, identification.ToArray()); license.AppendMessage(2, policy.ToArray());
        license.AppendMessage(3, signing.ToArray()); license.AppendMessage(3, key.ToArray()); license.AppendVarint(4, Now);
        byte[] licenseBytes = license.ToArray();
        byte[] authenticationKey = WidevineL3Crypto.DeriveAuthenticationKey(challenge.LicenseRequestData.Span, sessionKey);
        byte[] signature = HMACSHA256.HashData(authenticationKey, licenseBytes);
        var response = new WidevineProtobufWriter();
        response.AppendVarint(1, 2); response.AppendBytes(2, licenseBytes); response.AppendBytes(3, signature);
        response.AppendBytes(4, rsa.Encrypt(sessionKey, RSAEncryptionPadding.OaepSHA1)); response.AppendVarint(8, 1);
        return response.ToArray();
    }
}
