using System.IO;
using System.Windows;
using System.Windows.Threading;
using NoteTaker.Core;
using NAudio.Wave;

namespace NoteTaker.Windows;

internal static class SmokeAudioShare
{
    internal static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        var recording = new Recording { Title = "공유 동작 검증용 무음", DurationSeconds = 1 };
        Directory.CreateDirectory(library.DirectoryFor(recording.Id));
        using (var wave = new WaveFileWriter(library.AudioPath(recording.Id), new WaveFormat(16000, 16, 1))) wave.Write(new byte[32000]);
        library.Save(recording);
        var owner = new Window { Title = "AI-NoteTaker 공유 검증", Width = 300, Height = 200, Left = -20000, Top = -20000,
            ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual };
        owner.Show();
        using var share = new WindowsAudioShare(owner);
        var requested = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        share.DataRequested += () => requested.TrySetResult();
        try
        {
            var package = await WindowsAudioShare.PrepareAsync(library, library.Load().Single(), default);
            var files = await package.GetView().GetStorageItemsAsync();
            if (files.Count != 1 || SyncFileTransaction.Revision(files[0].Path) != SyncFileTransaction.Revision(library.AudioPath(recording.Id)))
                throw new InvalidOperationException("Share package changed the audio.");
            share.Show(package);
            await requested.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, NativeDataRequested = true, FileCount = files.Count,
                FileName = files[0].Name, AudioHash = SyncFileTransaction.Revision(files[0].Path),
                Scope = "Actual Windows share API requested the generated silent WAV package. Owner then closes. No destination app selected, no message sent, no user microphone or files, no rendering/delivery claim." });
        }
        finally { owner.Close(); }
    }
}
