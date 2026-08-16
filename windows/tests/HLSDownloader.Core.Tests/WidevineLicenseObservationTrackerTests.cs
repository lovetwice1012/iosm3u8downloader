using System.Text.Json;
using HLSDownloader.WebProbe;

namespace HLSDownloader.Core.Tests;

public sealed class WidevineLicenseObservationTrackerTests
{
    private static readonly string[] AllowedHosts = ["widevine.sprink.cloud"];
    private static readonly Uri Manifest = new("https://widevine.sprink.cloud/video/manifest.mpd");
    private static readonly Uri License = new("https://widevine.sprink.cloud/license?session=opaque");
    private static readonly DateTimeOffset StartedAt = new(2026, 8, 16, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void AssociationTextDoesNotExposeManifestOrLicenseUris()
    {
        var association = new WidevineLicenseAssociation(Manifest, License);

        Assert.Equal("WidevineLicenseAssociation(<redacted>)", association.ToString());
        Assert.DoesNotContain("opaque", $"{association}", StringComparison.Ordinal);
        Assert.DoesNotContain("/video/", string.Concat(association), StringComparison.Ordinal);
        var debuggerDisplay = Assert.IsType<System.Diagnostics.DebuggerDisplayAttribute>(Assert.Single(
            typeof(WidevineLicenseAssociation).GetCustomAttributes(
                typeof(System.Diagnostics.DebuggerDisplayAttribute),
                inherit: false)));
        Assert.Equal("WidevineLicenseAssociation(<redacted>)", debuggerDisplay.Value);
    }

    [Fact]
    public void UniqueManifestAndPostWithinLifecycleProducesAssociation()
    {
        var tracker = new WidevineLicenseObservationTracker(AllowedHosts);

        Assert.True(tracker.ObserveManifest(Manifest));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestStarted,
            StartedAt));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestSucceeded,
            StartedAt.AddSeconds(1)));
        Assert.True(tracker.ObserveSuccessfulPost(
            License,
            "POST",
            200,
            StartedAt.AddSeconds(2)));

        var association = tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(3));

        Assert.NotNull(association);
        Assert.Equal(Manifest, association.ManifestUri);
        Assert.Equal(License, association.LicenseUri);
    }

    [Fact]
    public void RepeatedSamePostUriIsStillUnambiguous()
    {
        var tracker = StartTracker();

        Assert.True(tracker.ObserveSuccessfulPost(License, "POST", 200, StartedAt.AddSeconds(2)));
        Assert.True(tracker.ObserveSuccessfulPost(License, "post", 204, StartedAt.AddSeconds(3)));

        Assert.NotNull(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(4)));
    }

    [Fact]
    public void MultipleManifestUrisAreRejected()
    {
        var tracker = StartTracker();
        Assert.True(tracker.ObserveManifest(
            new Uri("https://widevine.sprink.cloud/video/alternate.mpd")));
        Assert.True(tracker.ObserveSuccessfulPost(License, "POST", 200, StartedAt.AddSeconds(2)));

        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(3)));
    }

    [Fact]
    public void MultiplePostUrisAreRejected()
    {
        var tracker = StartTracker();
        Assert.True(tracker.ObserveSuccessfulPost(License, "POST", 200, StartedAt.AddSeconds(2)));
        Assert.True(tracker.ObserveSuccessfulPost(
            new Uri("https://widevine.sprink.cloud/license/alternate"),
            "POST",
            200,
            StartedAt.AddSeconds(3)));

        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(4)));
    }

    [Theory]
    [InlineData("http://widevine.sprink.cloud/license", "POST", 200)]
    [InlineData("https://www.widevine.sprink.cloud/license", "POST", 200)]
    [InlineData("https://widevine.sprink.cloud.example.com/license", "POST", 200)]
    [InlineData("https://evil-widevine.sprink.cloud/license", "POST", 200)]
    [InlineData("https://widevine.sprink.cloud/license", "GET", 200)]
    [InlineData("https://widevine.sprink.cloud/license", "POST", 302)]
    [InlineData("https://widevine.sprink.cloud/license", "POST", 400)]
    public void OnlySuccessfulPostToExactAllowedHttpsHostIsObserved(
        string rawUri,
        string method,
        int statusCode)
    {
        var tracker = StartTracker();

        Assert.False(tracker.ObserveSuccessfulPost(
            new Uri(rawUri),
            method,
            statusCode,
            StartedAt.AddSeconds(2)));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(3)));
    }

    [Fact]
    public void PostOutsideThirtySecondWindowIsRejected()
    {
        var tracker = StartTracker();

        Assert.False(tracker.ObserveSuccessfulPost(
            License,
            "POST",
            200,
            StartedAt.AddSeconds(31)));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(31)));
    }

    [Fact]
    public void OverlappingGenerateRequestsAreRejectedAsAmbiguous()
    {
        var tracker = StartTracker();

        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestStarted,
            StartedAt.AddSeconds(1)));
        Assert.True(tracker.ObserveSuccessfulPost(License, "POST", 200, StartedAt.AddSeconds(2)));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestSucceeded,
            StartedAt.AddSeconds(3)));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.UpdateSucceeded,
            StartedAt.AddSeconds(4)));
    }

    [Fact]
    public void ParserAcceptsEveryLifecyclePhaseWithoutDeduplicatingThem()
    {
        var session = new ProbeSession();
        var phases = new[]
        {
            "generate-request-started",
            "generate-request-succeeded",
            "update-succeeded"
        };

        for (var index = 0; index < phases.Length; index++)
        {
            var json = JsonSerializer.Serialize(new
            {
                channel = "hls-downloader-probe",
                version = 1,
                nonce = session.Nonce,
                seq = index + 1,
                kind = "eme-lifecycle",
                url = "https://widevine.sprink.cloud/player",
                source = "media-key-session",
                keySystem = "com.widevine.alpha",
                phase = phases[index],
                pageUrl = "https://widevine.sprink.cloud/player"
            });

            Assert.True(ProbePayloadParser.TryParse(json, session, out var signal));
            Assert.NotNull(signal?.EmePhase);
        }

        Assert.Equal(3, session.AcceptedCount);
    }

    [Theory]
    [InlineData(null, "com.widevine.alpha", 1)]
    [InlineData("unknown", "com.widevine.alpha", 1)]
    [InlineData("generate-request-started", "com.apple.fps", 1)]
    [InlineData("generate-request-started", "com.widevine.alpha", 0)]
    public void ParserRejectsInvalidLifecycleSignal(
        string? phase,
        string keySystem,
        long sequence)
    {
        var session = new ProbeSession();
        var json = JsonSerializer.Serialize(new
        {
            channel = "hls-downloader-probe",
            version = 1,
            nonce = session.Nonce,
            seq = sequence,
            kind = "eme-lifecycle",
            url = "https://widevine.sprink.cloud/player",
            source = "media-key-session",
            keySystem,
            phase
        });

        Assert.False(ProbePayloadParser.TryParse(json, session, out _));
    }

    private static WidevineLicenseObservationTracker StartTracker()
    {
        var tracker = new WidevineLicenseObservationTracker(AllowedHosts);
        Assert.True(tracker.ObserveManifest(Manifest));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestStarted,
            StartedAt));
        Assert.Null(tracker.ObserveLifecycle(
            ProbeEmeLifecyclePhase.GenerateRequestSucceeded,
            StartedAt.AddSeconds(1)));
        return tracker;
    }
}
