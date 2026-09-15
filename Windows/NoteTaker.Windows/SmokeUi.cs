using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using NoteTaker.Core;
using NoteTaker.Windows.Components;
using NAudio.Wave;

namespace NoteTaker.Windows;

internal static class SmokeUi
{
    public static async Task RunAiAsync(string output, string sample, string modelRoot, string provider)
    {
        Directory.CreateDirectory(output);
        Appearance.Apply(false);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        new SettingsStore(library.Root).Save(new AppSettings { TranscriptionProvider = provider });
        var recording = await library.ImportAsync(sample);
        recording = recording with { Title = "무료 AI · 한국어 합성 회의 검증" }; library.Save(recording);
        var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, enableDesktopIntegration: false)
        { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        window.Show(); window.ReloadLibrary(recording.Id);
        try
        {
            var detail = (TabControl)window.FindName("DetailPanel"); detail.SelectedIndex = 1;
            ((Button)window.FindName("TranscribeOnlyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await window.CurrentWork;
            var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
            if (transcript?.Complete != true || transcript.Provider != provider || File.Exists(library.NotesPath(recording.Id)))
                throw new InvalidOperationException("WPF transcription failed: " + ((TextBlock)window.FindName("StatusText")).Text, window.LastWorkError);
            ((TabControl)window.FindName("DocumentTabs")).SelectedIndex = 1;
            await CaptureAsync(window, Path.Combine(output, "transcript.png"));
            string transcriptHash = await MeetingNotesService.AudioHashAsync(library.TranscriptPath(recording.Id), default);
            ((Button)window.FindName("SummarizeOnlyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await window.CurrentWork;
            var notes = JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id));
            if (notes?.Model != "qwen3.5:4b" || string.IsNullOrWhiteSpace(notes.Markdown) || notes.CostUsd != 0)
                throw new InvalidOperationException("WPF local summary failed: " + ((TextBlock)window.FindName("StatusText")).Text, window.LastWorkError);
            if (transcriptHash != await MeetingNotesService.AudioHashAsync(library.TranscriptPath(recording.Id), default))
                throw new InvalidOperationException("Summary modified the transcript.");
            ((TabControl)window.FindName("DocumentTabs")).SelectedIndex = 0;
            await CaptureAsync(window, Path.Combine(output, "notes.png"));
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, Provider = provider, Transcript = transcript, Notes = notes, Library = library.Root });
        }
        finally { window.Close(); }
    }
    public static async Task RunAsync(string output)
    {
        Directory.CreateDirectory(output);
        Appearance.Apply(false);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        var window = new MainWindow(library, discoverDevices: false, enableDesktopIntegration: false) { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        window.Show();
        await CaptureAsync(window, Path.Combine(output, "empty.png"));
        var recording = new Recording { Title = "주간 제품 회의", Mode = RecordingMode.Mixed, DurationSeconds = 42, IsFavorite = true };
        library.Save(recording);
        CreateFixtureAudio(library.AudioPath(recording.Id));
        JsonDisk.Write(library.NotesPath(recording.Id), new MeetingNotes("# 다음 출시를 위한 제품 점검\n\n온보딩 경험과 Windows 녹음 흐름을 확인하고, 다음 주까지 진행할 작업을 정리했습니다.\n\n## 녹음 경험 개선\n\n마이크와 시스템 소리를 함께 저장하고, 회의가 끝난 뒤 주요 논의와 할 일을 한 화면에서 확인합니다.\n\n## 다음 할 일\n\n- [ ] 장치 전환 상황 검증 · 담당자 미정\n- [ ] 긴 회의 전사 결과 검토 · 다음 회의에서 확인\n\n## 열린 질문\n\n클라우드 동기화의 Windows 지원 일정은 아직 정해지지 않았습니다.", DateTimeOffset.Now, "미리보기 예시", null));
        JsonDisk.Write(library.TranscriptPath(recording.Id), new TranscriptCache("fixture", "fixture", "ko", ["이번 회의에서는 Windows 녹음 흐름을 살펴보겠습니다. 마이크와 시스템 소리가 함께 저장되는지 확인하고, 다음 주에는 긴 회의 전사 결과를 검토합시다."], true));
        window.ReloadLibrary(recording.Id);
        // Exercise the real WPF event wiring using the isolated fixture library.
        var favorite = (Button)window.FindName("FavoriteButton");
        favorite.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (library.Load().Single().IsFavorite) throw new InvalidOperationException("Favorite action was not saved.");
        favorite.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var delete = (Button)window.FindName("DeleteButton");
        delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (library.Load().Single().DeletedAt is null) throw new InvalidOperationException("Delete action was not saved.");
        var filter = (ListBox)window.FindName("FilterBox");
        filter.SelectedIndex = 2;
        delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (library.Load().Single().DeletedAt is not null) throw new InvalidOperationException("Restore action was not saved.");
        filter.SelectedIndex = 0;
        var search = (TextBox)window.FindName("SearchBox");
        search.Text = "no fixture matches this";
        if (((ListBox)window.FindName("RecordingList")).Items.Count != 0) throw new InvalidOperationException("Search filter failed.");
        search.Clear();
        await window.WaveformLoadTask;
        var waveform = (WaveformControl)window.FindName("PlaybackSlider");
        if (waveform.Peaks.Length == 0) throw new InvalidOperationException("Real audio waveform was not loaded.");
        waveform.RequestSeek(20);
        ((Button)window.FindName("BackButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (Math.Abs(waveform.Position - 5) > .01) throw new InvalidOperationException("Back 15 seconds failed.");
        ((Button)window.FindName("ForwardButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (Math.Abs(waveform.Position - 20) > .01) throw new InvalidOperationException("Forward 15 seconds failed.");
        ((WaveformControl)window.FindName("OverviewWaveform")).RequestSeek(0);
        if (waveform.Position != 0) throw new InvalidOperationException("Overview waveform seek failed.");
        await CaptureAsync(window, Path.Combine(output, "playback.png"));
        await VerifyFoldersAsync(window, library, waveform, output);
        await VerifyFocusedWaveformAsync(output);
        var detail = (TabControl)window.FindName("DetailPanel");
        detail.SelectedIndex = 1;
        var tabs = (TabControl)window.FindName("DocumentTabs");
        tabs.SelectedIndex = 1;
        if (!((TextBox)window.FindName("TranscriptBox")).Text.Contains("Windows")) throw new InvalidOperationException("Transcript tab failed.");
        tabs.SelectedIndex = 0;
        await CaptureAsync(window, Path.Combine(output, "meeting.png"));
        window.Width = 840; window.Height = 600;
        await CaptureAsync(window, Path.Combine(output, "compact.png"));
        detail.SelectedIndex = 0;
        await CaptureAsync(window, Path.Combine(output, "compact-playback.png"));
        window.Width = 1100; window.Height = 760;
        Appearance.Apply(true);
        await CaptureAsync(window, Path.Combine(output, "dark.png"));
        detail.SelectedIndex = 1;
        await CaptureAsync(window, Path.Combine(output, "dark-notes.png"));
        Appearance.Apply(false);
        // Recording UI fixture only: no microphone or device is opened here.
        detail.Visibility = Visibility.Collapsed;
        var recordingPanel = (Grid)window.FindName("RecordingPanel");
        recordingPanel.Visibility = Visibility.Visible;
        ((Button)window.FindName("RecordButton")).IsEnabled = false;
        ((Button)window.FindName("RecordOptionsButton")).IsEnabled = false;
        ((Button)window.FindName("PauseButton")).IsEnabled = true;
        ((Button)window.FindName("StopButton")).IsEnabled = true;
        ((TextBlock)window.FindName("RecordingClock")).Text = "03:24";
        ((ProgressBar)window.FindName("MicMeter")).Value = .62;
        ((ProgressBar)window.FindName("SystemMeter")).Value = .35;
        ((TextBlock)window.FindName("MicSignal")).Text = "입력 감지됨";
        ((TextBlock)window.FindName("SystemSignal")).Text = "입력 감지됨";
        await CaptureAsync(window, Path.Combine(output, "recording.png"));
        recordingPanel.Visibility = Visibility.Collapsed;
        detail.Visibility = Visibility.Visible;
        detail.SelectedIndex = 0;
        detail.SelectedIndex = 1;
        var mic = (ComboBox)window.FindName("MicrophoneBox");
        var speaker = (ComboBox)window.FindName("OutputBox");
        mic.ItemsSource = new[] { new AudioDevice("fixture-mic", "기본 마이크") }; mic.SelectedIndex = 0;
        speaker.ItemsSource = new[] { new AudioDevice("fixture-output", "기본 스피커") }; speaker.SelectedIndex = 0;
        var mode = (ComboBox)window.FindName("ModeBox");
        mode.SelectedIndex = 1;
        if (speaker.IsEnabled) throw new InvalidOperationException("Microphone-only mode must disable output selection.");
        mode.SelectedIndex = 2;
        if (mic.IsEnabled) throw new InvalidOperationException("System-only mode must disable microphone selection.");
        mode.SelectedIndex = 0;
        var popupContent = (FrameworkElement)((Popup)window.FindName("CapturePopup")).Child;
        popupContent.Measure(new Size(320, 600)); popupContent.Arrange(new Rect(popupContent.DesiredSize)); popupContent.UpdateLayout();
        SaveImage(popupContent, Path.Combine(output, "capture-settings.png"));
        var settings = new SettingsWindow(new AppSettings()) { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        settings.Show();
        await CaptureAsync(settings, Path.Combine(output, "settings.png"));
        ((ComboBox)settings.FindName("TranscriptionProviderBox")).SelectedIndex = 2;
        await CaptureAsync(settings, Path.Combine(output, "qwen-settings.png"));
        ((ComboBox)settings.FindName("TranscriptionProviderBox")).SelectedIndex = 1;
        ((ComboBox)settings.FindName("SummaryProviderBox")).SelectedIndex = 1;
        await CaptureAsync(settings, Path.Combine(output, "cloud-settings.png"));
        Appearance.Apply(true);
        await CaptureAsync(settings, Path.Combine(output, "dark-settings.png"));
        Appearance.Apply(false);
        settings.Close();
        ((Button)window.FindName("TranscribeOnlyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await window.CurrentWork;
        if (window.LastWorkError is not InvalidDataException || !((TextBlock)window.FindName("StatusText")).Text.Contains("모델"))
            throw new InvalidOperationException("Missing model did not show the setup guidance.");
        var import = new TranscriptImportWindow("클로바노트 전사문 · 미리보기 검증") { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        import.Show();
        ((TextBox)import.FindName("PreviewBox")).Text = "참석자 1 00:00\n금요일까지 검토하겠습니다.\n\n참석자 2 00:03\n광고 예산은 다음 회의에서 결정하겠습니다.";
        await CaptureAsync(import, Path.Combine(output, "transcript-import.png"));
        import.Close();
        var connect = new TranscriptImportWindow("격리된 전사문 연결 검증") { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        _ = connect.Dispatcher.BeginInvoke(() =>
        {
            ((TextBox)connect.FindName("PreviewBox")).Text = "담당자 김민수 · 금요일까지 검토합니다.";
            ((Button)connect.FindName("ConnectTranscriptButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        });
        if (connect.ShowDialog() != true || connect.Result is null) throw new InvalidOperationException("Transcript preview confirmation failed.");
        string oldNotes = File.ReadAllText(library.NotesPath(recording.Id));
        await TranscriptImport.SaveAsync(library, recording, connect.Result, default);
        if (JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id))?.Source != "import" || oldNotes != File.ReadAllText(library.NotesPath(recording.Id)))
            throw new InvalidOperationException("Transcript connection did not preserve the existing notes.");
        var closed = new TaskCompletionSource();
        window.Closed += (_, _) => closed.TrySetResult();
        window.Close();
        await closed.Task;
        if (Environment.GetEnvironmentVariable("NOTETAKER_UI_AUDIO_SMOKE") == "1") await RunRecordingControlsAsync(output);
        File.WriteAllText(Path.Combine(output, "result.txt"), "PASS: Apple-style empty, playback, notes, recording, compact, capture popover and light/dark settings rendered. Favorite, delete, restore, search, actual audio waveform, focused 5-minute timeline and stable drag mapping, folder create/move/order/delete preserving audio and playhead, submenu, input mode gating, transcript tab and graceful close passed. Generated audio fixture only; no recording or network used.");
    }

    private static async Task VerifyFocusedWaveformAsync(string output)
    {
        var focused = new WaveformControl { Height = 170, Duration = 7200, Position = 3600, Peaks = Enumerable.Range(0, 7200).Select(i => (float)(.1 + .7 * Math.Abs(Math.Sin(i * .13)))).ToArray() };
        focused.BeginScrub(); focused.RequestSeekAtFraction(.25);
        if (focused.Position != 3525) throw new InvalidOperationException("Focused pointer did not map to the absolute audio time.");
        focused.RequestSeekAtFraction(.25);
        if (focused.Position != 3525 || focused.Viewport.Start != 3450) throw new InvalidOperationException("Dragging moved the time interval under the pointer.");
        focused.EndScrub(); focused.Position = 3600;
        var overview = new WaveformControl { Height = 30, IsOverview = true, Duration = 7200, Position = 3600, Peaks = focused.Peaks };
        overview.RequestSeekAtFraction(.75);
        if (overview.Position != 5400) throw new InvalidOperationException("Overview must retain whole-recording pointer mapping.");
        overview.Position = 3600;
        var panel = new StackPanel { Margin = new Thickness(28) };
        panel.SetResourceReference(Panel.BackgroundProperty, "WindowSurface");
        panel.Children.Add(new TextBlock { Text = "2시간 녹음 · 1:00:00 주변 5분", Margin = new Thickness(0, 0, 0, 24), FontSize = 17 });
        panel.Children.Add(focused); panel.Children.Add(overview);
        var window = new Window { Content = panel, Width = 760, Height = 360, Left = -20000, Top = -20000, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual };
        window.Show(); await CaptureAsync(window, Path.Combine(output, "focused-waveform.png")); window.Close();
    }

    private static async Task VerifyFoldersAsync(MainWindow window, LibraryStore library, WaveformControl waveform, string output)
    {
        waveform.RequestSeek(20);
        var originalId = ((Recording)((ListBox)window.FindName("RecordingList")).SelectedItem).Id;
        string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(originalId), default);
        window.CreateNamedFolder("제품 개발"); window.CreateNamedFolder("고객 미팅");
        if (waveform.Position != 20 || ((Recording)((ListBox)window.FindName("RecordingList")).SelectedItem).Id != originalId)
            throw new InvalidOperationException("Folder creation cleared the selected recording or playback position.");
        var folders = new RecordingFolderStore(library.Root); var first = folders.Active[0];
        window.MoveSelectedToFolder(first.Id);
        if (library.Load().Single().FolderId != first.Id || waveform.Position != 20) throw new InvalidOperationException("Folder assignment was not saved or reset playback.");
        var tree = (TreeView)window.FindName("FolderTree");
        var node = (TreeViewItem)tree.Items[0]; node.IsExpanded = true;
        if (!File.ReadAllText(Path.Combine(library.Root, "folder-appearance.json")).Contains(first.Id.ToString())) throw new InvalidOperationException("Folder expansion was not saved.");
        var search = (TextBox)window.FindName("SearchBox"); search.Text = "no matching recording";
        ((TreeViewItem)node.Items[0]).IsSelected = true;
        if (search.Text.Length != 0 || ((Recording)((ListBox)window.FindName("RecordingList")).SelectedItem).Id != originalId) throw new InvalidOperationException("Clicking a folder child selected the wrong recording under a search filter.");
        await window.WaveformLoadTask; waveform.RequestSeek(20);
        await CaptureAsync(window, Path.Combine(output, "folders.png"));
        var second = new RecordingFolderStore(library.Root).Active[1];
        if (!window.PreviewFolderDrop(first.Id, second.Id, true)) throw new InvalidOperationException("Folder insertion after header was rejected.");
        await CaptureAsync(window, Path.Combine(output, "folder-insertion-after.png")); window.CommitFolderDrop();
        if (new RecordingFolderStore(library.Root).Active[1].Id != first.Id) throw new InvalidOperationException("Drop after folder moved it before instead.");
        if (!window.PreviewFolderDrop(first.Id, second.Id, false)) throw new InvalidOperationException("Folder insertion before header was rejected.");
        await CaptureAsync(window, Path.Combine(output, "folder-insertion-before.png")); window.CommitFolderDrop();
        if (new RecordingFolderStore(library.Root).Active[0].Id != first.Id || waveform.Position != 20) throw new InvalidOperationException("Drop before folder lost order or playback position.");
        if (window.PreviewFolderDrop(first.Id, first.Id, true)) throw new InvalidOperationException("A folder cannot target itself.");
        window.PreviewFolderDrop(first.Id, null, true); window.ClearFolderDropPreview(); window.CommitFolderDrop();
        if (new RecordingFolderStore(library.Root).Active[0].Id != first.Id) throw new InvalidOperationException("Cancelled drag reordered folders.");
        var list = (ListBox)window.FindName("RecordingList"); var context = list.ContextMenu;
        context.PlacementTarget = list; context.IsOpen = true;
        var move = (MenuItem)window.FindName("MoveFolderMenuItem"); move.IsSubmenuOpen = true;
        await window.Dispatcher.InvokeAsync(() => { context.UpdateLayout(); move.UpdateLayout(); }, DispatcherPriority.ContextIdle);
        if (!move.IsEnabled || move.Items.Count != 3 || move.Template.FindName("PART_Popup", move) is not Popup { IsOpen: true }) throw new InvalidOperationException("Folder submenu did not open.");
        ((MenuItem)move.Items[0]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent)); context.IsOpen = false;
        if (library.Load().Single().FolderId is not null || waveform.Position != 20) throw new InvalidOperationException("Moving out of a folder failed.");
        node = (TreeViewItem)tree.Items[0];
        ((MenuItem)node.ContextMenu.Items[2]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        if (new RecordingFolderStore(library.Root).Active[1].Id != first.Id) throw new InvalidOperationException("Folder order was not persisted.");
        window.MoveSelectedToFolder(first.Id);
        node = tree.Items.Cast<TreeViewItem>().Single(x => ((RecordingCollectionFolder)x.Tag).Id == first.Id);
        ((MenuItem)node.ContextMenu.Items[4]).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
        if (new RecordingFolderStore(library.Root).IsActive(first.Id) || library.Load().Single().DeletedAt is not null || waveform.Position != 20)
            throw new InvalidOperationException("Deleting a folder lost the recording or playback position.");
        if (audioHash != await MeetingNotesService.AudioHashAsync(library.AudioPath(originalId), default)) throw new InvalidOperationException("Folder actions changed the audio.");
        ((ListBox)window.FindName("FilterBox")).SelectedIndex = 0;
    }
    private static async Task RunRecordingControlsAsync(string output)
    {
        string root = Path.Combine(Path.GetTempPath(), "NoteTaker-ui-audio-" + Guid.NewGuid().ToString("N"));
        var store = new LibraryStore(root);
        var window = new MainWindow(store, enableDesktopIntegration: false) { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        window.Show();
        try
        {
            var start = (Button)window.FindName("RecordButton");
            var pause = (Button)window.FindName("PauseButton");
            var resume = (Button)window.FindName("ResumeButton");
            var stop = (Button)window.FindName("StopButton");
            start.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await WaitForAsync(() => pause.IsEnabled, "Recording start", window);
            if (start.IsEnabled || ((Grid)window.FindName("RecordingPanel")).Visibility != Visibility.Visible)
                throw new InvalidOperationException("Recording view state is incorrect.");
            await Task.Delay(350);
            pause.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (pause.IsEnabled || !resume.IsEnabled) throw new InvalidOperationException("Pause/resume button state is incorrect.");
            await Task.Delay(150);
            resume.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (!pause.IsEnabled || resume.IsEnabled) throw new InvalidOperationException("Resume button state is incorrect.");
            await Task.Delay(350);
            stop.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await WaitForAsync(() => start.IsEnabled, "Recording finish", window);
            await window.WaveformLoadTask;
            var saved = store.Load().Single();
            if (saved.IsRecording || saved.DurationSeconds < .5 || !File.Exists(store.AudioPath(saved.Id)))
                throw new InvalidOperationException("The UI did not finalize a recording.");
            File.WriteAllText(Path.Combine(output, "ui-audio-result.txt"), "PASS: real Windows devices through WPF record → pause → resume → done; saved WAV and playback view verified. Temporary microphone/system audio removed after verification.");
        }
        finally
        {
            var closed = new TaskCompletionSource();
            window.Closed += (_, _) => closed.TrySetResult();
            window.Close(); await closed.Task;
            var fullPath = Path.GetFullPath(root);
            if (fullPath.StartsWith(Path.Combine(Path.GetTempPath(), "NoteTaker-ui-audio-"), StringComparison.OrdinalIgnoreCase)) Directory.Delete(fullPath, recursive: true);
        }
    }
    private static async Task WaitForAsync(Func<bool> predicate, string phase, MainWindow window)
    {
        for (int attempt = 0; attempt < 100; attempt++) { if (predicate()) return; await Task.Delay(50); }
        throw new InvalidOperationException(phase + " failed: " + ((TextBlock)window.FindName("StatusText")).Text);
    }
    private static void CreateFixtureAudio(string path)
    {
        using var writer = new WaveFileWriter(path, AudioFiles.RecordingFormat);
        var samples = new float[48000 * 2];
        for (int second = 0; second < 42; second++)
        {
            for (int frame = 0; frame < 48000; frame++)
            {
                double time = second + frame / 48000d;
                double envelope = .1 + .55 * Math.Abs(Math.Sin(time * 1.7) * Math.Cos(time * .63)) + .15 * Math.Abs(Math.Sin(time * 13));
                if (second % 9 == 0) envelope *= .08;
                float sample = (float)(Math.Sin(time * 2 * Math.PI * 440) * envelope);
                samples[frame * 2] = samples[frame * 2 + 1] = sample;
            }
            writer.WriteSamples(samples, 0, samples.Length);
        }
    }
    internal static async Task CaptureAsync(Window window, string path)
    {
        await window.Dispatcher.InvokeAsync(() => window.UpdateLayout(), DispatcherPriority.ContextIdle);
        var content = (FrameworkElement)window.Content;
        SaveImage(content, path);
    }
    internal static void SaveImage(FrameworkElement content, string path)
    {
        if (content.ActualWidth <= 0 || content.ActualHeight <= 0) throw new InvalidOperationException("Window content was not laid out.");
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(content.ActualWidth), (int)Math.Ceiling(content.ActualHeight), 96, 96, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        var bounds = new Rect(0, 0, content.ActualWidth, content.ActualHeight);
        using (var dc = visual.RenderOpen()) dc.DrawRectangle(new VisualBrush(content) { ViewboxUnits = BrushMappingMode.Absolute, Viewbox = bounds }, null, bounds);
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var file = File.Create(path); encoder.Save(file);
    }
}
