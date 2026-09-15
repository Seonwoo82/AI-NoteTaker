using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokePlaybackGuards
{
    internal static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        var recording = new Recording { Title = "재생 보호 검증용 무음", DurationSeconds = 5 };
        library.Save(recording);
        using (var writer = new WaveFileWriter(library.AudioPath(recording.Id), new WaveFormat(16000, 16, 1))) writer.Write(new byte[160000]);
        string hash = SyncFileTransaction.Revision(library.AudioPath(recording.Id))!;
        new MeetingWorkspaceStore(library).Save(recording, new(recording.Id, 1, 0, Guid.NewGuid(), "", new(recording.Id, 1, "fixture",
            [new("owner", "나", true)], [new("turn1", .25, 1.75, "owner", "검증용 생성 문장"), new("turn2", 3, 4, "owner", "검증용 생성 문장 2")]), null, [], "fixture"), null);
        var window = new MainWindow(library, discoverDevices: false, enableDesktopIntegration: false)
            { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        window.Show(); window.ReloadLibrary(recording.Id);
        var turns = (ListBox)window.FindName("ParticipantTurns");
        var stop = (Button)window.FindName("StopTurnsButton");
        var play = (Button)window.FindName("PlayButton");
        var waveform = (WaveformControl)window.FindName("PlaybackSlider");
        void DoubleClick() => turns.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left) { RoutedEvent = Control.MouseDoubleClickEvent });
        try
        {
            ((TabControl)window.FindName("DetailPanel")).SelectedIndex = 2; turns.SelectedIndex = 0;
            ((Button)window.FindName("PlayOwnTurnsButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Require(stop.IsEnabled, "Own-turn playback did not start on the output device.");
            Task? inspection = null;
            var dispatch = window.Dispatcher.InvokeAsync(() => inspection = InspectProfile());
            async Task InspectProfile()
            {
                var dialog = window.OwnedWindows.OfType<ProfileWindow>().Single();
                try
                {
                    await Dispatcher.Yield(DispatcherPriority.Background);
                    Require(!stop.IsEnabled, "Opening profile did not stop own-turn playback.");
                    play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    Require(AutomationProperties.GetName(play) == "재생", "Queued regular playback started while profile was open.");
                    double position = waveform.Position;
                    ((Button)window.FindName("ForwardButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                    Require(waveform.Position == position, "Queued seek changed playback while profile was open.");
                    DoubleClick();
                    Require(!stop.IsEnabled, "Queued turn playback started while profile was open.");
                }
                finally { dialog.Close(); }
            }
            ((Button)window.FindName("ProfileButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await dispatch; if (inspection is not null) await inspection;
            int transitionRequests = 0; bool transitionStartedPlayback = false;
            var recordButton = (Button)window.FindName("RecordButton");
            void WhileTransitioning(object sender, DependencyPropertyChangedEventArgs change)
            {
                if (change.NewValue is not false) return;
                transitionRequests++; DoubleClick(); transitionStartedPlayback |= stop.IsEnabled;
            }
            recordButton.IsEnabledChanged += WhileTransitioning;
            try { recordButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }
            finally { recordButton.IsEnabledChanged -= WhileTransitioning; }
            Require(transitionRequests == 1 && !transitionStartedPlayback, "Turn playback started during recording transition.");
            Require(library.Load().Count == 1, "Missing-device fixture unexpectedly started recording.");
            ((Button)window.FindName("DeleteButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            ((ListBox)window.FindName("FilterBox")).SelectedIndex = 2; window.ReloadLibrary(recording.Id); turns.SelectedIndex = 0;
            Require(turns.Items.Count == 2, "Trash fixture did not retain its turns.");
            DoubleClick(); Require(!stop.IsEnabled, "Turn double-click played a deleted recording despite disabled playback controls.");
            Require(SyncFileTransaction.Revision(library.AudioPath(recording.Id)) == hash, "Playback guard changed source audio.");
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, OwnTurnPlaybackStarted = true, ProfileStopsPlayback = true, ModalRejectsQueuedPlayback = true, ModalRejectsRegularPlaybackAndSeek = true,
                RecordingTransitionRejectsPlayback = true, TrashRejectsDoubleClick = true, SourceUnchanged = true, Scope = "Real WPF profile dialog and routed turn events, generated silent WAV on the real output device. Missing input devices are injected. No enrollment start, microphone, surrounding audio, or human listening claim." });
        }
        finally
        {
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            window.Closed += (_, _) => closed.TrySetResult(); window.RequestExit(); await closed.Task.WaitAsync(TimeSpan.FromSeconds(10));
        }
        static void Require(bool value, string message) { if (!value) throw new InvalidOperationException(message); }
    }
}
