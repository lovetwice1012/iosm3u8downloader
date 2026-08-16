namespace HLSDownloader.Core.Tests;

public sealed class HlsPlaylistParserTests
{
    private static readonly Uri BaseUri = new("https://example.com/path/master.m3u8");

    [Fact]
    public void ParsesMasterVariantsAndExternalAudio()
    {
        var text = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese, Main",DEFAULT=YES,AUTOSELECT=YES,URI="audio/list.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=1000,AVERAGE-BANDWIDTH=900,RESOLUTION=640x360,AUDIO="a"
            low/list.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000,AUDIO="a"
            high/list.m3u8
            """;
        var master = Assert.IsType<HlsMasterPlaylist>(HlsPlaylistParser.Parse(text, BaseUri));
        Assert.Equal(2, master.Variants.Count);
        Assert.Equal(new Uri("https://example.com/path/high/list.m3u8"), master.Variants[1].Uri);
        Assert.Equal("Japanese, Main", master.Renditions.Single().Name);
        Assert.True(master.Renditions.Single().IsDefault);
    }

    [Fact]
    public void ParsesMapByteRangesSequenceAndDiscontinuity()
    {
        var text = """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:12
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"
            #EXTINF:4.5,
            #EXT-X-BYTERANGE:50@100
            media.mp4
            #EXT-X-DISCONTINUITY
            #EXTINF:5,
            #EXT-X-BYTERANGE:25
            media.mp4
            #EXT-X-ENDLIST
            """;
        var media = Assert.IsType<HlsMediaPlaylist>(HlsPlaylistParser.Parse(text, BaseUri));
        Assert.True(media.HasEndList);
        Assert.Equal((ulong)12, media.Segments[0].MediaSequence);
        Assert.Equal(new HlsByteRange(150, 25), media.Segments[1].ByteRange);
        Assert.Equal(new HlsByteRange(0, 100), media.Segments[0].InitializationMap!.ByteRange);
        Assert.True(media.Segments[1].HasDiscontinuity);
    }

    [Fact]
    public void ParsesIdentityAes128AndIv()
    {
        var text = """
            #EXTM3U
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example/key",IV=0x01
            #EXTINF:1,
            one.ts
            """;
        var media = Assert.IsType<HlsMediaPlaylist>(HlsPlaylistParser.Parse(text, BaseUri));
        var encryption = media.Segments.Single().Encryption!;
        Assert.Equal(HlsEncryptionMethod.Aes128, encryption.Method);
        Assert.Equal(16, encryption.ExplicitIv!.Length);
        Assert.Equal(1, encryption.ExplicitIv[^1]);
    }

    [Fact]
    public void ParsesIdentitySampleAesAndMethodNoneRotation()
    {
        var text = """
            #EXTM3U
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="key.bin",KEYFORMAT="identity"
            #EXTINF:1,
            encrypted.ts
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:1,
            clear.ts
            """;
        var media = Assert.IsType<HlsMediaPlaylist>(HlsPlaylistParser.Parse(text, BaseUri));
        Assert.True(media.UsesSampleAes);
        Assert.Equal(HlsEncryptionMethod.SampleAes, media.Segments[0].Encryption!.Method);
        Assert.Null(media.Segments[1].Encryption);
    }

    [Theory]
    [InlineData("#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"skd://asset\",KEYFORMAT=\"com.apple.streamingkeydelivery\"")]
    [InlineData("#EXT-X-KEY:METHOD=SAMPLE-AES-CTR,URI=\"key.bin\"")]
    [InlineData("#EXT-X-KEY:METHOD=CENC,URI=\"key.bin\"")]
    public void RejectsFairPlayCtrAndUnknownMethods(string keyLine)
    {
        var text = $"#EXTM3U\n{keyLine}\n#EXTINF:1,\none.ts";
        Assert.Throws<PlaylistException>(() => HlsPlaylistParser.Parse(text, BaseUri));
    }

    [Fact]
    public void SampleAesMapDoesNotRequireExplicitIv()
    {
        var text = "#EXTM3U\n#EXT-X-KEY:METHOD=SAMPLE-AES,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\none.m4s";
        var media = Assert.IsType<HlsMediaPlaylist>(HlsPlaylistParser.Parse(text, BaseUri));
        Assert.Equal(HlsEncryptionMethod.SampleAes, media.Segments[0].InitializationMap!.Encryption!.Method);
    }

    [Fact]
    public void Aes128MapRequiresExplicitIv()
    {
        var text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:1,\none.m4s";
        Assert.Throws<PlaylistException>(() => HlsPlaylistParser.Parse(text, BaseUri));
    }

    [Fact]
    public void RejectsImplicitByteRangeAfterDifferentUri()
    {
        var text = "#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:5@0\na.ts\n#EXTINF:1,\n#EXT-X-BYTERANGE:5\nb.ts";
        Assert.Throws<PlaylistException>(() => HlsPlaylistParser.Parse(text, BaseUri));
    }

    [Theory]
    [InlineData("")]
    [InlineData("not a playlist")]
    [InlineData("#EXTM3U\n#EXT-X-I-FRAMES-ONLY\n#EXTINF:1,\na.ts")]
    [InlineData("#EXTM3U\n#EXTINF:1,")]
    public void RejectsMalformedOrUnsupportedPlaylists(string text) =>
        Assert.Throws<PlaylistException>(() => HlsPlaylistParser.Parse(text, BaseUri));
}
