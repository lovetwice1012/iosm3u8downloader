using System.Security.Cryptography;

namespace HLSDownloader.Media.Tests;

internal static class IdentitySampleAesFixture
{
    internal static async Task<string> CreateProtectedAacAsync(
        string ffmpegPath,
        IExternalToolRunner runner,
        string directory,
        byte[] key,
        byte[] initializationVector)
    {
        string clearPath = Path.Combine(directory, "clear.aac");
        ExternalToolResult result = await runner.RunAsync(new ExternalToolInvocation(
            ffmpegPath,
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000",
                "-t", "0.6", "-c:a", "aac", "-b:a", "128k", "-f", "adts", clearPath
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, result.ExitCode);

        byte[] clear = await File.ReadAllBytesAsync(clearPath);
        byte[] encrypted = clear.ToArray();
        int encryptedBlockCount = EncryptAdtsFrames(encrypted, key, initializationVector);
        Assert.True(encryptedBlockCount > 0);
        Assert.False(clear.AsSpan().SequenceEqual(encrypted));

        string protectedPath = Path.Combine(directory, "protected.aac");
        await File.WriteAllBytesAsync(protectedPath, encrypted);
        return protectedPath;
    }

    internal static async Task<string> CreateProtectedAudioVideoTransportStreamAsync(
        string ffmpegPath,
        IExternalToolRunner runner,
        string directory,
        byte[] key,
        byte[] initializationVector)
    {
        string clearVideoPath = Path.Combine(directory, "clear.h264");
        string clearAudioPath = Path.Combine(directory, "clear-video-audio.aac");
        ExternalToolResult videoResult = await runner.RunAsync(new ExternalToolInvocation(
            ffmpegPath,
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "testsrc=size=32x32:rate=10:duration=0.6,tpad=stop_mode=clone:stop_duration=1.5",
                "-an", "-c:v", "libx264", "-preset", "ultrafast",
                "-g", "50", "-keyint_min", "50", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
                "-f", "h264", clearVideoPath
            ],
            TimeSpan.FromSeconds(30)));
        ExternalToolResult audioResult = await runner.RunAsync(new ExternalToolInvocation(
            ffmpegPath,
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-f", "lavfi", "-i", "sine=frequency=659:sample_rate=48000",
                "-t", "2.5", "-c:a", "aac", "-b:a", "128k", "-f", "adts", clearAudioPath
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, videoResult.ExitCode);
        Assert.Equal(0, audioResult.ExitCode);

        byte[] clearVideo = await File.ReadAllBytesAsync(clearVideoPath);
        byte[] protectedVideo = EncryptAnnexBVideo(clearVideo, key, initializationVector, out int encryptedVideoBlocks);
        Assert.True(encryptedVideoBlocks > 0);
        Assert.False(clearVideo.AsSpan().SequenceEqual(protectedVideo));
        string protectedVideoPath = Path.Combine(directory, "protected.h264");
        await File.WriteAllBytesAsync(protectedVideoPath, protectedVideo);

        byte[] clearAudio = await File.ReadAllBytesAsync(clearAudioPath);
        byte[] protectedAudio = clearAudio.ToArray();
        int encryptedAudioBlocks = EncryptAdtsFrames(protectedAudio, key, initializationVector);
        Assert.True(encryptedAudioBlocks > 0);
        Assert.False(clearAudio.AsSpan().SequenceEqual(protectedAudio));
        string protectedAudioPath = Path.Combine(directory, "protected-video-audio.aac");
        await File.WriteAllBytesAsync(protectedAudioPath, protectedAudio);

        string transportStreamPath = Path.Combine(directory, "protected.ts");
        ExternalToolResult muxResult = await runner.RunAsync(new ExternalToolInvocation(
            ffmpegPath,
            [
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-fflags", "+genpts", "-r", "10", "-f", "h264", "-i", protectedVideoPath,
                "-f", "aac", "-i", protectedAudioPath,
                "-t", "2.4", "-c", "copy", "-f", "mpegts", transportStreamPath
            ],
            TimeSpan.FromSeconds(30)));
        Assert.Equal(0, muxResult.ExitCode);

        byte[] transportStream = await File.ReadAllBytesAsync(transportStreamPath);
        int protectedStreamCount = MarkSampleEncryptedStreams(transportStream);
        Assert.Equal(2, protectedStreamCount);
        await File.WriteAllBytesAsync(transportStreamPath, transportStream);
        return transportStreamPath;
    }

    private static int EncryptAdtsFrames(byte[] data, byte[] key, byte[] initializationVector)
    {
        int offset = 0;
        int encryptedBlockCount = 0;
        while (offset < data.Length)
        {
            if (offset + 7 > data.Length || data[offset] != 0xff || (data[offset + 1] & 0xf0) != 0xf0)
            {
                throw new InvalidDataException("The generated AAC fixture did not contain a complete ADTS frame.");
            }

            int headerLength = (data[offset + 1] & 0x01) == 0x01 ? 7 : 9;
            int frameLength = ((data[offset + 3] & 0x03) << 11) |
                              (data[offset + 4] << 3) |
                              ((data[offset + 5] >> 5) & 0x07);
            if (frameLength < headerLength || offset + frameLength > data.Length)
            {
                throw new InvalidDataException("The generated AAC fixture contained an invalid ADTS frame length.");
            }

            int encryptedLength = Math.Max(0, (frameLength - headerLength - 16) / 16 * 16);
            if (encryptedLength > 0)
            {
                EncryptContiguousBlocks(data, offset + headerLength + 16, encryptedLength, key, initializationVector);
                encryptedBlockCount += encryptedLength / 16;
            }

            offset += frameLength;
        }

        return encryptedBlockCount;
    }

    private static byte[] EncryptAnnexBVideo(
        byte[] data,
        byte[] key,
        byte[] initializationVector,
        out int encryptedBlockCount)
    {
        encryptedBlockCount = 0;
        using var output = new MemoryStream(data.Length + 1024);
        int start = FindStartCode(data, 0, out int startCodeLength);
        if (start != 0)
        {
            throw new InvalidDataException("The generated H.264 fixture did not start with an Annex B start code.");
        }

        while (start >= 0)
        {
            int bodyStart = start + startCodeLength;
            int nextStart = FindStartCode(data, bodyStart, out int nextStartCodeLength);
            int bodyEnd = nextStart >= 0 ? nextStart : data.Length;
            output.Write(data, start, startCodeLength);

            byte[] body = RemoveEmulationPrevention(data.AsSpan(bodyStart, bodyEnd - bodyStart));
            int nalType = body.Length == 0 ? -1 : body[0] & 0x1f;
            if ((nalType == 1 || nalType == 5) && body.Length > 48)
            {
                encryptedBlockCount += EncryptVideoPattern(body, key, initializationVector);
            }

            byte[] escaped = AddEmulationPrevention(body);
            output.Write(escaped);
            start = nextStart;
            startCodeLength = nextStartCodeLength;
        }

        return output.ToArray();
    }

    private static int EncryptVideoPattern(byte[] body, byte[] key, byte[] initializationVector)
    {
        using Aes aes = CreateAes(key, initializationVector);
        using ICryptoTransform encryptor = aes.CreateEncryptor();
        int offset = 32;
        int remaining = body.Length - offset;
        int encryptedBlockCount = 0;
        while (remaining > 0)
        {
            if (remaining > 16)
            {
                byte[] encrypted = new byte[16];
                int transformed = encryptor.TransformBlock(body, offset, 16, encrypted, 0);
                if (transformed != 16)
                {
                    throw new CryptographicException("AES did not transform a complete SAMPLE-AES block.");
                }

                encrypted.CopyTo(body, offset);
                offset += 16;
                remaining -= 16;
                encryptedBlockCount++;
            }

            int clearLength = Math.Min(144, remaining);
            offset += clearLength;
            remaining -= clearLength;
        }

        return encryptedBlockCount;
    }

    private static void EncryptContiguousBlocks(
        byte[] data,
        int offset,
        int length,
        byte[] key,
        byte[] initializationVector)
    {
        using Aes aes = CreateAes(key, initializationVector);
        using ICryptoTransform encryptor = aes.CreateEncryptor();
        byte[] encrypted = encryptor.TransformFinalBlock(data, offset, length);
        encrypted.CopyTo(data, offset);
    }

    private static Aes CreateAes(byte[] key, byte[] initializationVector)
    {
        var aes = Aes.Create();
        aes.Key = key;
        aes.IV = initializationVector;
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.None;
        return aes;
    }

    private static byte[] RemoveEmulationPrevention(ReadOnlySpan<byte> data)
    {
        using var output = new MemoryStream(data.Length);
        for (int index = 0; index < data.Length; index++)
        {
            if (index + 3 < data.Length && data[index] == 0x00 && data[index + 1] == 0x00 && data[index + 2] == 0x03)
            {
                output.WriteByte(0x00);
                output.WriteByte(0x00);
                index += 2;
            }
            else
            {
                output.WriteByte(data[index]);
            }
        }

        return output.ToArray();
    }

    private static byte[] AddEmulationPrevention(ReadOnlySpan<byte> data)
    {
        using var output = new MemoryStream(data.Length + data.Length / 32);
        int zeroCount = 0;
        foreach (byte value in data)
        {
            if (zeroCount >= 2 && value <= 0x03)
            {
                output.WriteByte(0x03);
                zeroCount = 0;
            }

            output.WriteByte(value);
            zeroCount = value == 0x00 ? zeroCount + 1 : 0;
        }

        return output.ToArray();
    }

    private static int FindStartCode(byte[] data, int offset, out int length)
    {
        for (int index = offset; index + 3 <= data.Length; index++)
        {
            if (index + 4 <= data.Length && data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 0 && data[index + 3] == 1)
            {
                length = 4;
                return index;
            }

            if (data[index] == 0 && data[index + 1] == 0 && data[index + 2] == 1)
            {
                length = 3;
                return index;
            }
        }

        length = 0;
        return -1;
    }

    private static int MarkSampleEncryptedStreams(byte[] transportStream)
    {
        if (transportStream.Length % 188 != 0)
        {
            throw new InvalidDataException("The generated MPEG-TS fixture did not use 188-byte packets.");
        }

        int? programMapPid = null;
        int protectedStreamCount = 0;
        for (int packetOffset = 0; packetOffset < transportStream.Length; packetOffset += 188)
        {
            if (transportStream[packetOffset] != 0x47)
            {
                throw new InvalidDataException("The generated MPEG-TS fixture contained an invalid sync byte.");
            }

            int pid = ((transportStream[packetOffset + 1] & 0x1f) << 8) | transportStream[packetOffset + 2];
            bool payloadUnitStart = (transportStream[packetOffset + 1] & 0x40) != 0;
            int payloadOffset = GetPayloadOffset(transportStream, packetOffset);
            if (!payloadUnitStart || payloadOffset >= packetOffset + 188)
            {
                continue;
            }

            int sectionOffset = payloadOffset + 1 + transportStream[payloadOffset];
            if (sectionOffset + 3 > packetOffset + 188)
            {
                continue;
            }

            if (pid == 0 && transportStream[sectionOffset] == 0x00)
            {
                programMapPid ??= ReadProgramMapPid(transportStream, sectionOffset, packetOffset + 188);
            }
            else if (programMapPid == pid && transportStream[sectionOffset] == 0x02)
            {
                protectedStreamCount = Math.Max(
                    protectedStreamCount,
                    RewriteProgramMapSection(transportStream, sectionOffset, packetOffset + 188));
            }
        }

        if (programMapPid is null)
        {
            throw new InvalidDataException("The generated MPEG-TS fixture did not contain a program map.");
        }

        return protectedStreamCount;
    }

    private static int ReadProgramMapPid(byte[] data, int sectionOffset, int packetEnd)
    {
        int sectionLength = ((data[sectionOffset + 1] & 0x0f) << 8) | data[sectionOffset + 2];
        int sectionEnd = sectionOffset + 3 + sectionLength;
        if (sectionEnd > packetEnd)
        {
            throw new InvalidDataException("The PAT fixture unexpectedly spanned multiple MPEG-TS packets.");
        }

        for (int offset = sectionOffset + 8; offset + 4 <= sectionEnd - 4; offset += 4)
        {
            int programNumber = (data[offset] << 8) | data[offset + 1];
            if (programNumber != 0)
            {
                return ((data[offset + 2] & 0x1f) << 8) | data[offset + 3];
            }
        }

        throw new InvalidDataException("The PAT fixture did not declare a program map PID.");
    }

    private static int RewriteProgramMapSection(byte[] data, int sectionOffset, int packetEnd)
    {
        int sectionLength = ((data[sectionOffset + 1] & 0x0f) << 8) | data[sectionOffset + 2];
        int sectionEnd = sectionOffset + 3 + sectionLength;
        if (sectionEnd > packetEnd)
        {
            throw new InvalidDataException("The PMT fixture unexpectedly spanned multiple MPEG-TS packets.");
        }

        int programInfoLength = ((data[sectionOffset + 10] & 0x0f) << 8) | data[sectionOffset + 11];
        int streamOffset = sectionOffset + 12 + programInfoLength;
        int protectedStreamCount = 0;
        while (streamOffset + 5 <= sectionEnd - 4)
        {
            if (data[streamOffset] == 0x1b)
            {
                data[streamOffset] = 0xdb;
                protectedStreamCount++;
            }
            else if (data[streamOffset] == 0x0f)
            {
                data[streamOffset] = 0xcf;
                protectedStreamCount++;
            }

            int elementaryInfoLength = ((data[streamOffset + 3] & 0x0f) << 8) | data[streamOffset + 4];
            streamOffset += 5 + elementaryInfoLength;
        }

        uint crc = ComputeMpegCrc32(data.AsSpan(sectionOffset, sectionEnd - sectionOffset - 4));
        data[sectionEnd - 4] = (byte)(crc >> 24);
        data[sectionEnd - 3] = (byte)(crc >> 16);
        data[sectionEnd - 2] = (byte)(crc >> 8);
        data[sectionEnd - 1] = (byte)crc;
        return protectedStreamCount;
    }

    private static int GetPayloadOffset(byte[] data, int packetOffset)
    {
        int adaptationControl = (data[packetOffset + 3] >> 4) & 0x03;
        return adaptationControl switch
        {
            1 => packetOffset + 4,
            3 => packetOffset + 5 + data[packetOffset + 4],
            _ => packetOffset + 188
        };
    }

    private static uint ComputeMpegCrc32(ReadOnlySpan<byte> data)
    {
        uint crc = uint.MaxValue;
        foreach (byte value in data)
        {
            crc ^= (uint)value << 24;
            for (int bit = 0; bit < 8; bit++)
            {
                crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04c11db7 : crc << 1;
            }
        }

        return crc;
    }
}
