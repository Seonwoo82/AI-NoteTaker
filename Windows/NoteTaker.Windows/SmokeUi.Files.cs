using System.IO;
using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static partial class SmokeUi
{
    private static async Task VerifyLibraryFilesAsync(string output)
    {
        var library = new LibraryStore(Path.Combine(output, "files-" + Guid.NewGuid().ToString("N")));
        var record = new Recording { Title = "영구 삭제와 오디오 내보내기", DurationSeconds = 42 };
        library.Save(record); CreateFixtureAudio(library.AudioPath(record.Id));
        var keep = new Recording { Title = "남겨 둘 녹음", DurationSeconds = 42 }; library.Save(keep); CreateFixtureAudio(library.AudioPath(keep.Id));
        string audioHash = SyncFileTransaction.Revision(library.AudioPath(record.Id))!;
        string destination = Path.Combine(output, $"exported-{record.Id:D}.wav");
        var window = Open();
        try
        {
            window.ReloadLibrary(record.Id); await window.WaveformLoadTask;
            ((WaveformControl)window.FindName("PlaybackSlider")).RequestSeek(20);
            window.AudioExportDestination = _ => null;
            Click("ExportAudioButton"); await window.LastLibraryAction;
            if (File.Exists(destination)) throw new InvalidOperationException("Cancelled picker wrote an export.");
            window.AudioExportDestination = _ => destination;
            Click("ExportAudioButton"); await window.LastLibraryAction;
            if (window.LastWorkError is not null || SyncFileTransaction.Revision(destination) != audioHash) throw new InvalidOperationException("WPF audio export changed stored WAV bytes.", window.LastWorkError);
            Click("DeleteButton"); ((ListBox)window.FindName("FilterBox")).SelectedIndex = 2;
            await window.WaveformLoadTask;
            await Confirm(false, Path.Combine(output, "permanent-delete-confirm.png"));
            if (SyncFileTransaction.Revision(library.AudioPath(record.Id)) != audioHash) throw new InvalidOperationException("Cancelled permanent deletion changed the audio.");
            await Confirm(true, before: () => library.Save(library.Load().Single(r => r.Id == record.Id) with { DeletedAt = null }));
            if (window.LastWorkError is not InvalidOperationException || !File.Exists(library.AudioPath(record.Id))) throw new InvalidOperationException("Stale delete confirmation removed a restored recording.");
            ((ListBox)window.FindName("FilterBox")).SelectedIndex = 0; window.ReloadLibrary(record.Id);
            Click("DeleteButton"); ((ListBox)window.FindName("FilterBox")).SelectedIndex = 2; await window.WaveformLoadTask;
            ((WaveformControl)window.FindName("PlaybackSlider")).RequestSeek(20);
            await CaptureAsync(window, Path.Combine(output, "trash.png"));
            await Confirm(true);
            if (window.LastWorkError is not null || File.Exists(library.AudioPath(record.Id)) || !library.Load().Single(r => r.Id == record.Id).IsLocallyPurged)
                throw new InvalidOperationException("WPF permanent deletion failed.", window.LastWorkError);
            if (((ListBox)window.FindName("RecordingList")).Items.Count != 0 || ((TextBlock)window.FindName("DeletedCount")).Text != "0") throw new InvalidOperationException("Purged tombstone remains visible in trash.");
            if (!File.Exists(library.AudioPath(keep.Id)) || SyncFileTransaction.Revision(destination) != audioHash) throw new InvalidOperationException("Deletion affected another recording or exported file.");
        }
        finally { await Close(window); }
        window = Open();
        try
        {
            ((ListBox)window.FindName("FilterBox")).SelectedIndex = 2;
            if (((ListBox)window.FindName("RecordingList")).Items.Count != 0) throw new InvalidOperationException("Purged tombstone reappeared after restart.");
        }
        finally { await Close(window); }
        JsonDisk.Write(Path.Combine(output, "library-files.json"), new { Passed = true, Library = library.Root, AudioHash = audioHash, Export = destination,
            Evidence = "Native WPF confirmation/cancel/stale restore, opened audio reader release, hidden tombstone after restart. Export button uses injected destination picker; native OS Save dialog not automated. Only generated fixture audio." });

        MainWindow Open()
        {
            var value = new MainWindow(library, discoverDevices: false, enableDesktopIntegration: false)
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
            value.Show(); return value;
        }
        void Click(string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        async Task Confirm(bool confirm, string? capture = null, Action? before = null)
        {
            Task? fill = null;
            var dispatch = window.Dispatcher.InvokeAsync(() => fill = FillAsync());
            async Task FillAsync()
            {
                var dialog = Application.Current.Windows.OfType<PermanentDeleteWindow>().Single();
                try
                {
                    if (capture is not null) await CaptureAsync(dialog, capture);
                    before?.Invoke();
                    (confirm ? dialog.ConfirmButton : dialog.CancelButton).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                }
                finally { if (dialog.IsVisible) dialog.Close(); }
            }
            Click("PermanentDeleteButton"); await dispatch; if (fill is not null) await fill;
            await window.LastLibraryAction;
        }
        static async Task Close(MainWindow value)
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            value.Closed += (_, _) => closed.TrySetResult(); value.RequestExit(); await closed.Task;
        }
    }
}
