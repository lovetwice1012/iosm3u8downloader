namespace HLSDownloader.Media.Tests;

public sealed class SampleAesLocalPackageBuilderTests
{
    [Fact]
    public async Task BuildsProtectedIdentityPlaylistWithKeyRotationAndClearInterval()
    {
        using var scope = new TestFileScope();
        string first = scope.PathFor("first.ts");
        string clear = scope.PathFor("clear.ts");
        string second = scope.PathFor("second.ts");
        await File.WriteAllBytesAsync(first, [1, 2, 3]);
        await File.WriteAllBytesAsync(clear, [4, 5, 6]);
        await File.WriteAllBytesAsync(second, [7, 8, 9]);
        var key1 = new SampleAesKey(Enumerable.Repeat((byte)0x11, 16).ToArray(), "0x00000000000000000000000000000001");
        var key2 = new SampleAesKey(Enumerable.Repeat((byte)0x22, 16).ToArray());
        var builder = new SampleAesLocalPackageBuilder(scope.PathFor("jobs"));

        string directory;
        await using (ProtectedPlaylistLease lease = await builder.BuildAsync(new SampleAesPlaylistPackage([
            new SampleAesSegment(first, 1.5, key1),
            new SampleAesSegment(clear, 1.5, null),
            new SampleAesSegment(second, 1.5, key2)
        ])))
        {
            directory = lease.DirectoryPath;
            string playlist = await File.ReadAllTextAsync(lease.PlaylistPath);
            Assert.Contains("METHOD=SAMPLE-AES,KEYFORMAT=\"identity\"", playlist);
            Assert.Contains("METHOD=NONE", playlist);
            Assert.Equal(2, Directory.GetFiles(directory, "*.key").Length);
            Assert.All(Directory.GetFiles(directory), path => Assert.Equal(directory, Path.GetDirectoryName(path)));
        }

        Assert.False(Directory.Exists(directory));
    }

    [Fact]
    public async Task RejectsFmp4KeyRotation()
    {
        using var scope = new TestFileScope();
        string init = scope.PathFor("init.mp4");
        string first = scope.PathFor("first.m4s");
        string second = scope.PathFor("second.m4s");
        await File.WriteAllBytesAsync(init, [0]);
        await File.WriteAllBytesAsync(first, [1]);
        await File.WriteAllBytesAsync(second, [2]);
        var builder = new SampleAesLocalPackageBuilder(scope.PathFor("jobs"));
        var package = new SampleAesPlaylistPackage([
            new SampleAesSegment(first, 1, new SampleAesKey(new byte[16])),
            new SampleAesSegment(second, 1, new SampleAesKey(Enumerable.Repeat((byte)1, 16).ToArray()))
        ], InitializationSegmentPath: init);

        await Assert.ThrowsAsync<NotSupportedException>(() => builder.BuildAsync(package));
    }
}
