using System.Buffers.Binary;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static partial class SmokeUi
{
    private static async Task VerifyCapturePreferencesAsync(string output)
    {
        var library = new LibraryStore(Path.Combine(output, "capture-settings-" + Guid.NewGuid().ToString("N")));
        var capture = new GainCapture();
        MainWindow Open() => new(library, discoverDevices: false, enableDesktopIntegration: false, recordingFactory: () => capture)
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var window = Open(); window.Show();
        try
        {
            var mic = (ComboBox)window.FindName("MicrophoneBox"); mic.ItemsSource = new[] { new AudioDevice("fixture-mic", "생성 마이크 신호") }; mic.SelectedIndex = 0;
            var system = (ComboBox)window.FindName("OutputBox"); system.ItemsSource = new[] { new AudioDevice("fixture-system", "생성 시스템 신호") }; system.SelectedIndex = 0;
            var micGain = (Slider)window.FindName("MicrophoneGainSlider"); var systemGain = (Slider)window.FindName("SystemGainSlider");
            micGain.Value = .5; systemGain.Value = 1.5;
            Slider.IncreaseSmall.Execute(null, micGain);
            RequireCapture(Math.Abs(micGain.Value - .55) < .001 && Math.Abs(new CapturePreferencesStore(library.Root).Load().MicrophoneGain - .55f) < .001, "Slider keyboard command did not persist its step.");
            Slider.DecreaseSmall.Execute(null, micGain);
            var popupContent = (FrameworkElement)((Popup)window.FindName("CapturePopup")).Child;
            popupContent.Measure(new Size(320, 600)); popupContent.Arrange(new Rect(popupContent.DesiredSize)); popupContent.UpdateLayout();
            SaveImage(popupContent, Path.Combine(output, "capture-gains.png"));
            Appearance.Apply(true); popupContent.UpdateLayout(); SaveImage(popupContent, Path.Combine(output, "capture-gains-dark.png")); Appearance.Apply(false);
            ((Button)window.FindName("RecordButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            RequireCapture(capture.Started && capture.MicrophoneGain == .5f && capture.SystemGain == 1.5f, "UI gain did not reach the recording session.");
            RequireCapture(!micGain.IsEnabled && !systemGain.IsEnabled, "Capture levels remained editable during recording.");
            ((Button)window.FindName("StopButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await window.LastStopButtonWork;
            var record = library.Load().Single();
            using var audio = new WaveFileReader(library.AudioPath(record.Id)); byte[] samples = new byte[4]; audio.ReadExactly(samples);
            RequireCapture(BinaryPrimitives.ReadInt16LittleEndian(samples) == 2000 && BinaryPrimitives.ReadInt16LittleEndian(samples.AsSpan(2)) == 200, "Recorded PCM did not contain the configured source levels.");
            ((ComboBox)window.FindName("ModeBox")).SelectedIndex = 1;
            RequireCapture(micGain.IsEnabled && !systemGain.IsEnabled, "Microphone-only mode did not gate the system level.");
        }
        finally { await CloseCaptureWindow(window); }
        var restored = Open(); restored.Show();
        try
        {
            RequireCapture(((ComboBox)restored.FindName("ModeBox")).SelectedIndex == 1 && ((Slider)restored.FindName("MicrophoneGainSlider")).Value == .5 && ((Slider)restored.FindName("SystemGainSlider")).Value == 1.5, "Restart lost capture preferences.");
            var saved = new CapturePreferencesStore(library.Root).Load();
            RequireCapture(saved.MicrophoneId == "fixture-mic" && saved.OutputId == "fixture-system", "Local device selection did not persist.");
            JsonDisk.Write(Path.Combine(output, "capture-preferences.json"), new { Passed = true, saved.Mode, saved.MicrophoneGain, saved.SystemGain, RestartPreserved = true, RecordingControlsLocked = true,
                Scope = "Actual WPF capture controls, record/stop flow and production PCM mixer with generated source samples. File-backed input replaces WASAPI; no microphone or surrounding audio." });
        }
        finally { await CloseCaptureWindow(restored); }
        static void RequireCapture(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        static async Task CloseCaptureWindow(MainWindow target)
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); target.Closed += (_, _) => closed.TrySetResult(); target.RequestExit(); await closed.Task;
        }
    }
    private sealed class GainCapture : IRecordingSession, IConfigurableRecordingSession
    {
        public bool Started { get; private set; }
        public float MicrophoneGain { get; private set; }
        public float SystemGain { get; private set; }
        public string? Failure => null;
        public double DurationSeconds => Started ? 1 : 0;
        public bool IsPaused { get; private set; }
        public float MicrophoneLevel => 0;
        public float SystemLevel => 0;
        public void ConfigureGains(float microphoneGain, float systemGain) { MicrophoneGain = microphoneGain; SystemGain = systemGain; }
        public Task StartAsync(string path, RecordingMode mode, string? microphoneId, string? outputId)
        {
            byte[] mic = new byte[4], system = new byte[4], mixed = new byte[4];
            BinaryPrimitives.WriteInt16LittleEndian(mic, 3200); BinaryPrimitives.WriteInt16LittleEndian(mic.AsSpan(2), -6400);
            BinaryPrimitives.WriteInt16LittleEndian(system, 1600); BinaryPrimitives.WriteInt16LittleEndian(system.AsSpan(2), 2400);
            PcmMixer.Mix([mic, system], mixed, 4, [MicrophoneGain, SystemGain]);
            using var writer = new WaveFileWriter(path, AudioFiles.RecordingFormat);
            for (int i = 0; i < AudioFiles.SampleRate; i++) writer.Write(mixed, 0, 4);
            Started = true; return Task.CompletedTask;
        }
        public void TogglePause() => IsPaused = !IsPaused;
        public Task<double> StopAsync() => Task.FromResult(DurationSeconds);
        public ValueTask DisposeAsync() => ValueTask.CompletedTask;
    }
}
