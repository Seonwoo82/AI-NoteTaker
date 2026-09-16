using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class RecordingCompletionTests
{
    [Fact] public void EmptyCaptureIsNotCompletedOrReportedAsRecoveredAndOriginalRemains()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { IsRecording = true, DurationSeconds = 37 }; store.Save(record);
        TestFolder.Wave(store.AudioPath(record.Id), 0);
        var original = File.ReadAllBytes(store.AudioPath(record.Id));
        string metadata = File.ReadAllText(Path.Combine(store.DirectoryFor(record.Id), "meta.json"));
        Assert.Throws<InvalidDataException>(() => store.CompleteRecording(record, null));
        Assert.Equal(metadata, File.ReadAllText(Path.Combine(store.DirectoryFor(record.Id), "meta.json")));
        var recovered = Assert.Single(new LibraryStore(folder.Root).Load());
        Assert.False(recovered.IsRecording); Assert.Equal(0, recovered.DurationSeconds);
        Assert.Contains("복구하지 못했습니다", recovered.Warning);
        Assert.Equal(original, File.ReadAllBytes(store.AudioPath(record.Id)));
    }

    [Theory]
    [InlineData(0f)]
    [InlineData(.2f)]
    public void RealFramesDetermineSavedDurationAndValidSilenceIsPreserved(float amplitude)
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { IsRecording = true, DurationSeconds = 999 }; store.Save(record);
        TestFolder.Wave(store.AudioPath(record.Id), .125, amplitude);
        var original = File.ReadAllBytes(store.AudioPath(record.Id));
        var completed = store.CompleteRecording(record, "device stopped after partial recording");
        Assert.False(completed.IsRecording); Assert.Equal(.125, completed.DurationSeconds, 6);
        Assert.Equal("device stopped after partial recording", completed.Warning);
        Assert.Equal(.125, Assert.Single(new LibraryStore(folder.Root).Load()).DurationSeconds, 6);
        Assert.Equal(original, File.ReadAllBytes(store.AudioPath(record.Id)));
    }

    [Fact] public void MissingCaptureCannotRetainInventedElapsedDurationDuringRecovery()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { IsRecording = true, DurationSeconds = 42 }; store.Save(record);
        Assert.Throws<FileNotFoundException>(() => store.CompleteRecording(record, null));
        var recovered = Assert.Single(store.Load());
        Assert.Equal(0, recovered.DurationSeconds); Assert.Contains("찾을 수 없습니다", recovered.Warning);
    }

    [Fact] public void PartialFrameCannotBeSavedAsACompleteRecording()
    {
        using var folder = new TestFolder(); var store = new LibraryStore(folder.Root);
        var record = new Recording { IsRecording = true }; store.Save(record);
        using (var writer = new WaveFileWriter(store.AudioPath(record.Id), AudioFiles.RecordingFormat))
            writer.Write(new byte[5], 0, 5);
        var original = File.ReadAllBytes(store.AudioPath(record.Id));
        Assert.Throws<InvalidDataException>(() => store.CompleteRecording(record, null));
        Assert.Equal(original, File.ReadAllBytes(store.AudioPath(record.Id)));
    }
}
