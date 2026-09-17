using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using NAudio.Wave;
using NoteTaker.Core;
using NoteTaker.Windows.Components;

namespace NoteTaker.Windows;

internal static class SmokeMeetingAnalysis
{
    public static async Task RunAsync(string output, string modelRoot)
    {
        Directory.CreateDirectory(output); Appearance.Apply(false);
        var library = new LibraryStore(Path.Combine(output, "fixture-" + Guid.NewGuid().ToString("N")));
        new SettingsStore(library.Root).Save(new AppSettings());
        var recording = new Recording { Title = "제품 출시 회의 · 작성한 전사 검증", DurationSeconds = 30 };
        library.Save(recording);
        // Authored transcript + silent WAV exercise model/UI/navigation only, never microphone capture or speech accuracy.
        using (var writer = new WaveFileWriter(library.AudioPath(recording.Id), new WaveFormat(16000, 16, 1))) writer.Write(new byte[16000 * 2 * 30], 0, 16000 * 2 * 30);
        string[] speech = ["제가 금요일까지 견적서를 보내겠습니다.", "고맙습니다. 저는 다음 주 월요일까지 고객 인터뷰 5건을 정리하겠습니다.", "출시일은 언제로 정할까요?", "6월 20일에 출시하기로 합시다.", "네, 6월 20일 출시로 결정하겠습니다.", "300만 원의 광고 예산도 오늘 승인할까요?", "예산은 근거가 부족하니 다음 회의까지 보류하겠습니다.", "자동 이메일 발송 기능도 이번에 넣어 주세요.", "이번 출시에서는 자동 이메일 발송을 제외하기로 결정했습니다.", "고객 지원은 누가 담당할까요?"];
        var transcript = new MeetingTranscript(recording.Id, 1, "authored-qa-transcript", [new("speaker-a", "김민수", true), new("speaker-b", "박지영")],
            speech.Select((text, index) => new TranscriptTurn("turn-" + index, index * 3, index * 3 + 2.8, index % 2 == 0 ? "speaker-a" : "speaker-b", text)).ToList());
        var store = new MeetingWorkspaceStore(library);
        store.Save(recording, new(recording.Id, 1, 0, Guid.NewGuid(), "출시 준비", transcript, null, [], "fixture"), null);
        JsonDisk.Write(library.TranscriptPath(recording.Id), new TranscriptCache(await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "fixture", "ko", speech.ToList(), true) { Source = "import" });
        JsonDisk.Write(library.NotesPath(recording.Id), new MeetingNotes("# 기존 회의록\n\n분석 중에도 보존됩니다.", DateTimeOffset.Now, "fixture", null));
        string originalTranscript = File.ReadAllText(library.TranscriptPath(recording.Id)), originalNotes = File.ReadAllText(library.NotesPath(recording.Id));
        var window = new MainWindow(library, discoverDevices: false, aiModelRoot: modelRoot, enableDesktopIntegration: false)
        { Left = -20000, Top = -20000, WindowStartupLocation = WindowStartupLocation.Manual, ShowInTaskbar = false, Width = 1120, Height = 780 };
        window.AnalysisModelFactory = (settings, key) => new TracedModel(new OllamaSummarizer(settings, new TraceHttpHandler(output)), output);
        window.Show(); window.ReloadLibrary(recording.Id);
        try
        {
            var detail = (TabControl)window.FindName("DetailPanel"); detail.SelectedIndex = 3;
            var timer = Stopwatch.StartNew();
            ((Button)window.FindName("AnalyzeMeetingButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await window.CurrentWork;
            if (window.LastWorkError is not null) throw new InvalidOperationException("Real local meeting analysis failed.", window.LastWorkError);
            var document = store.Load(recording)!; var insights = document.Insights ?? throw new InvalidOperationException("No saved insights.");
            if (insights.Actions.Count < 2 || insights.Questions.Count < 2 || insights.Decisions.Count < 1) throw new InvalidOperationException("Fixture's actions/questions/decisions were not extracted.");
            if (document.AnalysisModelId != "qwen3.5:4b") throw new InvalidOperationException("Expected real default local model.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "actions.png"));
            var actions = (ListBox)window.FindName("MeetingActions"); actions.SelectedIndex = 0;
            ((Button)window.FindName("ActionDoneButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (store.Resolve(recording)!.ActionStates.GetValueOrDefault(insights.Actions[0].Id) != "done") throw new InvalidOperationException("UI action status did not persist.");
            ((ComboBox)window.FindName("InsightFilter")).SelectedIndex = 2;
            if (actions.Items.Count != insights.Actions.Count - 1) throw new InvalidOperationException("Open action filter did not remove completed action.");
            ((ComboBox)window.FindName("InsightFilter")).SelectedIndex = 0;
            var sections = (TabControl)window.FindName("MeetingSections"); sections.SelectedIndex = 1;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "questions.png"));
            sections.SelectedIndex = 2; await SmokeUi.CaptureAsync(window, Path.Combine(output, "decisions.png"));
            sections.SelectedIndex = 3;
            if ((string?)((ComboBox)window.FindName("BriefingProject")).SelectedItem != "출시 준비") throw new InvalidOperationException("Single project was not selected automatically.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "briefing.png"));
            await EditProject(window, "검증 프로젝트", Path.Combine(output, "project-editor.png"));
            if (store.Resolve(recording)!.ProjectName != "검증 프로젝트") throw new InvalidOperationException("Project editor did not save.");
            await EditProject(window, "", null);
            if (store.Resolve(recording)!.ProjectName != "" || ((ComboBox)window.FindName("BriefingProject")).Items.Count != 0) throw new InvalidOperationException("Empty project did not detach the meeting.");
            await EditProject(window, "출시 준비", null);
            window.OpenMeetingEvidence(recording.Id, insights.Questions[0].QuestionTurnIds.Concat(insights.Questions[0].AnswerTurnIds).Distinct().ToList());
            if (detail.SelectedIndex != 2 || ((ListBox)window.FindName("ParticipantTurns")).Items.Count != insights.Questions[0].QuestionTurnIds.Concat(insights.Questions[0].AnswerTurnIds).Distinct().Count()) throw new InvalidOperationException("Evidence did not filter exact original turns.");
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "evidence.png"));
            Appearance.Apply(true); window.Width = 850; window.Height = 640; detail.SelectedIndex = 3; sections.SelectedIndex = 2;
            await SmokeUi.CaptureAsync(window, Path.Combine(output, "decisions-compact-dark.png"));
            // A second recording proves that project evidence can cross a sidebar folder/search boundary.
            var other = new Recording { Title = "다음 회의", DurationSeconds = 1 }; library.Save(other);
            using (var writer = new WaveFileWriter(library.AudioPath(other.Id), new WaveFormat(16000, 16, 1))) writer.Write(new byte[32000], 0, 32000);
            store.Save(other, new(other.Id, 1, 0, Guid.NewGuid(), "다음 회의 기존 프로젝트", new(other.Id, 1, "fixture", [], []), null, [], "fixture"), null);
            window.ReloadLibrary(other.Id); ((TextBox)window.FindName("SearchBox")).Text = "다음 회의";
            window.OpenMeetingEvidence(recording.Id, insights.Actions[0].EvidenceTurnIds);
            if (((Recording)((ListBox)window.FindName("RecordingList")).SelectedItem).Id != recording.Id) throw new InvalidOperationException("Cross-meeting source navigation failed.");
            await EditProject(window, "처음 회의에만 저장", null, () => window.ReloadLibrary(other.Id));
            if (store.Resolve(recording)!.ProjectName != "처음 회의에만 저장" || store.Resolve(other)!.ProjectName != "다음 회의 기존 프로젝트") throw new InvalidOperationException("Project dialog saved into a newly selected meeting.");
            if (originalTranscript != File.ReadAllText(library.TranscriptPath(recording.Id)) || originalNotes != File.ReadAllText(library.NotesPath(recording.Id))) throw new InvalidOperationException("Existing transcript or notes changed.");
            JsonDisk.Write(Path.Combine(output, "result.json"), new { Passed = true, Model = document.AnalysisModelId, ElapsedSeconds = timer.Elapsed.TotalSeconds, Actions = insights.Actions.Count, Questions = insights.Questions.Count, Decisions = insights.Decisions.Count, AuthoredTextFixture = true, MicrophoneOrAudioPlayback = false, Evidence = "Actual WPF clicks, local Qwen response, action edit/filter, project default, exact evidence and cross-recording navigation, original files retained." });
            JsonDisk.Write(Path.Combine(output, "analysis.json"), document);
        }
        finally { window.RequestExit(); window.Close(); }
    }
    private static async Task EditProject(MainWindow window, string name, string? capture, Action? beforeSave = null)
    {
        Task? operation = null;
        var dispatch = window.Dispatcher.InvokeAsync(() => operation = FillAsync());
        async Task FillAsync()
        {
            var dialog = Application.Current.Windows.OfType<RenameWindow>().Single();
            Descendants<TextBox>(dialog).Single().Text = name;
            if (capture is not null) await SmokeUi.CaptureAsync(dialog, capture);
            beforeSave?.Invoke();
            Descendants<Button>(dialog).Single(b => b.Content as string == "저장").RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        }
        ((Button)window.FindName("EditProjectButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await dispatch; if (operation is not null) await operation;
    }
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T item) yield return item;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var descendant in Descendants<T>(child)) yield return descendant;
    }
    private sealed class TracedModel(ISummarizer model, string output) : IStructuredSummarizer
    {
        public string Model => model.Model; public int MaximumInputBytes => model.MaximumInputBytes;
        public async Task<AiText> CompleteAsync(string system, string text, CancellationToken token)
        {
            var response = await model.CompleteAsync(system, text, token);
            File.WriteAllText(Path.Combine(output, "model-response-" + Guid.NewGuid().ToString("N") + ".txt"), response.Text); return response;
        }
        public async Task<AiText> CompleteStructuredAsync(string system, string text, System.Text.Json.JsonElement schema, CancellationToken token)
        {
            var response = await ((IStructuredSummarizer)model).CompleteStructuredAsync(system, text, schema, token);
            File.WriteAllText(Path.Combine(output, "model-response-" + Guid.NewGuid().ToString("N") + ".txt"), response.Text); return response;
        }
        public void Dispose() => model.Dispose();
    }
    private sealed class TraceHttpHandler(string output) : System.Net.Http.DelegatingHandler(new System.Net.Http.HttpClientHandler { UseProxy = false, UseCookies = false, AllowAutoRedirect = false })
    {
        protected override async Task<System.Net.Http.HttpResponseMessage> SendAsync(System.Net.Http.HttpRequestMessage request, CancellationToken token)
        {
            var response = await base.SendAsync(request, token);
            File.WriteAllText(Path.Combine(output, "http-response-" + Guid.NewGuid().ToString("N") + ".json"), await response.Content.ReadAsStringAsync(token));
            return response;
        }
    }
}
