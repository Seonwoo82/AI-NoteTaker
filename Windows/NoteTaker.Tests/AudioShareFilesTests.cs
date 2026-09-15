using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class AudioShareFilesTests
{
    private static Recording Add(LibraryStore library)
    {
        var recording = new Recording { Title = "출시 / 회의: 정리", DurationSeconds = 1 };
        TestFolder.Wave(library.AudioPath(recording.Id)); library.Save(recording); return library.Load().Single();
    }
    [Fact] public async Task SharingUsesImmutableNamedCopyWithoutChangingOriginalMetadataAndPurgeRemovesIt()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var recording = Add(library);
        string metadata = File.ReadAllText(Path.Combine(library.DirectoryFor(recording.Id), "meta.json"));
        byte[] source = File.ReadAllBytes(library.AudioPath(recording.Id));
        string copy = await library.CreateAudioShareCopyAsync(recording);
        Assert.Equal("출시 _ 회의_ 정리.wav", Path.GetFileName(copy)); Assert.Equal(source, File.ReadAllBytes(copy));
        Assert.Equal(metadata, File.ReadAllText(Path.Combine(library.DirectoryFor(recording.Id), "meta.json")));
        TestFolder.Wave(library.AudioPath(recording.Id), 2); library.Save(recording with { AudioVersion = 2 });
        Assert.Equal(source, File.ReadAllBytes(copy));
        library.Save(library.Load().Single() with { DeletedAt = DateTimeOffset.UtcNow });
        library.DeletePermanently(library.Load().Single()); Assert.False(File.Exists(copy));
    }
    [Fact] public async Task SharingRejectsDeletedOrCancelledSelectionAndPrunesOnlyExpiredCopies()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var recording = Add(library);
        using var cancel = new CancellationTokenSource(); cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => library.CreateAudioShareCopyAsync(recording, cancel.Token));
        string first = await library.CreateAudioShareCopyAsync(recording), second = await library.CreateAudioShareCopyAsync(recording);
        var now = DateTimeOffset.UtcNow;
        string shareId = Path.GetFileName(Path.GetDirectoryName(first)!).Split('-')[^1];
        Directory.SetCreationTimeUtc(Path.Combine(library.DirectoryFor(recording.Id), "SharedAudio", shareId), now.AddHours(-25).UtcDateTime);
        Directory.SetCreationTimeUtc(Path.GetDirectoryName(first)!, now.AddHours(-25).UtcDateTime);
        library.PruneAudioShareCopies(recording.Id, now);
        Assert.False(File.Exists(first)); Assert.True(File.Exists(second)); Assert.True(File.Exists(library.AudioPath(recording.Id)));
        library.Save(recording with { DeletedAt = DateTimeOffset.UtcNow });
        await Assert.ThrowsAsync<InvalidOperationException>(() => library.CreateAudioShareCopyAsync(library.Load().Single()));
        Assert.Single(Directory.GetDirectories(Path.Combine(library.DirectoryFor(recording.Id), "SharedAudio")));
        library.DeletePermanently(library.Load().Single()); Assert.False(File.Exists(second));
    }
    [Fact] public async Task DeepLibraryAndLongTitleUseShortOwnedCacheAndLockedCopyCanRetryPurge()
    {
        using var test = new TestFolder();
        var library = new LibraryStore(Path.Combine(test.Root, new string('a', 100), new string('b', 100)));
        var recording = Add(library); library.Save(recording with { Title = new string('한', 180) }); recording = library.Load().Single();
        string copy = await library.CreateAudioShareCopyAsync(recording);
        Assert.True(library.AudioPath(recording.Id).Length > 260); Assert.InRange(copy.Length, 1, 240);
        Assert.Equal(File.ReadAllBytes(library.AudioPath(recording.Id)), File.ReadAllBytes(copy));
        library.Save(recording with { DeletedAt = DateTimeOffset.UtcNow }); var deleted = library.Load().Single();
        using (var locked = new FileStream(copy, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            Assert.ThrowsAny<IOException>(() => library.DeletePermanently(deleted));
            Assert.True(File.Exists(copy)); Assert.True(Directory.Exists(Path.Combine(library.DirectoryFor(recording.Id), "SharedAudio")));
        }
        Assert.True(library.Load().Single().IsLocallyPurged); Assert.False(File.Exists(copy));
    }
    [Theory]
    [InlineData("CON", "녹음 - CON.wav")]
    [InlineData("aux.txt", "녹음 - aux.txt.wav")]
    [InlineData(" . ", "녹음.wav")]
    public void SharedAndExportedAudioFilenamesAvoidWindowsReservedNames(string title, string expected)
        => Assert.Equal(expected, LibraryStore.AudioFileName(title));
}
