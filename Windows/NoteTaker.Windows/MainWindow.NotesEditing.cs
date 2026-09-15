using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private NotesEnhancementWindow? notesEditingWindow;
    private Dictionary<string, string>? cleanedTurnText;
    private string cleanedTranscriptText = "";
    internal Func<AppSettings, string, ISummarizer>? NotesEditingModelFactory { get; set; }
    private void RenderNotes(string markdown)
    {
        NotesViewer.Document = MarkdownView.Render(markdown, out var headings);
        NotesContents.ItemsSource = headings; NotesContents.SelectedIndex = -1; NotesContents.IsEnabled = headings.Count > 0;
    }
    private void NotesContents_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (NotesContents.SelectedItem is MarkdownView.Heading heading) heading.Paragraph.BringIntoView();
    }
    private void LoadCleanup(TranscriptCache? cache)
    {
        cleanedTranscriptText = ""; cleanedTurnText = null;
        CleanupStatus.Text = notes?.CleanupNotice ?? "원문은 ‘전사문’ 탭에서 확인할 수 있습니다. 전사 정리는 회의록 생성 시 자동으로 실행하거나 다시 요청할 수 있습니다.";
        if (notes?.Cleanup is { } cleanup && (notes.Original is not null || cache?.Complete == true))
        {
            try
            {
                string originalText = notes.Original?.Transcript ?? string.Join("\n\n", cache!.Chunks);
                var originalSpeakers = notes.Original is { } source ? source.Speakers : meeting?.Transcript;
                cleanup.Validate(CleanupSource.Make(originalText, originalSpeakers, cleanup.SourceKind));
                cleanedTranscriptText = cleanup.MeetingText(originalSpeakers);
                if (cleanup.SourceKind == "speakers" && meeting?.Transcript is { } current && CleanupSource.Make(originalText, current, "speakers").Hash == cleanup.SourceHash) cleanedTurnText = cleanup.TextOverrides;
                CleanupStatus.Text = $"{cleanup.ModelId} · 원문을 보존한 정리본입니다. 발화 내용은 원문과 함께 확인해 주세요.";
                if (cache is not null && notes.TranscriptHash != MeetingNotesService.TranscriptContentHash(cache)) CleanupStatus.Text += " 현재 전사문과 다른, 회의록 생성 당시의 원문을 정리한 결과입니다.";
            }
            catch (Exception) { CleanupStatus.Text = "전사 원문이 바뀌어 이전 정리본을 표시하지 않습니다. ‘전사 다시 정리’를 실행해 주세요."; }
        }
        CleanedTranscriptBox.Text = cleanedTranscriptText;
        CleanedTurnsBox.IsEnabled = cleanedTurnText is not null;
        if (cleanedTurnText is null) CleanedTurnsBox.IsChecked = false;
        RefreshParticipantTurns();
    }
    private void CleanedTurns_Changed(object sender, RoutedEventArgs e) { if (loaded) RefreshParticipantTurns(); }
    private void EnhanceNotes_Click(object sender, RoutedEventArgs e)
    {
        if (selected is not { DeletedAt: null } recording || notes is null || recorder is not null || runningWork is not null || transitioning || ModalOperationOpen) return;
        try
        {
            StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
            notesEditingWindow = new(recording, settings, library, aiModelRoot) { Owner = this, ModelFactory = NotesEditingModelFactory };
            UpdateControls(); _ = notesEditingWindow.ShowDialog();
            if (notesEditingWindow.Applied) SetStatus("보완한 회의록을 적용했습니다.");
        }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
        finally { notesEditingWindow = null; if (selected?.Id == recording.Id) LoadDocuments(recording); UpdateControls(); }
    }
    private async void CleanTranscript_Click(object sender, RoutedEventArgs e)
    {
        if (selected is not { DeletedAt: null } recording || notes is null || ModalOperationOpen) return;
        await RunWorkAsync(async token =>
        {
            try
            {
                if (NotesEditingModelFactory is null && settings.SummaryProvider == "ollama") await LocalRuntime.StartOllamaAsync(aiModelRoot, settings, token);
                await new MeetingNotesEditingService(library, NotesEditingModelFactory).CleanAsync(recording, settings,
                    settings.SummaryProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "", new Progress<string>(s => SetStatus(s)), token);
                SetStatus("전사를 정리했습니다. 원문과 회의록 내용은 유지됩니다.");
            }
            finally { if (selected?.Id == recording.Id) { LoadDocuments(recording); DocumentTabs.SelectedIndex = 2; } }
        });
    }
}
