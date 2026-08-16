using System.Buffers.Binary;
using System.Text;
using HLSDownloader.Core;

namespace HLSDownloader.Media.Tests;

public sealed class WidevineDashManifestTests
{
    [Fact]
    public void StaticVideoAndAudioTemplateBuildsExactHostPlan()
    {
        byte[] videoKey = Enumerable.Repeat((byte)0x11, 16).ToArray();
        byte[] audioKey = Enumerable.Repeat((byte)0x22, 16).ToArray();
        string document = $$"""
            <?xml version="1.0"?>
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT4S">
              <Period>
                <AdaptationSet contentType="video" mimeType="video/mp4">
                  {{Protection(videoKey)}}
                  <SegmentTemplate timescale="1" initialization="v-$RepresentationID$.mp4" media="v-$Number%03d$.m4s" startNumber="1">
                    <SegmentTimeline><S t="0" d="2" r="1"/></SegmentTimeline>
                  </SegmentTemplate>
                  <Representation id="low" bandwidth="100" width="640" height="360"/>
                  <Representation id="high" bandwidth="200" width="1920" height="1080"/>
                </AdaptationSet>
                <AdaptationSet contentType="audio" mimeType="audio/mp4">
                  {{Protection(audioKey)}}
                  <SegmentTemplate timescale="1" initialization="a-$RepresentationID$.mp4" media="a-$Number$.m4s" duration="2"/>
                  <Representation id="audio" bandwidth="128000"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """;

        Uri manifest = new("https://widevine.sprink.cloud/video/manifest.mpd");
        WidevineDashDownloadPlan plan = WidevineDashManifestParser.Parse(
            Encoding.UTF8.GetBytes(document), manifest, WidevineDownloadPolicy.IsDownloadableWidevineDomain);

        Assert.Equal(MediaOutputFormat.Mp4, plan.OutputFormat);
        Assert.Equal(new Uri("https://widevine.sprink.cloud/license"), plan.LicenseUri);
        Assert.Equal("high", plan.Video!.RepresentationId);
        Assert.Equal(videoKey, plan.Video.KeyId);
        Assert.Equal(new Uri("https://widevine.sprink.cloud/video/v-high.mp4"), plan.Video.Initialization.Uri);
        Assert.Equal(new[] { "v-001.m4s", "v-002.m4s" }, plan.Video.Segments.Select(item => Path.GetFileName(item.Uri.AbsolutePath)));
        Assert.Equal(audioKey, plan.Audio!.KeyId);
        Assert.Equal(2, plan.Audio.Segments.Count);
    }

