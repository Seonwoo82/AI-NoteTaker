using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class LibraryFilesTests
{
    private static Recording Add(LibraryStore library, bool deleted = false)
    {
        var record = new Recording { Title = "보관할 회의", DurationSeconds = 1, DeletedAt = deleted ? DateTimeOffset.UtcNow : null };
        TestFolder.Wave(library.AudioPath(record.Id)); library.Save(record);
        return library.Load().Single(r => r.Id == record.Id);
    }
    [Fact] public void PurgeKeepsExactTombstoneRemovesOnlyOwnedFilesAndCannotDeleteAnActiveRecording()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root);
        var active = Add(library); var deleted = Add(library, true);
        Assert.Throws<InvalidOperationException>(() => library.DeletePermanently(active));
        string prefix = $"Recordings/{deleted.Id:D}/", other = $"Recordings/{active.Id:D}/notes.json";
        File.WriteAllText(library.NotesPath(deleted.Id), "private meeting notes"); File.WriteAllText(library.NotesPath(active.Id), "other meeting notes");
        var paths = new[] { prefix + "notes.json", other };
        SyncFileTransaction.Commit(library.Root, SyncFileTransaction.Snapshot(library.Root, paths), [new(paths[0], null), new(paths[1], null)]);
        string history = Directory.GetDirectories(Path.Combine(test.Root, ".sync", "transactions")).Single();
        string outgoing = Path.Combine(test.Root, ".sync", "outgoing"); Directory.CreateDirectory(outgoing);
        string ownedCopy = Path.Combine(outgoing, $"{deleted.Id:D}-1-hash.m4a"), otherCopy = Path.Combine(outgoing, $"{active.Id:D}-1-hash.m4a");
        File.WriteAllText(ownedCopy, "owned audio"); File.WriteAllText(otherCopy, "other audio");
        string nested = Path.Combine(library.DirectoryFor(deleted.Id), "history", "old"); Directory.CreateDirectory(nested); File.WriteAllText(Path.Combine(nested, "audio.m4a"), "older audio");
        string meta = Path.Combine(library.DirectoryFor(deleted.Id), "meta.json"), before = File.ReadAllText(meta);
        library.DeletePermanently(deleted);
        Assert.Equal(before, File.ReadAllText(meta)); Assert.True(library.Load().Single(r => r.Id == deleted.Id).IsLocallyPurged);
        Assert.Equal(2, Directory.GetFileSystemEntries(library.DirectoryFor(deleted.Id)).Length);
        Assert.False(File.Exists(Path.Combine(history, "old-0"))); Assert.Equal("other meeting notes", File.ReadAllText(Path.Combine(history, "old-1")));
        Assert.False(File.Exists(ownedCopy)); Assert.True(File.Exists(otherCopy)); Assert.True(File.Exists(library.AudioPath(active.Id)));
        Assert.DoesNotContain("isLocallyPurged", before); Assert.DoesNotContain("purged", JsonSerializer.Serialize(deleted.SyncMetadata, SyncJson.Options), StringComparison.OrdinalIgnoreCase);
        library.DeletePermanently(deleted); SyncFileTransaction.Recover(test.Root); Assert.False(File.Exists(library.AudioPath(deleted.Id)));
    }
    [Fact] public void ThirtyDayBoundaryPurgesOnLoadAndRetainsTombstoneForSync()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var record = Add(library, true);
        var boundary = record.DeletedAt!.Value + LibraryStore.TrashRetention;
        Assert.False(library.Load(boundary.AddTicks(-1)).Single().IsLocallyPurged); Assert.True(File.Exists(library.AudioPath(record.Id)));
        var purged = library.Load(boundary).Single(); Assert.True(purged.IsLocallyPurged); Assert.False(File.Exists(library.AudioPath(record.Id)));
        Assert.Equal(JsonSerializer.Serialize(record.SyncMetadata, JsonDisk.Options), JsonSerializer.Serialize(purged.SyncMetadata, JsonDisk.Options));
    }
    [Fact] public void PurgeRedactsSharedEditInboxAndItsHistoryWithoutRemovingAnotherMeetingsEdits()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var deleted = Add(library, true); var keep = Add(library);
        var remove = new SyncEditEntry(1, new(Guid.NewGuid(), deleted.Id, 1, 1000, "speakerName", "s1", "삭제할 이름"));
        var retain = new SyncEditEntry(2, new(Guid.NewGuid(), keep.Id, 1, 1001, "speakerName", "s1", "남길 이름"));
        string inbox = Path.Combine(".sync", "workspaces", "fixture", "edits-inbox.json");
        string path = SyncFileTransaction.PathIn(test.Root, inbox); JsonDisk.Write(path, new[] { remove, retain });
        string staged = Path.Combine(test.Root, "stage.json"); JsonDisk.Write(staged, new[] { remove, retain });
        SyncFileTransaction.Commit(test.Root, SyncFileTransaction.Snapshot(test.Root, [inbox]), [new(inbox, staged)]);
        library.DeletePermanently(deleted);
        Assert.Equal(retain, JsonDisk.Read<List<SyncEditEntry>>(path)!.Single());
        string history = Directory.GetFiles(Path.Combine(test.Root, ".sync", "transactions"), "old-0", SearchOption.AllDirectories).Single();
        Assert.Equal(retain, JsonDisk.Read<List<SyncEditEntry>>(history)!.Single());
        SyncFileTransaction.Recover(test.Root); Assert.Equal(retain, JsonDisk.Read<List<SyncEditEntry>>(path)!.Single());
    }
    [Fact] public void RestoredOrReplacedRecordingRejectsAnOldDeleteConfirmation()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var record = Add(library, true);
        library.Save(record with { DeletedAt = null });
        Assert.Throws<InvalidOperationException>(() => library.DeletePermanently(record)); Assert.True(File.Exists(library.AudioPath(record.Id)));
        library.Save(record with { AudioVersion = 2 });
        Assert.Throws<InvalidOperationException>(() => library.DeletePermanently(record)); Assert.True(File.Exists(library.AudioPath(record.Id)));
    }
    [Fact] public void ExpiredInterruptedRecordingIsRecoveredThenPurgedUsingItsCurrentMetadata()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root);
        var record = new Recording { IsRecording = true, DeletedAt = DateTimeOffset.UtcNow.AddDays(-31) };
        TestFolder.Wave(library.AudioPath(record.Id)); library.Save(record);
        var recovered = library.Load().Single();
        Assert.False(recovered.IsRecording); Assert.True(recovered.IsLocallyPurged); Assert.Empty(library.LoadWarnings);
        Assert.False(File.Exists(library.AudioPath(record.Id))); Assert.NotNull(recovered.DeletedAt);
    }
    [Fact] public void InterruptedPurgeRetriesAtStartupWithoutRestampingOrAllowingPartialRestore()
    {
        using var test = new TestFolder(); var library = new LibraryStore(test.Root); var record = Add(library, true);
        string meta = Path.Combine(library.DirectoryFor(record.Id), "meta.json"), before = File.ReadAllText(meta);
        using (var held = new FileStream(library.AudioPath(record.Id), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            Assert.Throws<IOException>(() => library.DeletePermanently(record));
            Assert.Throws<InvalidOperationException>(() => library.Save(record with { DeletedAt = null }));
            Assert.False(library.Load().Single().IsLocallyPurged); Assert.Single(library.LoadWarnings);
        }
        var restarted = new LibraryStore(test.Root); Assert.True(restarted.Load().Single().IsLocallyPurged);
        Assert.Empty(restarted.LoadWarnings); Assert.Equal(before, File.ReadAllText(meta));
    }
    [Fact] public void LinkedChildIsRejectedBeforeAnyDeletionAndOutsideFilesStayUntouched()
    {
        using var test = new TestFolder(); using var outside = new TestFolder();
        var library = new LibraryStore(test.Root); var record = Add(library, true);
        string linked = Path.Combine(library.DirectoryFor(record.Id), "linked"); File.WriteAllText(Path.Combine(outside.Root, "keep.txt"), "keep");
        // Directory symlinks require Developer Mode or administrator privileges; junctions do not.
        var start = new System.Diagnostics.ProcessStartInfo("cmd.exe") { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("/c"); start.ArgumentList.Add("mklink"); start.ArgumentList.Add("/J"); start.ArgumentList.Add(linked); start.ArgumentList.Add(outside.Root);
        using var process = System.Diagnostics.Process.Start(start)!; process.WaitForExit(); Assert.Equal(0, process.ExitCode);
        try
        {
            Assert.Throws<InvalidDataException>(() => library.DeletePermanently(record));
            Assert.True(File.Exists(library.AudioPath(record.Id))); Assert.Equal("keep", File.ReadAllText(Path.Combine(outside.Root, "keep.txt")));
            Assert.False(File.Exists(library.PurgeMarkerPath(record.Id)));
        }
        finally { Directory.Delete(linked); } // Remove the verified fixture junction itself, never its target.
    }
    [Fact] public async Task ExportPreservesBytesAndExistingDestinationOnCancellationOrInvalidSelection()
    {
        using var test = new TestFolder(); var library = new LibraryStore(Path.Combine(test.Root, "library")); var record = Add(library);
        string destination = Path.Combine(test.Root, "내 회의.wav"); File.WriteAllText(destination, "previous export");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => library.ExportAudioAsync(record, destination, cancelled.Token));
        Assert.Equal("previous export", File.ReadAllText(destination));
        using (var locked = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var error = await Record.ExceptionAsync(() => library.ExportAudioAsync(record, destination));
            Assert.True(error is IOException or UnauthorizedAccessException, $"Expected a locked destination failure, got {error}");
        }
        Assert.Equal("previous export", File.ReadAllText(destination)); Assert.Empty(Directory.GetFiles(test.Root, "*.export-part"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => library.ExportAudioAsync(record, library.AudioPath(record.Id)));
        await library.ExportAudioAsync(record, destination); Assert.Equal(File.ReadAllBytes(library.AudioPath(record.Id)), File.ReadAllBytes(destination));
        string before = SyncFileTransaction.Revision(destination)!;
        library.Save(record with { AudioVersion = 2 });
        await Assert.ThrowsAsync<InvalidOperationException>(() => library.ExportAudioAsync(record, destination));
        Assert.Equal(before, SyncFileTransaction.Revision(destination)); Assert.Empty(Directory.GetFiles(test.Root, "*.export-part"));
    }
}
