using System.Security.Cryptography;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class RecordingFolderTests
{
    [Fact] public void DeletingAFolderPreservesRecordingAudioAndDocumentsAcrossRestart()
    {
        using var root = new TestFolder(); var library = new LibraryStore(root.Root); var folders = new RecordingFolderStore(root.Root);
        var folder = folders.Create("프로젝트 가"); var record = new Recording { Title = "회의" }; library.Save(record);
        TestFolder.Wave(library.AudioPath(record.Id)); File.WriteAllText(library.NotesPath(record.Id), "preserve notes");
        var before = SHA256.HashData(File.ReadAllBytes(library.AudioPath(record.Id)));
        folders.MoveRecording(library, record, folder.Id); folders.Delete(folder.Id);
        var reopened = new RecordingFolderStore(root.Root);
        Assert.Empty(reopened.Active); Assert.NotNull(Assert.Single(reopened.All).DeletedAt);
        var persisted = Assert.Single(library.Load()); Assert.Null(persisted.DeletedAt); Assert.False(reopened.IsActive(persisted.FolderId));
        Assert.Equal(before, SHA256.HashData(File.ReadAllBytes(library.AudioPath(record.Id))));
        Assert.Equal("preserve notes", File.ReadAllText(library.NotesPath(record.Id)));
        reopened.MoveRecording(library, persisted, null); Assert.Null(Assert.Single(library.Load()).FolderId);
    }
    [Fact] public void OrderRenameAndTombstonesPersistWithoutReusingDeletedIds()
    {
        using var root = new TestFolder(); var folders = new RecordingFolderStore(root.Root);
        var first = folders.Create("첫째"); var second = folders.Create("둘째"); var third = folders.Create("셋째");
        folders.Move(third.Id, first.Id); folders.Rename(first.Id, "수정한 폴더"); folders.Delete(second.Id);
        var reopened = new RecordingFolderStore(root.Root);
        Assert.Equal(new[] { third.Id, first.Id }, reopened.Active.Select(x => x.Id));
        Assert.Equal("수정한 폴더", reopened.Active[1].Name);
        var replacement = reopened.Create("둘째"); Assert.NotEqual(second.Id, replacement.Id);
        Assert.Equal(new[] { third.Id, first.Id, replacement.Id }, reopened.Active.Select(x => x.Id));
    }
    [Fact] public void CorruptedFolderFileCannotBeOverwrittenByAnEmptyLibrary()
    {
        using var root = new TestFolder(); var path = Path.Combine(root.Root, "recording-folders.json"); File.WriteAllText(path, "{broken");
        var folders = new RecordingFolderStore(root.Root); Assert.NotNull(folders.LoadError);
        Assert.Throws<InvalidDataException>(() => folders.Create("새 폴더")); Assert.Equal("{broken", File.ReadAllText(path));
    }
    [Fact] public void DuplicateInvalidAndDeletedDestinationsDoNotMutateMetadata()
    {
        using var root = new TestFolder(); var library = new LibraryStore(root.Root); var folders = new RecordingFolderStore(root.Root);
        var folder = folders.Create("Alpha"); var record = new Recording(); library.Save(record);
        Assert.Throws<InvalidOperationException>(() => folders.Create(" alpha "));
        Assert.Throws<ArgumentException>(() => folders.Rename(folder.Id, " "));
        folders.Delete(folder.Id);
        Assert.Throws<InvalidOperationException>(() => folders.MoveRecording(library, record, folder.Id)); Assert.Null(library.Load().Single().FolderId);
    }
    [Fact] public void RemoteConflictOrderPreservesRanksWhenOlderClientOmitsThem()
    {
        using var root = new TestFolder(); var folders = new RecordingFolderStore(root.Root); var original = folders.Create("원본");
        folders.ApplyRemote(original with { Name = "낡은 이름", ModifiedAt = original.ModifiedAt - 1 }); Assert.Equal("원본", folders.Active[0].Name);
        folders.ApplyRemote(original with { Name = "다른 기기", ModifiedAt = original.ModifiedAt + 10, SortOrder = null });
        Assert.Equal("다른 기기", folders.Active[0].Name); Assert.Equal(original.SortOrder, folders.Active[0].SortOrder);
        folders.Rename(original.Id, "수동 수정"); Assert.True(folders.Active[0].ModifiedAt > original.ModifiedAt + 10);
    }
}
