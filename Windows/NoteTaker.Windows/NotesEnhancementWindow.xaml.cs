using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class NotesEnhancementWindow : Window
{
    private readonly Recording recording;
    private readonly AppSettings settings;
    private readonly LibraryStore library;
    private readonly string modelRoot;
    private CancellationTokenSource? cancellation;
    private MeetingEnhancementPreview? preview;
    private bool closing, allowClose;
    internal Func<AppSettings, string, ISummarizer>? ModelFactory { get; set; }
    internal Task LastOperation { get; private set; } = Task.CompletedTask;
    internal Exception? LastError { get; private set; }
    public bool Applied { get; private set; }
    public NotesEnhancementWindow(Recording recording, AppSettings settings, LibraryStore library, string modelRoot)
    {
        this.recording = recording; this.settings = settings; this.library = library; this.modelRoot = modelRoot;
        InitializeComponent();
        OriginalViewer.Document = MarkdownView.Render(new NotesDocumentStore(library).Load(recording)?.Markdown ?? "");
        PreviewViewer.Document = MarkdownView.Render("수정 요청을 입력하고 수정안을 만들어 주세요."); UpdateControls();
    }
    private void UpdateControls()
    {
        bool idle = cancellation is null && !closing;
        InstructionsBox.IsEnabled = idle; PreviewButton.IsEnabled = idle && !string.IsNullOrWhiteSpace(InstructionsBox.Text);
        ApplyButton.IsEnabled = idle && preview is not null;
        CancelPreviewButton.Visibility = cancellation is null ? Visibility.Collapsed : Visibility.Visible;
        DiscardButton.IsEnabled = !closing;
    }
    private void Instructions_Changed(object sender, TextChangedEventArgs e)
    {
        if (PreviewButton is null) return;
        if (preview is not null && InstructionsBox.Text.Trim() != preview.Instructions)
        { preview = null; PreviewViewer.Document = MarkdownView.Render("요청이 변경되었습니다. 수정안을 다시 만들어 주세요."); }
        UpdateControls();
    }
    private void Preview_Click(object sender, RoutedEventArgs e)
    {
        if (cancellation is not null || closing) return;
        LastOperation = GenerateAsync();
    }
    private async Task GenerateAsync()
    {
        cancellation = new(); preview = null; LastError = null; UpdateControls();
        try
        {
            var selection = AiProviders.EnhancementSettings(settings);
            if (ModelFactory is null && selection.SummaryProvider == "ollama") await LocalRuntime.StartOllamaAsync(modelRoot, selection, cancellation.Token);
            var candidate = await new MeetingNotesEditingService(library, ModelFactory).PreviewAsync(recording, settings, settings.SummaryProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "", InstructionsBox.Text,
                new Progress<string>(s => EditorStatus.Text = s), cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested(); preview = candidate;
            OriginalViewer.Document = MarkdownView.Render(candidate.Original.Markdown); PreviewViewer.Document = MarkdownView.Render(candidate.Markdown); PreviewTabs.SelectedIndex = 0;
            EditorStatus.Text = $"{candidate.ModelId} · 수정안을 확인한 뒤 적용해 주세요.";
        }
        catch (OperationCanceledException) { EditorStatus.Text = "생성을 취소했습니다. 현재 회의록은 유지됩니다."; }
        catch (Exception ex) { LastError = ex; EditorStatus.Text = ex.Message; }
        finally { cancellation.Dispose(); cancellation = null; UpdateControls(); }
    }
    private void Apply_Click(object sender, RoutedEventArgs e)
    {
        if (preview is null || cancellation is not null || closing) return;
        LastOperation = ApplyAsync(preview);
    }
    private async Task ApplyAsync(MeetingEnhancementPreview candidate)
    {
        cancellation = new(); LastError = null; UpdateControls();
        try { await new MeetingNotesEditingService(library).ApplyAsync(recording, candidate, cancellation.Token); Applied = true; allowClose = true; Close(); }
        catch (OperationCanceledException) { EditorStatus.Text = "적용을 취소했습니다."; }
        catch (Exception ex) { LastError = ex; preview = null; EditorStatus.Text = ex.Message; }
        finally { cancellation.Dispose(); cancellation = null; UpdateControls(); }
    }
    private void Cancel_Click(object sender, RoutedEventArgs e) => cancellation?.Cancel();
    private void Discard_Click(object sender, RoutedEventArgs e) => Close();
    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (allowClose) return;
        e.Cancel = true; await StopAndCloseAsync();
    }
    internal async Task StopAndCloseAsync()
    {
        if (closing) { await LastOperation; return; }
        closing = true; cancellation?.Cancel(); UpdateControls(); await LastOperation;
        allowClose = true; Close();
    }
}
