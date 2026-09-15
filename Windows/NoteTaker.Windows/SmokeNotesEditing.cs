using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokeNotesEditing
{
    private sealed class FixtureModel(bool delay = false) : ISummarizer
    {
        public string Model => "ui-editing-fixture"; public int MaximumInputBytes => 12000;
        public async Task<AiText> CompleteAsync(string system, string text, CancellationToken token)
        {
            if (delay) await Task.Delay(30000, token);
            return new("# 출시 회의\n\n## 일정\n출시일은 목표이며 확정되지 않았습니다.\n\n## 예산\n300만 원입니다.", 0);
        }
        public void Dispose() { }
    }
    private static T Find<T>(FrameworkElement window, string name) where T : FrameworkElement => (T)window.FindName(name);
    private static void Click(FrameworkElement window, string name) => Find<Button>(window, name).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Require(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        for (int i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); if (child is T match) yield return match;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }
    private static async Task Editor(MainWindow window, Func<NotesEnhancementWindow, Task> exercise)
    {
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _ = window.Dispatcher.BeginInvoke(new Action(async () =>
        {
            var editor = Application.Current.Windows.OfType<NotesEnhancementWindow>().Single();
            try
            {
                Require(!Find<Button>(window, "RecordButton").IsEnabled, "Recording remained enabled while the editor was open.");
                await exercise(editor); completion.SetResult();
            }
            catch (Exception ex) { completion.SetException(ex); }
            finally { await editor.StopAndCloseAsync(); }
        }));
        Click(window, "EnhanceNotesButton"); await completion.Task;
    }
    public static async Task RunAsync(string output, string modelRoot)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        var settings = new AppSettings { KeepRunningInTray = false };
        new SettingsStore(library.Root).Save(settings);
        using var catalogClient = new AiModelCatalogClient(); var catalog = await catalogClient.FetchAsync(default);
        new AiModelCatalogStore(library.Root).Save(catalog);
        var originalSettings = settings with { SummaryProvider = "openrouter", SummaryModel = "custom/retained", EnhancementModel = "custom/enhance", ProtectedApiKey = SettingsStore.ProtectKey("fixture-only-not-a-real-key") };
        var dialog = new SettingsWindow(originalSettings, library.Root) { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false };
        var settingsWork = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        dialog.Loaded += async (_, _) =>
        {
            try
            {
                Find<TextBox>(dialog, "SummarySearchBox").Text = "no-matches-fixture";
                Require(Find<ComboBox>(dialog, "SummaryModelList").Items.Count == 0, "Search did not filter.");
                Require(Find<TextBox>(dialog, "SummaryModelBox").Text == "custom/retained", "Search erased an unknown model ID.");
                var candidate = catalog.Models.First(m => m.SupportsSummary);
                Find<TextBox>(dialog, "SummarySearchBox").Text = candidate.Id;
                var choices = Find<ComboBox>(dialog, "SummaryModelList"); choices.SelectedItem = choices.Items.Cast<AiModel>().First(m => m.Id == candidate.Id);
                Require(Find<TextBox>(dialog, "SummaryModelBox").Text == candidate.Id, "Catalog selection did not update the ID.");
                Find<TextBox>(dialog, "EnhancementModelBox").Text = candidate.Id;
                dialog.CatalogLoader = _ => throw new IOException("fixture offline"); Click(dialog, "RefreshModelsButton");
                Require(Find<TextBlock>(dialog, "CatalogStatus").Text.Contains("이전 선택"), "Failed refresh lost the previous catalog.");
                Require(new AiModelCatalogStore(library.Root).Load()!.Models.Count == catalog.Models.Count, "Failed refresh changed cache.");
                Find<CheckBox>(dialog, "DeleteKeyBox").IsChecked = true;
                Find<FrameworkElement>(dialog, "CloudModelCard").BringIntoView();
                await SmokeUi.CaptureAsync(dialog, Path.Combine(output, "models.png"));
                Click(dialog, "SaveSettingsButton");
                Require(dialog.Result.ProtectedApiKey is null && dialog.Result.SummaryModel == candidate.Id && dialog.Result.EnhancementModel == candidate.Id && dialog.Result.SummaryModelInfo?.Id == candidate.Id, "Deleting the key changed model selection.");
                settingsWork.SetResult();
            }
            catch (Exception ex) { settingsWork.SetException(ex); dialog.Close(); }
        };
        _ = dialog.ShowDialog(); await settingsWork.Task;

        var recording = new Recording { Title = "출시 회의 · 작성한 전사로 보완 검증", DurationSeconds = 1 }; library.Save(recording);
        using (var writer = new WaveFileWriter(library.AudioPath(recording.Id), new WaveFormat(16000, 16, 1))) writer.Write(new byte[32000], 0, 32000);
        string audioHash = await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default);
        var cache = new TranscriptCache(audioHash, "authored-fixture", "ko", ["출시 목표는 6월 20일입니다. 아직 확정한 일정은 아닙니다.", "예산은 300만 원입니다. 추가 승인은 다음 회의에서 논의하겠습니다."], true) { Source = "import" };
        JsonDisk.Write(library.TranscriptPath(recording.Id), cache);
        string transcriptOriginal = File.ReadAllText(library.TranscriptPath(recording.Id));
        string originalMarkdown = "# 출시 회의\n\n## 일정\n6월 20일 출시를 목표로 하고 있습니다.\n\n## 예산\n예산은 300만 원입니다. 추가 승인은 다음 회의에서 논의합니다.";
        var original = new MeetingNotes(originalMarkdown, DateTimeOffset.Now, "authored-fixture", null) { TranscriptHash = MeetingNotesService.TranscriptContentHash(cache) };
        JsonDisk.Write(library.NotesPath(recording.Id), original with { Markdown = "# C#\n```\n## 코드 안 제목\n```\n" + string.Concat(Enumerable.Range(0, 35).Select(i => $"## 동일 제목\n단락 {i}: 검토할 내용을 유지합니다.\n\n")) });
        var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, enableDesktopIntegration: false)
        { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false, Width = 1120, Height = 800 };
        window.Show(); window.ReloadLibrary(recording.Id);
        try
        {
            Find<TabControl>(window, "DetailPanel").SelectedIndex = 1; Find<TabControl>(window, "DocumentTabs").SelectedIndex = 0;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "contents-before.png"));
            var contents = Find<ComboBox>(window, "NotesContents");
            Require(contents.Items.Count == 36 && ((MarkdownView.Heading)contents.Items[0]).Label == "C#", "Contents mishandled fenced code or literal hashes.");
            contents.SelectedIndex = contents.Items.Count - 1;
            await window.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var scroll = Descendants<ScrollViewer>(Find<FlowDocumentScrollViewer>(window, "NotesViewer")).First();
            Require(scroll.VerticalOffset > 0, "Choosing the last duplicate heading did not scroll.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "contents-after.png"));
            JsonDisk.Write(library.NotesPath(recording.Id), original); window.LoadDocuments(recording);
            string originalJson = File.ReadAllText(library.NotesPath(recording.Id));
            window.NotesEditingModelFactory = (_, _) => new FixtureModel();
            await Editor(window, async editor =>
            {
                Find<TextBox>(editor, "InstructionsBox").Text = "확정된 일정과 목표를 구분해 주세요.";
                Click(editor, "PreviewButton"); await editor.LastOperation;
                Require(editor.LastError is null && Find<Button>(editor, "ApplyButton").IsEnabled, "Fixture preview failed.");
                Require(File.ReadAllText(library.NotesPath(recording.Id)) == originalJson, "Preview wrote notes before apply.");
                await SmokeUi.CaptureAsync(editor, Path.Combine(output, "preview.png"));
                Find<TextBox>(editor, "InstructionsBox").Text += " 예산도 유지하세요.";
                Require(!Find<Button>(editor, "ApplyButton").IsEnabled, "Edited instructions left an old preview applicable.");
            });
            Require(File.ReadAllText(library.NotesPath(recording.Id)) == originalJson, "Discard wrote notes.");
            window.NotesEditingModelFactory = (_, _) => new FixtureModel(true);
            await Editor(window, async editor =>
            {
                Find<TextBox>(editor, "InstructionsBox").Text = "취소 검증"; Click(editor, "PreviewButton"); Click(editor, "CancelPreviewButton"); await editor.LastOperation;
                Require(!Find<Button>(editor, "ApplyButton").IsEnabled && Find<TextBlock>(editor, "EditorStatus").Text.Contains("취소"), "Cancel left a preview applicable.");
            });
            Require(File.ReadAllText(library.NotesPath(recording.Id)) == originalJson, "Cancellation changed notes.");
            window.NotesEditingModelFactory = (_, _) => new FixtureModel();
            await Editor(window, async editor =>
            {
                Find<TextBox>(editor, "InstructionsBox").Text = "동시 수정 검증"; Click(editor, "PreviewButton"); await editor.LastOperation;
                JsonDisk.Write(library.NotesPath(recording.Id), original with { Markdown = "# 다른 창의 수정" });
                Click(editor, "ApplyButton"); await editor.LastOperation;
                Require(editor.LastError is InvalidOperationException && !editor.Applied, "Concurrent change was overwritten.");
            });
            Require(new NotesDocumentStore(library).Load(recording)!.Markdown == "# 다른 창의 수정", "Concurrent edit was lost.");
            JsonDisk.Write(library.NotesPath(recording.Id), original); window.LoadDocuments(recording); window.NotesEditingModelFactory = null;

            // Real default local model; authored text + silent WAV do not measure speech or meeting accuracy.
            await LocalRuntime.StartOllamaAsync(modelRoot, settings, default);
            Click(window, "CleanTranscriptButton"); await window.CurrentWork;
            Require(window.LastWorkError is null, "Real local cleanup failed: " + window.LastWorkError);
            var cleaned = new NotesDocumentStore(library).Load(recording)!;
            Require(cleaned.Cleanup?.ModelId == "qwen3.5:4b" && cleaned.Markdown == originalMarkdown && Find<TextBox>(window, "CleanedTranscriptBox").Text.Length > 0, "Cleanup compare view is missing or rewrote the notes.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "cleanup.png"));
            Require(cleaned.Original?.Transcript == string.Join("\n\n", cache.Chunks) && cleaned.Original.AudioHash == audioHash, "Cleanup did not retain its original source.");
            JsonDisk.Write(library.TranscriptPath(recording.Id), cache with { Chunks = ["이후에 다시 만든 전사문입니다."] }); window.LoadDocuments(recording);
            Require(Find<TextBox>(window, "CleanedTranscriptBox").Text.Length > 0 && Find<TextBlock>(window, "CleanupStatus").Text.Contains("생성 당시"), "Replacing a transcript hid or misidentified the original cleanup.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "cleanup-original-source.png"));
            File.WriteAllText(library.TranscriptPath(recording.Id), transcriptOriginal); window.LoadDocuments(recording);
            Find<TabControl>(window, "DocumentTabs").SelectedIndex = 0;
            await Editor(window, async editor =>
            {
                Find<TextBox>(editor, "InstructionsBox").Text = "6월 20일은 확정일이 아니라 목표라는 점을 일정 항목에 명확히 표시해 주세요. 예산과 추가 승인 논의는 유지해 주세요.";
                Click(editor, "PreviewButton"); await editor.LastOperation;
                Require(editor.LastError is null && Find<Button>(editor, "ApplyButton").IsEnabled, "Real local enhancement failed: " + editor.LastError);
                await SmokeUi.CaptureAsync(editor, Path.Combine(output, "local-preview.png")); Click(editor, "ApplyButton"); await editor.LastOperation;
                Require(editor.Applied, "Real local preview was not applied.");
            });
            var final = new NotesDocumentStore(library).Load(recording)!;
            Require(final.Enhancement?.ModelId == "qwen3.5:4b" && final.Cleanup is not null && final.Markdown.Contains("300") && final.Markdown.Contains("20") && final.Original?.Transcript == cleaned.Original?.Transcript, "Local output lost required fixture values or source.");
            Require(transcriptOriginal == File.ReadAllText(library.TranscriptPath(recording.Id)) && audioHash == await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "Source text or audio changed.");
            Appearance.Apply(true); window.Width = 850; window.Height = 650;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "notes-compact-dark.png"));
            JsonDisk.Write(Path.Combine(output, "result.json"), new { passed = true, textModels = catalog.Models.Count(m => m.SupportsSummary), speechModels = catalog.Models.Count(m => m.SupportsTranscription), sourcePreserved = true, model = final.Enhancement!.ModelId, fixture = library.Root, checks = new[] { "anonymous live model catalog", "model search and key deletion", "refresh failure preserves cache", "real heading scroll", "preview discard cancellation concurrent change", "real local cleanup and enhancement apply", "original transcript and audio unchanged" } });
        }
        finally { window.RequestExit(); window.Close(); }
    }
}
