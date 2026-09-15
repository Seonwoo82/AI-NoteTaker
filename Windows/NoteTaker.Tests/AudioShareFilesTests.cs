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
        Directory.SetCreationTimeUtc(Path.GetDirectoryName(first)!, now.AddHours(-25).UtcDateTime);
        library.PruneAudioShareCopies(recording.Id, now);
        Assert.False(File.Exists(first)); Assert.True(File.Exists(second)); Assert.True(File.Exists(library.AudioPath(recording.Id)));
        library.Save(recording with { DeletedAt = DateTimeOffset.UtcNow });
        await Assert.ThrowsAsync<InvalidOperationException>(() => library.CreateAudioShareCopyAsync(library.Load().Single()));
        Assert.Single(Directory.GetDirectories(Path.Combine(library.DirectoryFor(recording.Id), "SharedAudio")));
    }
    [Theory]
    [InlineData("CON", "녹음 - CON.wav")]
    [InlineData("aux.txt", "녹음 - aux.txt.wav")]
    [InlineData(" . ", "녹음.wav")]
    public void SharedAndExportedAudioFilenamesAvoidWindowsReservedNames(string title, string expected)
        => Assert.Equal(expected, LibraryStore.AudioFileName(title));
}
