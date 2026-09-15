using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;
using Microsoft.Win32;
using NAudio.CoreAudioApi;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

public partial class MainWindow : Window
{
    private readonly LibraryStore library;
    private readonly string aiModelRoot;
    private readonly SettingsStore settingsStore;
    private readonly RecordingFolderStore folderStore;
    private AppSettings settings;
    private readonly AudioPlayer player = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private IRecordingSession? recorder;
    private readonly Func<IRecordingSession> recordingFactory;
    private Recording? activeRecording;
    private Recording? selected;
    private MeetingNotes? notes;
    private string transcriptText = "";
    private IReadOnlyList<Recording> recordings = [];
    private CancellationTokenSource? workCancellation;
    private Task? runningWork;
    internal Task CurrentWork => runningWork ?? Task.CompletedTask;
    internal Task LastStopButtonWork { get; private set; } = Task.CompletedTask;
    internal Exception? LastWorkError { get; private set; }
    private CancellationTokenSource? waveformCancellation;
    internal Task WaveformLoadTask { get; private set; } = Task.CompletedTask;
    private bool loaded, transitioning, finishing, closePending, allowClose, playbackLoaded;
    private DesktopIntegration? desktop;
    private bool exitRequested;
    private WebShareWindow? webShareWindow;
    internal DesktopIntegration? Desktop => desktop;

    public MainWindow(LibraryStore library, bool discoverDevices = true, string? aiModelRoot = null, bool enableDesktopIntegration = true, Func<IRecordingSession>? recordingFactory = null, Func<SyncConfiguration, HttpMessageHandler>? syncHandlerFactory = null)
    {
        this.library = library;
        this.syncHandlerFactory = syncHandlerFactory;
        this.recordingFactory = recordingFactory ?? (() => new AudioRecorder());
        this.aiModelRoot = aiModelRoot ?? library.Root;
        settingsStore = new SettingsStore(library.Root);
        settings = settingsStore.Load();
        folderStore = new RecordingFolderStore(library.Root);
        InitializeComponent();
        LoadFolderAppearance();
        PlaybackSlider.SeekRequested += SeekTo;
        OverviewWaveform.SeekRequested += SeekTo;
        loaded = true;
        if (discoverDevices) RefreshDevices();
        ReloadLibrary();
        ReadSyncStatus();
        timer.Tick += Timer_Tick;
        timer.Start();
        UpdateControls();
        if (enableDesktopIntegration) SourceInitialized += (_, _) =>
        {
            try
            {
                desktop = new DesktopIntegration(this, ShowFromTray, ToggleTrayRecording, () => Pause_Click(this, new RoutedEventArgs()), RequestExit);
                desktop.ConfigureShortcuts(settings.EnableGlobalShortcuts);
                if (!desktop.IsAvailable) SetStatus("트레이 아이콘을 만들지 못했습니다. 창을 닫으면 앱을 종료합니다.", true);
                else if (desktop.ShortcutWarning is not null) SetStatus(desktop.ShortcutWarning, true);
            }
            catch (Exception ex) { SetStatus("트레이를 준비하지 못했습니다. " + FriendlyError(ex), true); }
        };
    }

    internal void ShowFromTray()
    {
        Show(); if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
    }
    private async void ToggleTrayRecording()
    {
        if (recorder is not null) await StopRecordingAsync();
        else { ShowFromTray(); Record_Click(this, new RoutedEventArgs()); }
    }
    internal void RequestExit() { exitRequested = true; Close(); }

    private MeetingNotesService MeetingService() => new(library,
        (s, key, progress) => AiProviders.Transcriber(aiModelRoot, s, key, progress), AiProviders.Summarizer);

    private void SetStatus(string message, bool error = false)
    {
        StatusText.Text = message;
        StatusText.SetResourceReference(TextBlock.ForegroundProperty, error ? "RecordRed" : "Muted");
    }

    private async Task RunWorkAsync(Func<CancellationToken, Task> action)
    {
        if (runningWork is not null || recorder is not null || transitioning || closePending || exitRequested) return;
        workCancellation = new CancellationTokenSource();
        LastWorkError = null;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        runningWork = completion.Task;
        UpdateControls();
        try { await action(workCancellation.Token); }
        catch (OperationCanceledException) { SetStatus("작업을 취소했습니다. 완료된 전사와 기존 회의록은 유지됩니다."); }
        catch (Exception ex) { LastWorkError = ex; SetStatus(FriendlyError(ex), true); }
        finally
        {
            workCancellation.Dispose(); workCancellation = null;
            runningWork = null;
            if (!syncing) RequestAutomaticSync();
            UpdateControls(); completion.SetResult();
        }
    }

    internal void ReloadLibrary(Guid? selectId = null)
    {
        var id = selectId ?? selected?.Id;
        recordings = library.Load().Where(r => !r.IsLocallyPurged).ToList();
        AllCount.Text = recordings.Count(r => r.DeletedAt is null).ToString();
        FavoriteCount.Text = recordings.Count(r => r.DeletedAt is null && r.IsFavorite).ToString();
        DeletedCount.Text = recordings.Count(r => r.DeletedAt is not null).ToString();
        ReloadFolders();
        FilterLibrary(id);
        if (library.LoadWarnings.Count > 0) SetStatus(library.LoadWarnings[0], true);
        if (folderStore.LoadError is not null) SetStatus(folderStore.LoadError, true);
    }

