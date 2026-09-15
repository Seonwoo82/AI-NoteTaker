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
        var library = new LibraryStore(Path.Combine(output, new string('a', 80), "fixture-" + Guid.NewGuid().ToString("N")));
        var recording = new Recording { Title = "공유 동작 검증용 무음", DurationSeconds = 1 };
        Directory.CreateDirectory(library.DirectoryFor(recording.Id));
        using (var wave = new WaveFileWriter(library.AudioPath(recording.Id), new WaveFormat(16000, 16, 1))) wave.Write(new byte[32000]);
        library.Save(recording);
        var owner = new Window { Title = "AI-NoteTaker 공유 검증", Width = 360, Height = 200,
            Content = new System.Windows.Controls.TextBlock { Text = "생성한 무음 파일로 Windows 공유 기능을 확인합니다.\n받을 앱을 선택하거나 파일을 전송하지 않습니다.", Margin = new Thickness(24), TextWrapping = TextWrapping.Wrap },
            ShowInTaskbar = true, WindowStartupLocation = WindowStartupLocation.CenterScreen };
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
            owner.Activate(); await Dispatcher.Yield(DispatcherPriority.ApplicationIdle);
            JsonDisk.Write(Path.Combine(output, "prepared.json"), new { OwnerActive = owner.IsActive, SourcePathLength = library.AudioPath(recording.Id).Length, StoragePathLength = files[0].Path.Length });
            share.Show(package);
            await requested.Task.WaitAsync(TimeSpan.FromSeconds(15));
            await Dispatcher.Yield(DispatcherPriority.ContextIdle);
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, NativeDataRequested = true, FileCount = files.Count,
                FileName = files[0].Name, SourcePathLength = library.AudioPath(recording.Id).Length, StoragePathLength = files[0].Path.Length, AudioHash = SyncFileTransaction.Revision(files[0].Path),
                Scope = "Actual Windows share API requested the generated silent WAV package. Owner then closes. No destination app selected, no message sent, no user microphone or files, no rendering/delivery claim." });
        }
        finally
        {
            owner.Close(); share.Dispose();
            library.Save(library.Load().Single() with { DeletedAt = DateTimeOffset.UtcNow });
            library.DeletePermanently(library.Load().Single());
        }
    }
}
