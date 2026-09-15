using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class ProfileWindow : Window
{
    private readonly MeetingProfileStore store;
    private readonly VoiceEnrollmentSession enrollment;
    private readonly string? microphoneId;
    private MeetingProfile profile;
    private string? profileRevision;
    private readonly ObservableCollection<EditableTerm> terms = [];
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private CancellationTokenSource? operationCancellation;
    private Task operation = Task.CompletedTask;
    private bool busy, cancelling, closing, allowClose;
    private Task? closingTask;
    public bool Changed { get; private set; }
    internal Task CurrentOperation => operation;
    internal Exception? LastError { get; private set; }

    public ProfileWindow(string root, string modelRoot, string? microphoneId, Func<IRecordingSession>? recordingFactory = null)
    {
        this.microphoneId = microphoneId; store = new(root); enrollment = new(root, modelRoot, recordingFactory);
        profile = store.Load(); profileRevision = store.ProfileRevision;
        InitializeComponent(); ProfileNameBox.Text = profile.DisplayName; ProfileAliasesBox.Text = string.Join(", ", profile.Aliases); ProfileRoleBox.Text = profile.Role; AutoAnalyzeBox.IsChecked = profile.AutomaticallyAnalyze;
        foreach (var term in profile.Terms) terms.Add(new(term)); GlossaryGrid.ItemsSource = terms;
        TermCategoryColumn.ItemsSource = new[] { new Category("general", "일반"), new("person", "이름"), new("organization", "회사"), new("project", "프로젝트"), new("abbreviation", "약어") };
        RefreshVoice(); timer.Tick += Timer_Tick; timer.Start();
    }
    private void RefreshVoice()
    {
        try { var voice = store.LoadVoice(); VoiceProfileStatus.Text = voice is null ? "아직 등록하지 않았습니다" : $"목소리 등록됨 · {voice.EnrolledAt.LocalDateTime:yyyy.MM.dd HH:mm}"; }
        catch (Exception ex) { VoiceProfileStatus.Text = "이 목소리 프로필은 다시 등록해야 합니다."; ProfileStatus.Text = ex.Message; }
        StartEnrollmentButton.Content = File.Exists(store.VoicePath) ? "목소리 다시 등록" : "목소리 녹음 시작";
        EnrollmentClock.Text = $"{Recording.FormatTime(enrollment.Duration)} / 00:30"; EnrollmentLevel.Value = enrollment.Level; UpdateControls();
    }
    private void UpdateControls()
    {
        bool active = enrollment.IsRecording;
        bool idle = !busy && !cancelling && !closing;
        StartEnrollmentButton.IsEnabled = idle && !active;
        FinishEnrollmentButton.IsEnabled = idle && active && enrollment.Duration >= 10;
        CancelEnrollmentButton.IsEnabled = (busy || active) && !closing && !cancelling;
        DeleteVoiceButton.IsEnabled = idle && !active && File.Exists(store.VoicePath);
        SaveProfileButton.IsEnabled = idle && !active;
        GlossaryGrid.IsEnabled = idle && !active;
    }
    private void StartEnrollment_Click(object sender, RoutedEventArgs e) => Begin(async token =>
    {
        await enrollment.StartAsync(microphoneId, new Progress<string>(s => ProfileStatus.Text = s), token);
        ProfileStatus.Text = "마이크 녹음 중입니다. 예문을 자연스럽게 읽어 주세요.";
    });
    private void FinishEnrollment_Click(object sender, RoutedEventArgs e) => FinishEnrollment();
    private void FinishEnrollment() => Begin(async token =>
    {
        await enrollment.FinishAsync(new Progress<string>(s => ProfileStatus.Text = s), token);
        Changed = true; ProfileStatus.Text = "목소리를 등록했습니다. 등록용 녹음은 삭제했습니다."; RefreshVoice();
    });
    private void Begin(Func<CancellationToken, Task> action)
    {
        if (busy || cancelling || closing) return; busy = true; LastError = null; operationCancellation = new(); UpdateControls();
        operation = RunAsync(action, operationCancellation);
    }
    private async Task RunAsync(Func<CancellationToken, Task> action, CancellationTokenSource cancellation)
    {
        try { await action(cancellation.Token); }
        catch (OperationCanceledException) { ProfileStatus.Text = "등록을 취소했습니다. 이전 목소리 프로필은 유지됩니다."; }
        catch (Exception ex) { LastError = ex; ProfileStatus.Text = ex.Message; }
        finally
        {
            try { if (cancellation.IsCancellationRequested) await enrollment.DisposeAsync(); }
            catch (Exception ex) { LastError = ex; ProfileStatus.Text = ex.Message; }
            finally { cancellation.Dispose(); operationCancellation = null; busy = false; UpdateControls(); }
        }
    }
    private void CancelEnrollment_Click(object sender, RoutedEventArgs e)
    {
        if (cancelling || closing) return;
        cancelling = true; operationCancellation?.Cancel(); UpdateControls(); operation = CancelCoreAsync(operation);
    }
    private async Task CancelCoreAsync(Task previous)
    {
        try { await previous; await enrollment.DisposeAsync(); ProfileStatus.Text = "등록을 취소했습니다. 이전 목소리 프로필은 유지됩니다."; }
        catch (Exception ex) { LastError = ex; ProfileStatus.Text = ex.Message; }
        finally { cancelling = false; RefreshVoice(); }
    }
    private void Timer_Tick(object? sender, EventArgs e)
    {
        EnrollmentClock.Text = $"{Recording.FormatTime(enrollment.Duration)} / 00:30"; EnrollmentLevel.Value = enrollment.Level;
        UpdateControls();
        if (!busy && !cancelling && !closing && enrollment.IsRecording)
        {
            if (enrollment.Failure is not null) { string failure = enrollment.Failure; Begin(async _ => { await enrollment.DisposeAsync(); ProfileStatus.Text = failure; RefreshVoice(); }); }
            else if (enrollment.Duration >= 30) FinishEnrollment();
        }
    }
    private void DeleteVoice_Click(object sender, RoutedEventArgs e)
    {
        try { store.DeleteVoice(store.VoiceRevision); Changed = true; ProfileStatus.Text = "이 PC의 목소리 프로필을 삭제했습니다."; RefreshVoice(); }
        catch (Exception ex) { ProfileStatus.Text = ex.Message; }
    }
    private void DeleteTerm_Click(object sender, RoutedEventArgs e)
    {
        if (GlossaryGrid.SelectedItem is EditableTerm term) terms.Remove(term);
    }
    private void SaveProfile_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            GlossaryGrid.CommitEdit(DataGridEditingUnit.Cell, true); GlossaryGrid.CommitEdit(DataGridEditingUnit.Row, true);
            var changed = profile with { DisplayName = ProfileNameBox.Text.Trim(), Aliases = ProfileAliasesBox.Text.Split([',', '\n'], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries).ToList(),
                Role = ProfileRoleBox.Text.Trim(), AutomaticallyAnalyze = AutoAnalyzeBox.IsChecked == true,
                Terms = terms.Where(t => t.Term.Length > 0 || t.SpokenAs.Length > 0 || t.Meaning.Length > 0).Select(t => t.ToTerm()).ToList() };
            profile = store.Save(changed, profileRevision); profileRevision = store.ProfileRevision; Changed = true;
            ProfileStatus.Text = "이름과 용어를 저장했습니다.";
        }
        catch (Exception ex) { LastError = ex; ProfileStatus.Text = ex.Message; }
    }
    private void CloseProfile_Click(object sender, RoutedEventArgs e) => Close();
    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (allowClose) return; e.Cancel = true; await StopAndCloseAsync();
    }
    internal Task StopAndCloseAsync() => closingTask ??= CloseCoreAsync();
    private async Task CloseCoreAsync()
    {
        closing = true; timer.Stop(); UpdateControls(); operationCancellation?.Cancel(); await operation; await enrollment.DisposeAsync();
        allowClose = true; await Dispatcher.Yield(DispatcherPriority.Background); Close();
    }
    public sealed class EditableTerm
    {
        public Guid Id { get; set; } = Guid.NewGuid();
        public string Term { get; set; } = "";
        public string SpokenAs { get; set; } = "";
        public string Meaning { get; set; } = "";
        public string Category { get; set; } = "general";
        public EditableTerm() { }
        public EditableTerm(GlossaryTerm term) { Id = term.Id; Term = term.Term; SpokenAs = term.SpokenAs; Meaning = term.Meaning; Category = term.Category; }
        public GlossaryTerm ToTerm() => new(Id, Term.Trim(), SpokenAs.Trim(), Meaning.Trim(), Category);
    }
    private sealed record Category(string Id, string Name);
}