    private void FilterLibrary(Guid? selectId = null)
    {
        if (!loaded) return;
        string query = SearchBox.Text.Trim();
        string title = folderStore.Active.FirstOrDefault(f => f.Id == selectedFolder)?.Name ?? (FilterBox.SelectedIndex == 2 ? "최근 삭제된 항목" : FilterBox.SelectedIndex == 1 ? "즐겨찾기" : "모든 녹음 항목");
        SidebarTitle.Text = WindowSubtitle.Text = title;
        ClearSearchButton.Visibility = query.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var list = recordings.Where(r => !r.IsRecording && (FilterBox.SelectedIndex == 2
            ? r.DeletedAt is not null : r.DeletedAt is null && (FilterBox.SelectedIndex != 1 || r.IsFavorite)))
            .Where(r => selectedFolder is null || r.FolderId == selectedFolder)
            .Where(r => r.Title.Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        refreshingLibrary = true;
        RecordingList.ItemsSource = list;
        LibraryCount.Text = list.Count == 0 ? "녹음 없음" : $"{title}  ·  {list.Count}";
        RecordingList.SelectedItem = list.FirstOrDefault(r => r.Id == selectId) ?? list.FirstOrDefault();
        refreshingLibrary = false;
        SelectRecording(RecordingList.SelectedItem as Recording);
    }
    private void Search_Changed(object sender, TextChangedEventArgs e) { if (loaded && !refreshingLibrary) FilterLibrary(selected?.Id); }
    private void Filter_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!loaded || refreshingLibrary || FilterBox.SelectedIndex < 0) return;
        selectedFolder = null; ClearFolderSelection(); FilterLibrary(selected?.Id);
    }
    private void Recording_Selected(object sender, SelectionChangedEventArgs e)
    {
        if (loaded && !refreshingLibrary) SelectRecording(RecordingList.SelectedItem as Recording);
    }

    private void SelectRecording(Recording? recording)
    {
        bool sameAudio = recording is not null && selected?.Id == recording.Id && selected.AudioVersion == recording.AudioVersion && selected.DurationSeconds == recording.DurationSeconds;
        if (!sameAudio) { StopTurnPlayback(); waveformCancellation?.Cancel(); player.Dispose(); playbackLoaded = false; }
        selected = recording; notes = null;
        if (!sameAudio) { PlaybackSlider.Peaks = []; PlaybackSlider.Position = 0; }
        if (recording is not null)
        {
            DetailTitle.Text = NotesTitle.Text = recording.Title;
            DetailMeta.Text = recording.CreatedAt.LocalDateTime.ToString("yyyy년 M월 d일 tt h:mm");
            DetailMode.Text = recording.ModeLabel;
            NotesMeta.Text = recording.Subtitle;
            FavoriteButton.Content = recording.IsFavorite ? "즐겨찾기 해제" : "즐겨찾기";
            DeleteButton.Content = recording.DeletedAt is null ? "삭제" : "복원";
            PlaybackSlider.Duration = recording.DurationSeconds;
            PlaybackTime.Text = $"{Recording.FormatTime(PlaybackSlider.Position)} / {Recording.FormatTime(recording.DurationSeconds)}";
            ElapsedLabel.Text = Recording.FormatTime(PlaybackSlider.Position); TotalLabel.Text = Recording.FormatTime(recording.DurationSeconds);
            LoadDocuments(recording);
            if (!sameAudio) WaveformLoadTask = LoadWaveformAsync(recording);
            if (recording.Warning is not null) SetStatus(recording.Warning, true);
        }
        UpdateControls();
    }

    internal void LoadDocuments(Recording recording)
    {
        try
        {
            notes = JsonDisk.Read<MeetingNotes>(library.NotesPath(recording.Id));
            var transcript = JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id));
            transcriptText = transcript is null ? "" : (transcript.Complete ? "" : "[부분 전사]\n\n") + string.Join("\n\n", transcript.Chunks);
            RenderNotes(notes?.Markdown ?? "");
            NotesPlaceholder.Visibility = notes is null ? Visibility.Visible : Visibility.Collapsed;
            TranscriptBox.Text = transcript is null ? "전사문이 아직 없습니다. AI 회의록을 생성하면 오디오를 먼저 전사합니다." :
                (transcript.Complete ? "" : "[부분 전사 · 다시 생성하면 이어서 처리합니다.]\n\n") + string.Join("\n\n", transcript.Chunks);
            if (notes is not null)
            {
                bool stale = transcript is not null && (notes.TranscriptHash is not null
                    ? notes.TranscriptHash != MeetingNotesService.TranscriptContentHash(transcript)
                    : File.GetLastWriteTimeUtc(library.TranscriptPath(recording.Id)) > notes.CreatedAt.UtcDateTime.AddSeconds(1));
                NotesMeta.Text = recording.Subtitle + $"  ·  {notes.Model}" + (stale ? "  ·  전사문이 바뀌었습니다. 다시 정리해 주세요." : "");
            }
            GenerateButton.Content = notes is null ? "회의록 생성" : "다시 생성";
        }
        catch (Exception ex)
        {
            RenderNotes(""); notes = null;
            transcriptText = "";
            TranscriptBox.Text = "저장된 문서를 읽지 못했습니다. 저장 폴더에서 원본을 확인해 주세요.";
            NotesPlaceholder.Visibility = Visibility.Visible;
            SetStatus(FriendlyError(ex), true);
        }
        LoadParticipants(recording);
        try { LoadCleanup(JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id))); }
        catch (Exception) { LoadCleanup(null); }
    }

    private void RefreshDevices()
    {
        try
        {
            string? mic = (MicrophoneBox.SelectedItem as AudioDevice)?.Id;
            string? output = (OutputBox.SelectedItem as AudioDevice)?.Id;
            var microphones = AudioRecorder.GetDevices(DataFlow.Capture);
            var outputs = AudioRecorder.GetDevices(DataFlow.Render);
            MicrophoneBox.ItemsSource = microphones;
            OutputBox.ItemsSource = outputs;
            MicrophoneBox.SelectedItem = microphones.FirstOrDefault(d => d.Id == mic) ?? microphones.FirstOrDefault();
            OutputBox.SelectedItem = outputs.FirstOrDefault(d => d.Id == output) ?? outputs.FirstOrDefault();
            SetStatus("오디오 장치 목록을 확인했습니다.");
        }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void RefreshDevices_Click(object sender, RoutedEventArgs e) => RefreshDevices();
    private RecordingMode Mode => ModeBox.SelectedIndex switch { 1 => RecordingMode.Microphone, 2 => RecordingMode.SystemAudio, _ => RecordingMode.Mixed };
    private void Mode_Changed(object sender, SelectionChangedEventArgs e) { if (loaded) UpdateControls(); }

    private async Task LoadWaveformAsync(Recording recording)
    {
        waveformCancellation?.Cancel();
        var cancellation = new CancellationTokenSource();
        waveformCancellation = cancellation;
        WaveformNotice.Visibility = Visibility.Visible;
        WaveformNoticeText.Text = "파형을 불러오는 중…";
        try
        {
            var peaks = await Task.Run(() => WaveformSampler.Read(library.AudioPath(recording.Id), token: cancellation.Token), cancellation.Token);
            if (cancellation.IsCancellationRequested || selected?.Id != recording.Id || closePending) return;
            PlaybackSlider.Peaks = peaks;
            WaveformNotice.Visibility = peaks.Length > 0 ? Visibility.Collapsed : Visibility.Visible;
            WaveformNoticeText.Text = "파형을 표시할 오디오가 없습니다.";
        }
        catch (OperationCanceledException) { }
        catch (Exception)
        {
            if (!cancellation.IsCancellationRequested && selected?.Id == recording.Id)
                WaveformNoticeText.Text = "파형을 불러올 수 없습니다.";
        }
        finally { if (waveformCancellation == cancellation) waveformCancellation = null; cancellation.Dispose(); }
    }
    private void ReloadWaveform_Click(object sender, RoutedEventArgs e) { if (selected is not null) WaveformLoadTask = LoadWaveformAsync(selected); }
    private void ClearSearch_Click(object sender, RoutedEventArgs e) { SearchBox.Clear(); SearchBox.Focus(); }
    private void RecordOptions_Click(object sender, RoutedEventArgs e) => CapturePopup.IsOpen = !CapturePopup.IsOpen;
    private void RecordOptions_RightClick(object sender, MouseButtonEventArgs e) { if (RecordOptionsButton.IsEnabled) CapturePopup.IsOpen = true; e.Handled = true; }
    private void CapturePopup_Opened(object? sender, EventArgs e) => ModeBox.Focus();
    private void ShowNotes_Click(object sender, RoutedEventArgs e) => DetailPanel.SelectedIndex = 1;
    private void DetailTab_Changed(object sender, SelectionChangedEventArgs e) { if (loaded && ReferenceEquals(e.Source, DetailPanel)) UpdateControls(); }
    private void Title_MouseDown(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2 && RenameButton.IsEnabled) Rename_Click(sender, e); }
    private void RevealRecording_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { Process.Start(new ProcessStartInfo(library.DirectoryFor(selected.Id)) { UseShellExecute = true }); }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void Recording_RightClick(object sender, MouseButtonEventArgs e)
    {
        DependencyObject? current = e.OriginalSource as DependencyObject;
        while (current is not null && current is not ListBoxItem)
            current = current is FrameworkContentElement content ? content.Parent : VisualTreeHelper.GetParent(current);
        if (current is ListBoxItem row && row.DataContext is Recording record) RecordingList.SelectedItem = record;
    }
    private void RecordingMenu_Opened(object sender, RoutedEventArgs e)
    {
        RenameMenuItem.IsEnabled = RenameButton.IsEnabled;
        FavoriteMenuItem.IsEnabled = FavoriteButton.IsEnabled;
        DeleteMenuItem.IsEnabled = DeleteButton.IsEnabled;
        FavoriteMenuItem.Header = FavoriteButton.Content;
        DeleteMenuItem.Header = DeleteButton.Content;
        PermanentDeleteMenuItem.Visibility = PermanentDeleteButton.Visibility;
        PermanentDeleteMenuItem.IsEnabled = PermanentDeleteButton.IsEnabled;
        ExportAudioMenuItem.IsEnabled = ExportAudioButton.IsEnabled;
        PopulateMoveMenu(MoveFolderMenuItem);
    }
    private void Window_KeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Control && e.Key == Key.Q) { RequestExit(); e.Handled = true; return; }
        if (CapturePopup.IsOpen && e.Key == Key.Escape) { CapturePopup.IsOpen = false; RecordOptionsButton.Focus(); e.Handled = true; return; }
        if (Keyboard.Modifiers == ModifierKeys.Control)
        {
            if (e.Key == Key.F) { SearchBox.Focus(); SearchBox.SelectAll(); }
            else if (e.Key == Key.N && RecordButton.IsEnabled) Record_Click(sender, e);
            else if (e.Key == Key.O && ImportButton.IsEnabled) Import_Click(sender, e);
            else if (e.Key == Key.OemComma && SettingsButton.IsEnabled) Settings_Click(sender, e);
            else return;
            e.Handled = true; return;
        }
        if (Keyboard.FocusedElement is TextBoxBase or PasswordBox or ComboBox or ButtonBase or TabItem or MenuItem || CapturePopup.IsOpen) return;
        if (e.Key == Key.Space && Keyboard.Modifiers == ModifierKeys.None)
        {
            if (recorder is not null && !transitioning) Pause_Click(sender, e);
            else if (PlayButton.IsEnabled) Play_Click(sender, e);
            e.Handled = true;
        }
    }

    private async void Record_Click(object sender, RoutedEventArgs e)
    {
        if (!await StopSyncForForegroundAsync()) return;
        if (recorder is not null || transitioning || runningWork is not null || ModalOperationOpen) return;
        transitioning = true; UpdateControls();
        CapturePopup.IsOpen = false;
        RecordingClock.Text = "00:00";
        try
        {
            var micId = (MicrophoneBox.SelectedItem as AudioDevice)?.Id;
            var outputId = (OutputBox.SelectedItem as AudioDevice)?.Id;
            if ((Mode is RecordingMode.Microphone or RecordingMode.Mixed) && micId is null)
                throw new InvalidOperationException("마이크를 연결하고 장치 새로고침을 눌러 주세요.");
            if ((Mode is RecordingMode.SystemAudio or RecordingMode.Mixed) && outputId is null)
                throw new InvalidOperationException("출력 장치를 연결하고 장치 새로고침을 눌러 주세요.");
            StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
            activeRecording = new Recording { Title = $"회의 {DateTime.Now:MM월 dd일 HH:mm}", Mode = Mode, IsRecording = true, FolderId = folderStore.IsActive(selectedFolder) ? selectedFolder : null };
            library.Save(activeRecording);
            recorder = recordingFactory();
            UpdateControls();
            await recorder.StartAsync(library.AudioPath(activeRecording.Id), Mode, micId, outputId);
            StartLiveOwner();
            SetStatus("녹음 중 · 선택한 출력 장치의 전체 소리를 녹음합니다.");
            CaptureHint.Text = settings.KeepRunningInTray && desktop?.IsAvailable == true
                ? "창을 닫아도 녹음이 계속됩니다. 트레이에서 녹음을 제어할 수 있습니다."
                : "녹음 중입니다. 창을 닫으면 녹음을 저장하고 종료합니다.";
        }
        catch (Exception ex)
        {
            await StopLiveOwnerAsync();
            if (recorder is not null) { await recorder.DisposeAsync(); recorder = null; }
            if (activeRecording is not null)
            {
                // Keep the unfinished manifest: next launch can recover any written audio.
                activeRecording = null;
            }
            SetStatus(FriendlyError(ex), true);
        }
        finally { transitioning = false; UpdateControls(); }
    }
    private void Pause_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            recorder?.TogglePause();
            liveOwner?.SetActive(recorder?.IsPaused != true);
            UpdateLiveOwner();
            SetStatus(recorder?.IsPaused == true ? "녹음 일시정지 · 재개하면 이어서 저장됩니다." : "녹음 중");
            UpdateControls();
        }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private async void Stop_Click(object sender, RoutedEventArgs e) { LastStopButtonWork = StopRecordingAsync(); await LastStopButtonWork; }
    private async Task StopRecordingAsync()
    {
        if (recorder is null || transitioning) return;
        transitioning = true; finishing = true; UpdateControls();
        liveOwner?.SetActive(false);
        var session = recorder;
        Recording? completedRecording = null;
        try
        {
            double duration = await session.StopAsync();
            var completed = activeRecording! with { IsRecording = false, DurationSeconds = duration, Warning = session.Failure };
            library.Save(completed);
            completedRecording = completed;
            SetStatus(session.Failure ?? $"녹음을 저장했습니다 · {Recording.FormatTime(duration)}", session.Failure is not null);
            // Session must be cleared before library reload updates enabled controls.
            recorder = null; activeRecording = null;
            SelectFolderFilter(completed.FolderId); SearchBox.Text = ""; DetailPanel.SelectedIndex = 0;
            ReloadLibrary(completed.Id);
        }
        catch (Exception ex) { recorder = null; activeRecording = null; SetStatus(FriendlyError(ex) + " 다음 실행에서 녹음 복구를 시도합니다.", true); }
        finally
        {
            await StopLiveOwnerAsync();
            await session.DisposeAsync();
            transitioning = false; finishing = false;
            CaptureHint.Text = "완료를 누르면 녹음이 라이브러리에 저장됩니다.";
            MicMeter.Value = SystemMeter.Value = 0;
            UpdateControls();
        }
        if (completedRecording is { Warning: null } && settings.AutoGenerate && !closePending && !exitRequested)
            await GenerateNotesAsync(completedRecording);
        if (completedRecording is { Warning: null } && !closePending && !exitRequested && recorder is null && runningWork is null)
        {
            try
            {
                if (new MeetingProfileStore(library.Root).Load().AutomaticallyAnalyze && await AnalyzeParticipantsAsync(completedRecording) && !closePending && !exitRequested)
                    await AnalyzeMeetingAsync(completedRecording);
            }
            catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
        }
    }

    private async void Import_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "녹음 가져오기", Filter = "오디오 파일|*.wav;*.mp3;*.m4a;*.aac;*.wma;*.aiff|모든 파일|*.*" };
        if (dialog.ShowDialog(this) != true) return;
        await RunWorkAsync(async token =>
        {
            SetStatus("오디오를 가져오는 중…");
            var imported = await library.ImportAsync(dialog.FileName, token);
            if (folderStore.IsActive(selectedFolder)) imported = folderStore.MoveRecording(library, imported, selectedFolder);
            SelectFolderFilter(imported.FolderId); SearchBox.Text = "";
            ReloadLibrary(imported.Id); SetStatus("오디오를 라이브러리에 저장했습니다.");
        });
    }

    private async void Generate_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        await GenerateNotesAsync(selected);
    }
    private async Task GenerateNotesAsync(Recording recording)
    {
        await RunWorkAsync(async token =>
        {
            string key = settings.TranscriptionProvider == "openrouter" || settings.SummaryProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "";
            if (settings.SummaryProvider == "ollama") await LocalRuntime.StartOllamaAsync(aiModelRoot, settings, token);
            var service = MeetingService();
            try
            {
                await service.GenerateAsync(recording, settings, key, new Progress<string>(message => SetStatus(message)), token);
                SetStatus("회의록을 저장했습니다. 전사문과 함께 내용을 확인해 주세요.");
            }
            finally { if (selected?.Id == recording.Id) LoadDocuments(recording); }
        });
    }
    private async void TranscribeOnly_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return; var recording = selected;
        await RunWorkAsync(async token =>
        {
            try
            {
                await MeetingService().TranscribeAsync(recording, settings,
                    settings.TranscriptionProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "",
                    new Progress<string>(message => SetStatus(message)), token);
                SetStatus("전사문을 저장했습니다. 회의록 정리는 필요할 때 실행하세요.");
            }
            finally { if (selected?.Id == recording.Id) { LoadDocuments(recording); DocumentTabs.SelectedIndex = 1; } }
        });
    }
    private async void SummarizeOnly_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return; var recording = selected;
        await RunWorkAsync(async token =>
        {
            try
            {
                if (settings.SummaryProvider == "ollama") await LocalRuntime.StartOllamaAsync(aiModelRoot, settings, token);
                await MeetingService().SummarizeAsync(recording, settings,
                    settings.SummaryProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "",
                    new Progress<string>(message => SetStatus(message)), token);
                SetStatus("저장된 전사문으로 회의록을 정리했습니다.");
            }
            finally { if (selected?.Id == recording.Id) { LoadDocuments(recording); DocumentTabs.SelectedIndex = 0; } }
        });
    }
    private void Cancel_Click(object sender, RoutedEventArgs e) { workCancellation?.Cancel(); SetStatus("작업을 취소하는 중…"); }
    private async void ImportTranscript_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return; var recording = selected;
        var dialog = new TranscriptImportWindow(recording.Title) { Owner = this };
        if (dialog.ShowDialog() != true || dialog.Result is null) return;
        await RunWorkAsync(async token =>
        {
            await TranscriptImport.SaveAsync(library, recording, dialog.Result, token);
            if (selected?.Id == recording.Id) { LoadDocuments(recording); DocumentTabs.SelectedIndex = 1; }
            SetStatus("전사문을 연결했습니다. ‘전사문으로 정리’를 누르면 회의록을 만듭니다. 기존 회의록은 아직 이전 내용입니다.");
        });
    }
    private async void ClovaExport_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return; var recording = selected;
        var dialog = new OpenFolderDialog { Title = "클로바노트용 파일을 저장할 폴더" };
        if (dialog.ShowDialog(this) != true) return;
        await RunWorkAsync(async token =>
        {
            var files = await ClovaAudioExport.ExportAsync(library.AudioPath(recording.Id), dialog.FolderName,
                new Progress<string>(message => SetStatus(message)), token);
            SetStatus($"클로바노트용 WAV {files.Count}개를 저장했습니다. 각 파일은 최대 90분입니다.");
            Process.Start(new ProcessStartInfo("explorer.exe", System.IO.Path.GetDirectoryName(files[0])!) { UseShellExecute = true });
        });
    }

    private void Settings_Click(object sender, RoutedEventArgs e) => OpenSettings(false);
    private async void OpenSettings(bool showSync)
    {
        if (!await StopSyncForForegroundAsync() || recorder is not null || transitioning || runningWork is not null || ModalOperationOpen) return;
        try
        {
            settings = settingsStore.Load();
            var dialog = new SettingsWindow(settings, aiModelRoot, syncHandlerFactory) { Owner = this };
            if (showSync) dialog.Loaded += (_, _) => dialog.ShowSyncSettings();
            if (dialog.ShowDialog() != true) return;
            settingsStore.Save(dialog.Result);
            settings = settingsStore.Load();
            LastSyncResult = null; syncSchedule.Reset(); ReadSyncStatus();
            desktop?.ConfigureShortcuts(settings.EnableGlobalShortcuts);
            SetStatus("AI 설정을 이 Windows 계정에 저장했습니다.");
            if (desktop?.ShortcutWarning is not null) SetStatus(desktop.ShortcutWarning, true);
        }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo(library.Root) { UseShellExecute = true }); }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }

    private void Play_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try
        {
            EnsurePlaybackLoaded();
            player.Toggle();
            UpdatePlayIcon();
        }
        catch (Exception ex) { playbackLoaded = false; SetStatus(FriendlyError(ex), true); }
    }
    private void EnsurePlaybackLoaded()
    {
        if (selected is null || playbackLoaded) return;
        player.Load(library.AudioPath(selected.Id)); playbackLoaded = true; PlaybackSlider.Duration = player.Duration;
        player.Seek(PlaybackSlider.Position);
    }
    private void Back_Click(object sender, RoutedEventArgs e) => SeekTo(PlaybackSlider.Position - 15);
    private void Forward_Click(object sender, RoutedEventArgs e) => SeekTo(PlaybackSlider.Position + 15);
    private void SeekTo(double position)
    {
        if (selected is null || recorder is not null) return;
        StopTurnPlayback();
        try
        {
            EnsurePlaybackLoaded();
            player.Seek(position);
            PlaybackSlider.Position = player.Position;
        }
        catch (Exception ex) { playbackLoaded = false; SetStatus(FriendlyError(ex), true); }
    }

    private bool SaveEdit(Recording changed)
    {
        try { library.Save(changed); ReloadLibrary(changed.Id); RequestAutomaticSync(); return true; }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); return false; }
    }
    private void Favorite_Click(object sender, RoutedEventArgs e) { if (selected is not null) SaveEdit(selected with { IsFavorite = !selected.IsFavorite }); }
    private void Delete_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null || runningWork is not null || recorder is not null || transitioning || ModalOperationOpen) return;
        bool restore = selected.DeletedAt is not null;
        if (SaveEdit(selected with { DeletedAt = restore ? null : DateTimeOffset.Now }))
            SetStatus(restore ? "녹음을 복원했습니다." : "최근 삭제로 이동했습니다. 30일 안에 복원할 수 있습니다.");
    }
    private void Rename_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        var dialog = new RenameWindow(selected.Title) { Owner = this };
        if (dialog.ShowDialog() == true) SaveEdit(selected with { Title = dialog.Result });
    }
    private string ExportText() => DocumentTabs.SelectedIndex switch { 1 => transcriptText, 2 => cleanedTranscriptText, _ => notes?.Markdown ?? "" };
    private void DocumentTab_Changed(object sender, SelectionChangedEventArgs e) { if (loaded) UpdateControls(); }
    private void Export_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null || string.IsNullOrWhiteSpace(ExportText())) return;
        string title = string.Concat(selected.Title.Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '_' : c));
        var dialog = new SaveFileDialog { FileName = title + (DocumentTabs.SelectedIndex switch { 1 => "-전사문", 2 => "-정리한-전사", _ => "-회의록" }) + ".md", Filter = "Markdown|*.md", AddExtension = true };
        try { if (dialog.ShowDialog(this) == true) { File.WriteAllText(dialog.FileName, ExportText()); SetStatus("Markdown 파일을 내보냈습니다."); } }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        try { if (!string.IsNullOrWhiteSpace(ExportText())) { Clipboard.SetText(ExportText()); SetStatus("클립보드에 복사했습니다."); } }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void ShareWeb_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null || notes is null || runningWork is not null || recorder is not null || transitioning || ModalOperationOpen) return;
        try
        {
            webShareWindow = new WebShareWindow(selected, notes, settings, syncHandlerFactory) { Owner = this };
            _ = webShareWindow.ShowDialog();
            SetStatus("웹 공유 창을 닫았습니다.");
        }
        finally { webShareWindow = null; UpdateControls(); }
    }

    private void UpdateControls()
    {
        if (!loaded) return;
        bool idle = recorder is null && !transitioning && runningWork is null && !ModalOperationOpen;
        ProfileButton.IsEnabled = idle;
        RecordButton.IsEnabled = RecordOptionsButton.IsEnabled = CaptureOptions.IsEnabled = RefreshDevicesButton.IsEnabled = ImportButton.IsEnabled = SettingsButton.IsEnabled = idle;
        if (syncing && !syncForegroundPending && !closePending && !exitRequested) RecordButton.IsEnabled = SettingsButton.IsEnabled = true;
        CaptureModeLabel.Text = RecordingModeLabel.Text = Mode switch { RecordingMode.Microphone => "마이크만", RecordingMode.SystemAudio => "시스템 오디오만", _ => "마이크 + 시스템" };
        MicRail.Visibility = Mode == RecordingMode.SystemAudio ? Visibility.Collapsed : Visibility.Visible;
        SystemRail.Visibility = Mode == RecordingMode.Microphone ? Visibility.Collapsed : Visibility.Visible;
        MicrophoneBox.IsEnabled = Mode != RecordingMode.SystemAudio;
        OutputBox.IsEnabled = Mode != RecordingMode.Microphone;
        PauseButton.IsEnabled = recorder is not null && !transitioning && !recorder.IsPaused;
        ResumeButton.IsEnabled = recorder is not null && !transitioning && recorder.IsPaused;
        StopButton.IsEnabled = recorder is not null && !transitioning;
        PlayButton.IsEnabled = BackButton.IsEnabled = ForwardButton.IsEnabled = idle && selected is not null;
        PlaybackSlider.IsEnabled = OverviewWaveform.IsEnabled = idle;
        RecordingPanel.Visibility = recorder is not null || transitioning ? Visibility.Visible : Visibility.Collapsed;
        RecordingStatus.Text = transitioning ? finishing ? "저장 중…" : "준비 중…" : recorder?.IsPaused == true ? "일시정지됨" : "녹음 중";
        DetailPanel.Visibility = recorder is null && !transitioning && selected is not null ? Visibility.Visible : Visibility.Collapsed;
        EmptyState.Visibility = recorder is null && !transitioning && selected is null ? Visibility.Visible : Visibility.Collapsed;
        bool editable = idle && selected is not null;
        FavoriteButton.IsEnabled = RenameButton.IsEnabled = DeleteButton.IsEnabled = editable;
        PermanentDeleteButton.Visibility = selected?.DeletedAt is not null ? Visibility.Visible : Visibility.Collapsed;
        PermanentDeleteButton.IsEnabled = editable && selected?.DeletedAt is not null;
        ExportAudioButton.IsEnabled = editable && File.Exists(library.AudioPath(selected!.Id));
        GenerateButton.IsEnabled = TranscribeOnlyButton.IsEnabled = SummarizeOnlyButton.IsEnabled = ImportTranscriptButton.IsEnabled = ClovaExportButton.IsEnabled = editable && selected?.DeletedAt is null;
        ShareWebButton.IsEnabled = editable && selected?.DeletedAt is null && notes is not null;
        EnhanceNotesButton.IsEnabled = CleanTranscriptButton.IsEnabled = ShareWebButton.IsEnabled;
        CopyButton.IsEnabled = ExportButton.IsEnabled = selected is not null && !string.IsNullOrWhiteSpace(ExportText());
        RecordingList.IsEnabled = SearchBox.IsEnabled = FilterBox.IsEnabled = runningWork is null && !transitioning;
        FolderTree.IsEnabled = CreateFolderButton.IsEnabled = idle && folderStore.LoadError is null;
        CancelButton.Visibility = runningWork is null ? Visibility.Collapsed : Visibility.Visible;
        UpdateParticipantControls();
        UpdatePlayIcon();
        UpdateSyncControls();
    }

    private void UpdatePlayIcon()
    {
        PlayIcon.Kind = player.IsPlaying ? "pause" : "play";
        System.Windows.Automation.AutomationProperties.SetName(PlayButton, player.IsPlaying ? "재생 일시정지" : "재생");
    }

    private async void Timer_Tick(object? sender, EventArgs e)
    {
        AdvanceTurnPlayback();
        desktop?.Update(recorder is not null, recorder?.IsPaused == true, transitioning || runningWork is not null && !syncing,
            recorder is null ? "" : Recording.FormatTime(recorder.DurationSeconds));
        if (recorder is not null)
        {
            if (!transitioning) UpdateLiveOwner();
            RecordingClock.Text = Recording.FormatTime(recorder.DurationSeconds);
            MicMeter.Value = recorder.IsPaused ? 0 : recorder.MicrophoneLevel;
            SystemMeter.Value = recorder.IsPaused ? 0 : recorder.SystemLevel;
            MicSignal.Text = MicMeter.Value > .001 ? "입력 감지됨" : "신호 없음";
            SystemSignal.Text = SystemMeter.Value > .001 ? "입력 감지됨" : "신호 없음";
            if (recorder.Failure is not null && !transitioning) await StopRecordingAsync();
        }
        UpdatePlayIcon();
        if (playbackLoaded)
        {
            if (!PlaybackSlider.IsMouseCaptureWithin && !OverviewWaveform.IsMouseCaptureWithin) PlaybackSlider.Position = player.Position;
            PlaybackTime.Text = $"{Recording.FormatTime(player.Position)} / {Recording.FormatTime(player.Duration)}";
            ElapsedLabel.Text = Recording.FormatTime(player.Position); TotalLabel.Text = Recording.FormatTime(player.Duration);
        }
        if (SyncPopup.IsOpen) UpdateSyncControls();
        TickAutomaticSync();
    }
    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (allowClose) return;
        e.Cancel = true;
        if (!exitRequested && settings.KeepRunningInTray && desktop?.IsAvailable == true)
        {
            Hide(); SetStatus("트레이에서 계속 실행 중입니다. 트레이 메뉴에서 다시 열거나 종료할 수 있습니다."); return;
        }
        if (closePending) return;
        closePending = true;
        if (profileWindow is { } profileDialog) await profileDialog.StopAndCloseAsync();
        if (notesEditingWindow is { } editor) await editor.StopAndCloseAsync();
        if (webShareWindow is { } share) await share.StopAndCloseAsync();
        SetStatus("진행 중인 작업을 정리하고 종료하는 중…");
        workCancellation?.Cancel();
        if (runningWork is { } work) await work;
        while (transitioning) await Task.Delay(50);
        await StopRecordingAsync();
        waveformCancellation?.Cancel();
        await WaveformLoadTask;
        timer.Stop(); player.Dispose();
        desktop?.Dispose();
        allowClose = true;
        // Closing may run without any incomplete await; defer the second Close
        // until WPF has left the original Closing event.
        await Dispatcher.Yield(DispatcherPriority.Background);
        Close();
    }
    private static string FriendlyError(Exception ex) => ex switch
    {
        System.Runtime.InteropServices.COMException => "오디오 장치에 접근할 수 없습니다. Windows 설정 → 개인정보 및 보안 → 마이크에서 데스크톱 앱 접근을 허용하고 장치를 확인해 주세요.",
        UnauthorizedAccessException => "파일 또는 장치 접근 권한이 없습니다. 폴더 권한과 Windows 마이크 설정을 확인해 주세요.",
        InvalidDataException => ex.Message,
        IOException => "파일을 읽거나 저장할 수 없습니다. 저장 공간과 파일 사용 상태를 확인해 주세요.",
        _ => ex.Message
    };
}

