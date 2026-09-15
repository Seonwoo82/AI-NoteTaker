using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private ResolvedMeeting? meeting;
    private MeetingProfile meetingProfile = new();
    private bool loadingParticipants;

    private void LoadParticipants(Recording recording)
    {
        try { meetingProfile = new MeetingProfileStore(library.Root).Load(); } catch (Exception) { meetingProfile = new(); }
        try
        {
            meeting = new MeetingWorkspaceStore(library).Resolve(recording);
            RenderParticipants();
        }
        catch (Exception ex) { meeting = null; RenderParticipants(); ParticipantsStatus.Text = FriendlyError(ex); }
    }
    private void RenderParticipants()
    {
        loadingParticipants = true;
        string? previous = (ParticipantFilter.SelectedItem as ParticipantChoice)?.Id;
        string? previousPerson = (ParticipantPeople.SelectedItem as ParticipantChoice)?.Id;
        var choices = new List<ParticipantChoice> { new("*", "모든 참여자"), new("@own", "내 발화"), new("@unknown", "미지정") };
        if (meeting is not null) choices.AddRange(meeting.Transcript.Speakers.Select(s => new ParticipantChoice(s.Id, s.Name + (s.IsOwner ? " · 나" : ""))));
        ParticipantFilter.ItemsSource = choices; ParticipantFilter.SelectedItem = choices.FirstOrDefault(c => c.Id == previous) ?? choices[0];
        ParticipantPeople.ItemsSource = meeting?.Transcript.Speakers.Select(s =>
            new ParticipantChoice(s.Id, s.IsOwner ? s.Name + " · 나" : s.Name)).ToList();
        ParticipantPeople.SelectedItem = ParticipantPeople.Items.Cast<ParticipantChoice>().FirstOrDefault(p => p.Id == previousPerson) ?? ParticipantPeople.Items.Cast<ParticipantChoice>().FirstOrDefault();
        loadingParticipants = false;
        ParticipantsStatus.Text = meeting is null ? "참여자를 분석하면 발화 시간과 내용을 함께 볼 수 있습니다. 첫 실행에 약 47MB의 모델을 다운로드합니다." :
            $"{meeting.Transcript.Speakers.Count}개 화자 그룹 · {meeting.Transcript.Turns.Count}개 발화 · 미지정 {meeting.Transcript.Turns.Count(t => t.SpeakerId is null)}개" +
            (meeting.UnresolvedEditCount > 0 ? $" · 이전 수정 {meeting.UnresolvedEditCount}개는 현재 발화에 연결되지 않았습니다." : "");
        RefreshParticipantTurns(); UpdateParticipantControls();
    }
    private void RefreshParticipantTurns()
    {
        string choice = (ParticipantFilter.SelectedItem as ParticipantChoice)?.Id ?? "*";
        var turns = meeting?.Transcript.Turns.AsEnumerable() ?? [];
        if (choice == "@own") turns = meeting?.OwnTurns ?? [];
        else if (choice == "@unknown") turns = turns.Where(t => t.SpeakerId is null);
        else if (choice != "*") turns = turns.Where(t => t.SpeakerId == choice);
        ParticipantTurns.ItemsSource = turns.Select(t => new ParticipantTurnRow(t,
            meeting?.Transcript.Speakers.FirstOrDefault(s => s.Id == t.SpeakerId)?.Name ?? "미지정",
            string.Join(" · ", meetingProfile.Substitutions(t.Text).Select(s => $"표기 참고: {s.SourceText} → {s.DisplayText}")))).ToList();
    }
    private void ParticipantFilter_Changed(object sender, SelectionChangedEventArgs e) { if (!loadingParticipants && loaded) RefreshParticipantTurns(); }
    private void ParticipantSelection_Changed(object sender, SelectionChangedEventArgs e) { if (loaded) UpdateParticipantControls(); }
    private void UpdateParticipantControls()
    {
        if (AnalyzeParticipantsButton is null) return;
        bool idle = recorder is null && !transitioning && runningWork is null && !ProfileOpen && selected?.DeletedAt is null && selected is not null;
        AnalyzeParticipantsButton.IsEnabled = ParticipantCount.IsEnabled = idle;
        RenameParticipantButton.IsEnabled = MarkOwnerButton.IsEnabled = idle && meeting is not null && ParticipantPeople.SelectedItem is ParticipantChoice;
        AssignTurnButton.IsEnabled = PlayTurnButton.IsEnabled = idle && ParticipantTurns.SelectedItem is ParticipantTurnRow;
        PlayOwnTurnsButton.IsEnabled = idle && meeting?.OwnTurns.Count > 0;
        StopTurnsButton.IsEnabled = player.HasRangePlayback;
        CancelParticipantAnalysisButton.Visibility = runningWork is null ? Visibility.Collapsed : Visibility.Visible;
    }
    private async void AnalyzeParticipants_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        await AnalyzeParticipantsAsync(selected, ParticipantCount.SelectedIndex);
    }
    private async Task AnalyzeParticipantsAsync(Recording recording, int count = 0)
    {
        await RunWorkAsync(async token =>
        {
            StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
            var progress = new Progress<string>(message => { ParticipantsStatus.Text = message; SetStatus(message); });
            var service = new ParticipantAnalysisService(library, aiModelRoot, MeetingService());
            try
            {
                await service.AnalyzeAsync(recording, settings, settings.TranscriptionProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "", count, progress, token);
                SetStatus("참여자 분석을 저장했습니다. 이름과 잘못 구분된 발화를 확인해 주세요.");
            }
            finally { if (selected?.Id == recording.Id) { LoadDocuments(recording); LoadParticipants(recording); } }
        });
    }
    private void RenameParticipant_Click(object sender, RoutedEventArgs e)
    {
        if (ParticipantPeople.SelectedItem is not ParticipantChoice choice || meeting is null) return;
        var speaker = meeting.Transcript.Speakers.First(s => s.Id == choice.Id);
        var dialog = new RenameWindow(speaker.Name, "참여자 이름", "이름", 256) { Owner = this };
        if (dialog.ShowDialog() == true) SaveMeetingEdit("speakerName", speaker.Id, dialog.Result);
    }
    private void MarkOwner_Click(object sender, RoutedEventArgs e)
    {
        if (ParticipantPeople.SelectedItem is not ParticipantChoice choice || meeting is null) return;
        var speaker = meeting.Transcript.Speakers.First(s => s.Id == choice.Id);
        SaveMeetingEdit("speakerOwner", speaker.Id, speaker.IsOwner ? "false" : "true");
    }
    private void AssignTurn_Click(object sender, RoutedEventArgs e)
    {
        if (ParticipantTurns.SelectedItem is not ParticipantTurnRow row || meeting is null) return;
        var menu = new ContextMenu();
        var choices = new List<ParticipantChoice> { new("", "미지정"), new("owner", "나") };
        choices.AddRange(meeting.Transcript.Speakers.Where(s => s.Id != "owner").Select(s => new ParticipantChoice(s.Id, s.Name)));
        foreach (var choice in choices)
        {
            var item = new MenuItem { Header = choice.Name, IsCheckable = true, IsChecked = (row.Turn.SpeakerId ?? "") == choice.Id };
            item.Click += (_, _) => SaveMeetingEdit("turnSpeaker", row.Turn.Id, choice.Id); menu.Items.Add(item);
        }
        menu.PlacementTarget = AssignTurnButton; menu.IsOpen = true;
    }
    private void SaveMeetingEdit(string kind, string target, string value)
    {
        if (selected is null) return;
        try { new MeetingWorkspaceStore(library).Append(selected, kind, target, value); LoadParticipants(selected); SetStatus("수정했습니다. 다시 분석해도 수정 이력은 보존됩니다."); }
        catch (Exception ex) { SetStatus(FriendlyError(ex), true); }
    }
    private void PlayTurn_Click(object sender, RoutedEventArgs e) { if (ParticipantTurns.SelectedItem is ParticipantTurnRow row) PlayTurns([row.Turn]); }
    private void ParticipantTurn_DoubleClick(object sender, MouseButtonEventArgs e) { if (ParticipantTurns.SelectedItem is ParticipantTurnRow row) PlayTurns([row.Turn]); }
    private void PlayOwnTurns_Click(object sender, RoutedEventArgs e) { if (meeting is not null) PlayTurns(meeting.OwnTurns); }
    private void PlayTurns(IEnumerable<TranscriptTurn> turns)
    {
        if (recorder is not null || runningWork is not null) return;
        StopTurnPlayback();
        try { EnsurePlaybackLoaded(); player.PlayRanges(turns.Select(t => new AudioRange(t.Start, t.End))); UpdateParticipantControls(); }
        catch (Exception ex) { StopTurnPlayback(); SetStatus(FriendlyError(ex), true); }
    }
    private void StopTurns_Click(object sender, RoutedEventArgs e) => StopTurnPlayback();
    private void StopTurnPlayback()
    {
        player.StopRanges(); UpdateParticipantControls();
    }
    private void AdvanceTurnPlayback()
    {
        // PCM ranges advance inside the audio provider, independent of the UI timer.
        UpdateParticipantControls();
    }
    private sealed record ParticipantChoice(string Id, string Name);
    private sealed record ParticipantTurnRow(TranscriptTurn Turn, string Speaker, string GlossaryHint)
    {
        public string Time => $"{Recording.FormatTime(Turn.Start)} – {Recording.FormatTime(Turn.End)}";
        public string Text => Turn.Text;
    }
}