    [Fact]
    public void AudioOnlyPlanSelectsWav()
    {
        byte[] keyId = Enumerable.Repeat((byte)0x33, 16).ToArray();
        string document = $$"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT2S">
              <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
                {{Protection(keyId)}}
                <Representation id="audio" bandwidth="64000">
                  <SegmentList><Initialization sourceURL="init.mp4"/><SegmentURL media="one.m4s"/></SegmentList>
                </Representation>
              </AdaptationSet></Period>
            </MPD>
            """;
        WidevineDashDownloadPlan plan = WidevineDashManifestParser.Parse(
            Encoding.UTF8.GetBytes(document),
            new Uri("https://widevine.sprink.cloud/audio/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain);
        Assert.Null(plan.Video);
        Assert.NotNull(plan.Audio);
        Assert.Equal(MediaOutputFormat.Wav, plan.OutputFormat);
    }

    [Fact]
    public void VerifiedPlaybackLicenseFillsMissingMpdLicenseUrl()
    {
        byte[] keyId = Enumerable.Repeat((byte)0x35, 16).ToArray();
        string document = $$"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT2S">
              <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
                {{Protection(keyId, includeLicenseUrl: false)}}
                <Representation id="audio"><SegmentList><Initialization sourceURL="init.mp4"/><SegmentURL media="one.m4s"/></SegmentList></Representation>
              </AdaptationSet></Period>
            </MPD>
            """;
        Uri observedLicense = new("https://widevine.sprink.cloud/runtime-license");

        WidevineDashDownloadPlan plan = WidevineDashManifestParser.Parse(
            Encoding.UTF8.GetBytes(document),
            new Uri("https://widevine.sprink.cloud/audio/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain,
            observedLicense);

        Assert.Equal(observedLicense, plan.LicenseUri);
    }

    [Fact]
    public void PlaybackLicenseMustMatchMpdLicenseUrl()
    {
        byte[] keyId = Enumerable.Repeat((byte)0x36, 16).ToArray();
        string document = $$"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static" mediaPresentationDuration="PT2S">
              <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
                {{Protection(keyId)}}
                <Representation id="audio"><SegmentList><Initialization sourceURL="init.mp4"/><SegmentURL media="one.m4s"/></SegmentList></Representation>
              </AdaptationSet></Period>
            </MPD>
            """;

        Assert.Throws<WidevineDashManifestException>(() => WidevineDashManifestParser.Parse(
            Encoding.UTF8.GetBytes(document),
            new Uri("https://widevine.sprink.cloud/audio/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain,
            new Uri("https://widevine.sprink.cloud/other-license")));
    }

    [Theory]
    [InlineData("https://cdn.example.com/init.mp4")]
    [InlineData("http://widevine.sprink.cloud/init.mp4")]
    [InlineData("https://www.widevine.sprink.cloud/init.mp4")]
    public void SegmentOutsideExactHttpsHostIsRejected(string initialization)
    {
        byte[] keyId = Enumerable.Repeat((byte)0x44, 16).ToArray();
        string document = $$"""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" xmlns:cenc="urn:mpeg:cenc:2013" type="static">
              <Period><AdaptationSet contentType="audio" mimeType="audio/mp4">
                {{Protection(keyId)}}
                <Representation id="audio"><SegmentList><Initialization sourceURL="{{initialization}}"/><SegmentURL media="one.m4s"/></SegmentList></Representation>
              </AdaptationSet></Period>
            </MPD>
            """;
        Assert.Throws<WidevineDashManifestException>(() => WidevineDashManifestParser.Parse(
            Encoding.UTF8.GetBytes(document),
            new Uri("https://widevine.sprink.cloud/audio/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain));
    }

    [Fact]
    public void DynamicPresentationIsRejected()
    {
        Assert.Throws<WidevineDashManifestException>(() => WidevineDashManifestParser.Parse(
            "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" type=\"dynamic\"/>"u8.ToArray(),
            new Uri("https://widevine.sprink.cloud/manifest.mpd"),
            WidevineDownloadPolicy.IsDownloadableWidevineDomain));
    }

    private static string Protection(byte[] keyId, bool includeLicenseUrl = true)
    {
        string uuid = Convert.ToHexString(keyId).ToLowerInvariant();
        uuid = $"{uuid[..8]}-{uuid[8..12]}-{uuid[12..16]}-{uuid[16..20]}-{uuid[20..]}";
        string license = includeLicenseUrl
            ? "<Laurl licenseUrl=\"https://widevine.sprink.cloud/license\"/>"
            : string.Empty;
        return $"""
          <ContentProtection schemeIdUri="urn:mpeg:dash:mp4protection:2011" value="cenc" cenc:default_KID="{uuid}"/>
          <ContentProtection schemeIdUri="urn:uuid:edef8ba9-79d6-4ace-a3c8-27dcd51d21ed">
            <cenc:pssh>{Convert.ToBase64String(MakePssh(keyId))}</cenc:pssh>
            {license}
          </ContentProtection>
          """;
    }

    private static byte[] MakePssh(byte[] keyId)
    {
        var payload = new WidevineProtobufWriter();
        payload.AppendBytes(2, keyId);
        byte[] payloadBytes = payload.ToArray();
        byte[] result = new byte[32 + payloadBytes.Length];
        BinaryPrimitives.WriteUInt32BigEndian(result, checked((uint)result.Length));
        "pssh"u8.CopyTo(result.AsSpan(4));
        // version 0, flags 0
        new byte[] { 0xed, 0xef, 0x8b, 0xa9, 0x79, 0xd6, 0x4a, 0xce, 0xa3, 0xc8, 0x27, 0xdc, 0xd5, 0x1d, 0x21, 0xed }
            .CopyTo(result, 12);
        BinaryPrimitives.WriteUInt32BigEndian(result.AsSpan(28), checked((uint)payloadBytes.Length));
        payloadBytes.CopyTo(result, 32);
        return result;
    }
}