internal sealed class WebShareWindow : Window
{
    private readonly Recording recording;
    private readonly MeetingNotes notes;
    private readonly AppSettings settings;
    private readonly Func<SyncConfiguration, HttpMessageHandler>? handlerFactory;
    private readonly Action<string> copyLink;
    private readonly CancellationTokenSource cancellation = new();
    private readonly TextBlock statusText = new() { TextWrapping = TextWrapping.Wrap, LineHeight = 20 };
    private readonly Grid linkRow = new() { Visibility = Visibility.Collapsed, Margin = new Thickness(0, 12, 0, 0) };
    private readonly TextBlock urlText = new() { TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), TextAlignment = TextAlignment.Left };
    private readonly Button urlButton = new() { ToolTip = "클릭하여 링크 복사", Cursor = Cursors.Hand };
    private readonly Button publishButton = new() { Content = "웹 링크 만들기", MinWidth = 110, IsEnabled = false };
    private readonly Button copyButton = new() { Content = "복사", ToolTip = "링크 복사", MinWidth = 56, IsEnabled = false };
    private readonly Button revokeButton = new() { Content = "공유 취소", MinWidth = 90, Visibility = Visibility.Collapsed };
    private readonly Button refreshButton = new() { Content = "상태 새로고침", HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
    private bool busy, closing, allowClose;
    private Task? closingTask;
    internal Task CurrentOperation { get; private set; } = Task.CompletedTask;
    internal string? CurrentUrl => currentUrl;
    private bool statusLoaded;
    private bool knownActive;
    private string? currentUrl;

    public WebShareWindow(Recording recording, MeetingNotes notes, AppSettings settings, Func<SyncConfiguration, HttpMessageHandler>? handlerFactory = null, Action<string>? copyLink = null)
    {
        this.recording = recording;
        this.notes = notes;
        this.settings = settings;
        this.handlerFactory = handlerFactory; this.copyLink = copyLink ?? Clipboard.SetText;
        NameScope.SetNameScope(this, new NameScope());
        foreach (var entry in new[] { ("PublishWebShareButton", publishButton), ("RevokeWebShareButton", revokeButton), ("CopyWebShareButton", copyButton), ("RefreshWebShareButton", refreshButton) }) RegisterName(entry.Item1, entry.Item2);
        Title = "웹 공유"; Width = 520; Height = 420; MinWidth = 460; MinHeight = 360;
        WindowStartupLocation = WindowStartupLocation.CenterOwner; ShowInTaskbar = false; WindowStyle = WindowStyle.None;
        Style = (Style)FindResource(typeof(Window));
        WindowChrome.SetWindowChrome(this, new WindowChrome { CaptionHeight = 44, ResizeBorderThickness = new Thickness(6), GlassFrameThickness = new Thickness(0), CornerRadius = new CornerRadius(10), UseAeroCaptionButtons = false });

        var root = new Border { BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10) };
        root.SetResourceReference(BorderBrushProperty, "Separator");
        root.SetResourceReference(BackgroundProperty, "WindowSurface");
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(44) });
        grid.RowDefinitions.Add(new RowDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.Child = grid;

        var header = new Grid();
        header.SetResourceReference(BackgroundProperty, "ToolbarSurface");
        var controls = new WindowControls { HorizontalAlignment = HorizontalAlignment.Left };
        WindowChrome.SetIsHitTestVisibleInChrome(controls, true);
        header.Children.Add(controls);
        header.Children.Add(new TextBlock { Text = "웹 공유", HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, FontWeight = FontWeights.SemiBold });
        grid.Children.Add(header);

        var body = new StackPanel { Margin = new Thickness(24) };
        body.Children.Add(new TextBlock { Text = recording.Title, FontSize = 18, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
        var explanation = new TextBlock
        {
            Text = "제목과 회의록 사본을 공유합니다. 링크를 가진 사람은 누구나 7일 동안 읽을 수 있습니다. 공유를 취소하면 링크 접근이 차단되지만, 다른 사람이 이미 저장한 사본은 되돌릴 수 없습니다.",
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20,
            Margin = new Thickness(0, 10, 0, 16)
        };
        explanation.SetResourceReference(TextBlock.ForegroundProperty, "Muted");
        body.Children.Add(explanation);
        body.Children.Add(statusText);
        linkRow.ColumnDefinitions.Add(new ColumnDefinition());
        linkRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        urlButton.SetResourceReference(StyleProperty, "LinkButton");
        urlButton.Content = urlText;
        urlButton.Click += Copy_Click;
        System.Windows.Automation.AutomationProperties.SetName(urlButton, "링크 주소 복사");
        copyButton.SetResourceReference(StyleProperty, "ToolbarButton");
        copyButton.VerticalAlignment = VerticalAlignment.Center;
        copyButton.Margin = new Thickness(8, 0, 0, 0);
        System.Windows.Automation.AutomationProperties.SetName(copyButton, "링크 복사");
        Grid.SetColumn(copyButton, 1);
        linkRow.Children.Add(urlButton);
        linkRow.Children.Add(copyButton);
        body.Children.Add(linkRow);
        body.Children.Add(refreshButton);
        refreshButton.Click += async (_, _) => await LoadStatusAsync();
        var scroll = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Grid.SetRow(scroll, 1); grid.Children.Add(scroll);

        var footer = new Border { Padding = new Thickness(24, 14, 24, 14), BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(BorderBrushProperty, "Separator");
        footer.SetResourceReference(BackgroundProperty, "ToolbarSurface");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        publishButton.SetResourceReference(StyleProperty, "PrimaryButton");
        publishButton.Click += Publish_Click;
        copyButton.Click += Copy_Click;
        revokeButton.Click += Revoke_Click;
        buttons.Children.Add(revokeButton);
        buttons.Children.Add(new Button { Content = "닫기", IsCancel = true, MinWidth = 70, Margin = new Thickness(8, 0, 0, 0) });
        buttons.Children.Add(publishButton); publishButton.Margin = new Thickness(8, 0, 0, 0);
        footer.Child = buttons;
        Grid.SetRow(footer, 2);
        grid.Children.Add(footer);

        Content = root;
        Loaded += async (_, _) => await LoadStatusAsync();
        Closing += async (_, e) =>
        {
            if (allowClose) return;
            e.Cancel = true; if (closing) return;
            await StopAndCloseAsync();
        };
        Closed += (_, _) => cancellation.Dispose();
    }

    internal Task StopAndCloseAsync() => closingTask ??= CloseCoreAsync();
    private async Task CloseCoreAsync()
    {
        if (allowClose) return;
        closing = true; cancellation.Cancel(); SetBusy(true);
        await CurrentOperation;
        allowClose = true; await Dispatcher.Yield(DispatcherPriority.Background); Close();
    }

    private WebShareClient CreateClient()
    {
        if (string.IsNullOrWhiteSpace(settings.SharingServerUrl))
            throw new InvalidOperationException("설정에서 웹 공유 서버 주소를 저장해 주세요.");
        if (!Uri.TryCreate(settings.SharingServerUrl, UriKind.Absolute, out var uri))
            throw new InvalidOperationException("웹 공유 서버 주소를 확인해 주세요.");
        var configuration = new SyncConfiguration(uri.AbsoluteUri, SettingsStore.ReadSharingToken(settings));
        return new WebShareClient(uri, configuration.Token, handlerFactory?.Invoke(configuration));
    }

    private async Task LoadStatusAsync()
    {
        if (busy || closing) return;
        currentUrl = null;
        linkRow.Visibility = Visibility.Collapsed;
        statusLoaded = false;
        await RunAsync("공유 상태를 확인하는 중…", async client =>
        {
            var status = await client.GetStatusAsync(recording.Id, cancellation.Token);
            currentUrl = status.Url;
            urlText.Text = currentUrl ?? "";
            linkRow.Visibility = currentUrl is null ? Visibility.Collapsed : Visibility.Visible;
            copyButton.Content = "복사";
            statusLoaded = true;
            knownActive = status.Active;
            if (status.Active)
                SetStatus("웹 링크가 활성화되어 있습니다." + ExpiryText(status.ExpiresAt));
            else
                SetStatus("현재 활성화된 웹 공유 링크가 없습니다.");
        });
    }

    private async void Publish_Click(object sender, RoutedEventArgs e)
    {
        if (knownActive || !statusLoaded || busy || closing) return;
        await RunAsync("회의록 스냅샷을 업로드하는 중…", async client =>
        {
            var publication = await client.PublishAsync(recording.Id, recording.Title, notes.Markdown, cancellation.Token);
            currentUrl = publication.Url;
            knownActive = true;
            urlText.Text = publication.Url;
            linkRow.Visibility = Visibility.Visible;
            copyButton.Content = "복사";
            SetStatus("웹 링크가 활성화되어 있습니다." + ExpiryText(publication.ExpiresAt));
        }, mutation: true);
    }

    private async void Revoke_Click(object sender, RoutedEventArgs e)
    {
        if (!knownActive || !statusLoaded || busy || closing) return;
        await RunAsync("공유를 취소하는 중…", async client =>
        {
            await client.RevokeAsync(recording.Id, cancellation.Token);
            currentUrl = null;
            knownActive = false;
            linkRow.Visibility = Visibility.Collapsed;
            SetStatus("공유를 취소했습니다.");
        }, mutation: true);
    }

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        if (currentUrl is null || busy || closing || !statusLoaded) return;
        try
        {
            copyLink(currentUrl);
            copyButton.Content = "복사됨";
            SetStatus("링크를 클립보드에 복사했습니다.");
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            SetStatus("클립보드를 사용할 수 없습니다. 다시 눌러 복사해 주세요.", true);
        }
    }

    private async Task RunAsync(string progress, Func<WebShareClient, Task> action, bool mutation = false)
    {
        if (busy || closing) return;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        CurrentOperation = completion.Task;
        SetBusy(true);
        SetStatus(progress);
        try
        {
            using var client = CreateClient();
            await action(client);
        }
        catch (OperationCanceledException) { SetStatus("웹 공유 작업을 취소했습니다.", true); }
        catch (Exception ex)
        {
            if (mutation) { statusLoaded = false; knownActive = false; currentUrl = null; linkRow.Visibility = Visibility.Collapsed; }
            SetStatus(ex.Message + (mutation ? " 상태 새로고침으로 서버의 결과를 확인해 주세요." : ""), true);
        }
        finally { SetBusy(closing); completion.TrySetResult(); }
    }

    private void SetBusy(bool busy)
    {
        this.busy = busy;
        publishButton.Visibility = knownActive ? Visibility.Collapsed : Visibility.Visible;
        publishButton.IsEnabled = !busy && statusLoaded && !knownActive;
        revokeButton.Visibility = knownActive ? Visibility.Visible : Visibility.Collapsed;
        revokeButton.IsEnabled = !busy && statusLoaded && knownActive;
        copyButton.IsEnabled = urlButton.IsEnabled = !busy && statusLoaded && currentUrl is not null;
        refreshButton.IsEnabled = !busy;
    }

    private void SetStatus(string text, bool error = false)
    {
        statusText.Text = text;
        statusText.SetResourceReference(TextBlock.ForegroundProperty, error ? "RecordRed" : "Muted");
    }

    private static string ExpiryText(DateTimeOffset? expiresAt)
        => expiresAt is null ? "" : $" 만료: {expiresAt.Value.LocalDateTime:yyyy.MM.dd HH:mm}";
}
