using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using NAudio.Wave;
using NoteTaker.Core;

namespace NoteTaker.Windows;

internal static class SmokeDesktop
{
    public static async Task RunCaptureFlowAsync(string output, string fixture, string modelRoot)
    {
        Directory.CreateDirectory(output);
        foreach (var scenario in new[] { "off", "missing-key", "local-ai", "exit-during-capture" })
        {
            var library = new LibraryStore(Path.Combine(output, scenario + "-" + Guid.NewGuid().ToString("N")));
            var settings = new AppSettings { AutoGenerate = scenario != "off", KeepRunningInTray = true };
            if (scenario == "missing-key") settings = settings with { TranscriptionProvider = "openrouter", SummaryProvider = "openrouter" };
            new SettingsStore(library.Root).Save(settings);
            var capture = new FileCapture(fixture, library, scenario == "missing-key");
            var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, recordingFactory: () => capture)
                { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            window.Closed += (_, _) => closed.TrySetResult();
            void Click(string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            try
            {
                window.Show();
                if (window.Desktop?.IsAvailable != true) throw new InvalidOperationException("Tray required for capture lifecycle test.");
                var mic = (ComboBox)window.FindName("MicrophoneBox"); mic.ItemsSource = new[] { new AudioDevice("fixture", "합성 파일 입력") }; mic.SelectedIndex = 0;
                ((ComboBox)window.FindName("ModeBox")).SelectedIndex = 1;
                window.CreateNamedFolder("자동 생성 검증");
                var folder = (TreeViewItem)((TreeView)window.FindName("FolderTree")).Items[0]; folder.IsSelected = true;
                var folderId = ((RecordingCollectionFolder)folder.Tag).Id;
                Click("RecordButton");
                if (!capture.Started || !((Button)window.FindName("StopButton")).IsEnabled) throw new InvalidOperationException("Capture start action failed.");
                Click("PauseButton"); if (!capture.IsPaused) throw new InvalidOperationException("Capture pause action failed.");
                Click("ResumeButton"); if (capture.IsPaused) throw new InvalidOperationException("Capture resume action failed.");
                window.Close();
                if (window.IsVisible || capture.Stopped || closed.Task.IsCompleted) throw new InvalidOperationException("Close-to-tray stopped the active capture.");
                if (scenario == "exit-during-capture") { window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15)); }
                else
                {
                    if (!window.HandleShortcut(System.Windows.Input.Key.Enter, System.Windows.Input.ModifierKeys.Control, null)) throw new InvalidOperationException("Finish recording shortcut failed.");
                    await window.LastStopButtonWork.WaitAsync(TimeSpan.FromMinutes(5));
                }
                var recording = library.Load().Single();
                if (!capture.Stopped || recording.IsRecording || recording.FolderId != folderId || recording.DurationSeconds <= 0) throw new InvalidOperationException("Completed capture metadata or folder was lost.");
                if (await MeetingNotesService.AudioHashAsync(fixture, default) != await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default)) throw new InvalidOperationException("Capture lifecycle changed fixture audio.");
                var notes = JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id));
                if (scenario is "off" or "exit-during-capture")
                {
                    if (notes is not null || File.Exists(library.TranscriptPath(recording.Id))) throw new InvalidOperationException("Automatic generation ran when disabled or during exit.");
                }
                else if (scenario == "missing-key")
                {
                    if (notes?.Markdown != "이전 회의록 유지" || window.LastWorkError is null) throw new InvalidOperationException("Automatic generation failure did not preserve the previous notes.");
                }
                else
                {
                    var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
                    if (window.LastWorkError is not null || transcript?.Complete != true || transcript.Provider != "whisper" || notes?.Model != "qwen3.5:4b" || notes.CostUsd != 0 || string.IsNullOrWhiteSpace(notes.Markdown))
                        throw new InvalidOperationException("Automatic local generation did not finish.", window.LastWorkError);
                }
                JsonDisk.Write(Path.Combine(output, scenario + ".json"), new { Passed = true, Scenario = scenario, Recording = recording, Notes = notes,
                    Scope = "Real WPF capture lifecycle and folder selection with file-backed synthetic capture. Local AI uses real Whisper/Ollama; no microphone recording." });
            }
            finally { if (!closed.Task.IsCompleted) { window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15)); } }
        }
    }

    private sealed class FileCapture(string fixture, LibraryStore library, bool previousNotes) : IRecordingSession
    {
        public bool Started { get; private set; }
        public bool Stopped { get; private set; }
        public string? Failure => null;
        public double DurationSeconds { get; private set; }
        public bool IsPaused { get; private set; }
        public float MicrophoneLevel => 0;
        public float SystemLevel => 0;
        public Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId)
        {
            File.Copy(fixture, path);
            using var reader = new WaveFileReader(path); DurationSeconds = reader.TotalTime.TotalSeconds;
            if (previousNotes)
            {
                var id = Guid.Parse(Path.GetFileName(Path.GetDirectoryName(path))!);
                JsonDisk.Write(library.NotesPath(id), new MeetingNotes("이전 회의록 유지", DateTimeOffset.UtcNow, "fixture", null));
            }
            Started = true; return Task.CompletedTask;
        }
        public void TogglePause() => IsPaused = !IsPaused;
        public Task<double> StopAsync() { Stopped = true; return Task.FromResult(DurationSeconds); }
        public ValueTask DisposeAsync() { Stopped = true; return ValueTask.CompletedTask; }
    }

    public static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        new SettingsStore(library.Root).Save(new AppSettings { EnableGlobalShortcuts = true, KeepRunningInTray = true });
        var window = new MainWindow(library, discoverDevices: false) { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) => closed.TrySetResult();
        try
        {
            window.Show();
            var desktop = window.Desktop ?? throw new InvalidOperationException("Native desktop integration did not initialize.");
            if (!desktop.IsAvailable) throw new InvalidOperationException("Windows Shell did not accept the notification icon.");
            if (desktop.RegisteredShortcutCount != 3) throw new InvalidOperationException(desktop.ShortcutWarning ?? "Not all global hotkeys were registered.");
            window.Close();
            if (window.IsVisible || closed.Task.IsCompleted || !desktop.IsAvailable) throw new InvalidOperationException("Close-to-tray did not keep the application alive.");
            // Dispatch the Windows message used by the registered Show shortcut; never record the user's microphone.
            SendMessage(desktop.Handle, 0x312, 0x6110, 0);
            if (!window.IsVisible) throw new InvalidOperationException("The global shortcut's HWND message did not restore the hidden window.");
            desktop.ConfigureShortcuts(false);
            if (desktop.RegisteredShortcutCount != 0) throw new InvalidOperationException("Disabling global shortcuts did not release registrations.");
            desktop.ConfigureShortcuts(true);
            if (desktop.RegisteredShortcutCount != 3) throw new InvalidOperationException("Global shortcuts could not be registered again.");
            window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15));
            if (desktop.IsAvailable || desktop.RegisteredShortcutCount != 0) throw new InvalidOperationException("Explicit exit retained native registrations.");
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, TrayShellRegistration = true, CloseHidesWithoutShutdown = true,
                ThreeGlobalKeysRegistered = true, ShowHotkeyWindowMessage = true, UnregisterAndReregister = true, ExplicitExitDisposesResources = true,
                Scope = "Native Windows Shell and HWND verification. No microphone capture or physical keyboard automation." });
        }
        finally { if (!closed.Task.IsCompleted) { window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(15)); } }
    }
    [DllImport("user32.dll")] private static extern nint SendMessage(nint window, int message, nint wParam, nint lParam);
}
