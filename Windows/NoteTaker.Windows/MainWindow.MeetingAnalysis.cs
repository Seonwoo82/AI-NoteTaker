using System.IO;
using System.Windows;
using System.Windows.Controls;
using NoteTaker.Core;

namespace NoteTaker.Windows;

public partial class MainWindow
{
    private bool renderingInsights;
    private List<MeetingBriefingSource> briefingSources = [];
    private HashSet<string> evidenceTurnIds = new(StringComparer.Ordinal);
    private Guid? evidenceRecordingId;
    internal Func<AppSettings, string, ISummarizer>? AnalysisModelFactory { get; set; }
    private sealed record InsightRow(string Title, string Body, string Meta, Guid RecordingId, List<string> TurnIds, string? ActionId = null);
    private static string MeetingLabel(string value) => value switch
    {
        "commitment" => "약속", "request" => "요청", "open" => "미완료", "done" => "완료", "dismissed" => "제외",
        "answered" => "답변됨", "partial" => "일부 답변", "unanswered" => "답변 없음", "uncertain" => "불확실",
        "decided" => "결정됨", "deferred" => "보류", "unresolved" => "미결정", "proposal" => "제안", "concern" => "우려", "decision" => "결정", "revised" => "수정", _ => value
    };
    private void RenderMeetingInsights(bool refreshBriefing = true)
    {
        if (MeetingActions is null || renderingInsights) return;
        renderingInsights = true;
        try
        {
            string? previousAction = (MeetingActions.SelectedItem as InsightRow)?.ActionId;
            var insights = meeting?.Source.Insights; int filter = InsightFilter.SelectedIndex;
            string Name(string? id) => meeting?.Transcript.Speakers.FirstOrDefault(s => s.Id == id)?.Name ?? "미지정";
            var ownSpeakers = meeting?.Transcript.Speakers.Where(s => s.IsOwner).Select(s => s.Id).ToHashSet(StringComparer.Ordinal) ?? [];
            var ownTurns = meeting?.OwnTurns.Select(t => t.Id).ToHashSet(StringComparer.Ordinal) ?? [];
            bool Related(IEnumerable<string> ids) => ids.Any(ownTurns.Contains);
            MeetingActions.ItemsSource = insights?.Actions.Where(a => filter != 1 || Related(a.EvidenceTurnIds) || ownSpeakers.Contains(a.ActorSpeakerId ?? "") || ownSpeakers.Contains(a.TargetSpeakerId ?? ""))
                .Where(a => filter != 2 || meeting!.ActionStates.GetValueOrDefault(a.Id, "open") == "open")
                .Select(a => new InsightRow(a.Text, $"담당: {Name(a.ActorSpeakerId)}" + (a.TargetSpeakerId is null ? "" : $" → 요청 대상: {Name(a.TargetSpeakerId)}"),
                    $"{MeetingLabel(a.Kind)} · {MeetingLabel(meeting!.ActionStates.GetValueOrDefault(a.Id, "open"))}" + (a.DueText is null ? "" : $" · 기한: {a.DueText}"), meeting!.Source.RecordingId, a.EvidenceTurnIds, a.Id)).ToList();
            MeetingActions.SelectedItem = MeetingActions.Items.Cast<InsightRow>().FirstOrDefault(a => a.ActionId == previousAction);
            MeetingQuestions.ItemsSource = insights?.Questions.Where(q => filter != 1 || Related(q.QuestionTurnIds.Concat(q.AnswerTurnIds))).Where(q => filter != 2 || q.Status != "answered")
                .Select(q => new InsightRow(q.Question, q.Answer ?? "확인된 답변이 없습니다.", MeetingLabel(q.Status), meeting!.Source.RecordingId, q.QuestionTurnIds.Concat(q.AnswerTurnIds).Distinct(StringComparer.Ordinal).ToList())).ToList();
            MeetingDecisions.ItemsSource = insights?.Decisions.Where(d => filter != 1 || Related(d.Steps.SelectMany(s => s.EvidenceTurnIds))).Where(d => filter != 2 || d.Status != "decided")
                .Select(d => new InsightRow(d.Topic, string.Join("\n\n", d.Steps.Select(s => $"{MeetingLabel(s.Kind)} · {Name(s.SpeakerId)}\n{s.Text}")), MeetingLabel(d.Status), meeting!.Source.RecordingId, d.Steps.SelectMany(s => s.EvidenceTurnIds).Distinct(StringComparer.Ordinal).ToList())).ToList();
            MeetingAnalysisStatus.Text = meeting is null ? "참여자 탭에서 발화를 준비한 뒤 회의를 분석해 주세요." :
                $"프로젝트: {(meeting.ProjectName.Length == 0 ? "미지정" : meeting.ProjectName)} · " + (insights is null ? "아직 회의 분석 결과가 없습니다." :
                $"약속·요청 {MeetingActions.Items.Count} · 질문 {MeetingQuestions.Items.Count} · 결정 {MeetingDecisions.Items.Count} · {meeting.Source.AnalysisModelId}");
            if (meeting?.UnresolvedEditCount > 0) MeetingAnalysisStatus.Text += $" · 이전 수정 {meeting.UnresolvedEditCount}개는 현재 항목에 연결되지 않았습니다.";
        }
        finally { renderingInsights = false; }
        UpdateMeetingControls(); if (refreshBriefing) RefreshBriefing();
    }
    private void UpdateMeetingControls()
    {
        if (AnalyzeMeetingButton is null) return;
        bool idle = recorder is null && !transitioning && runningWork is null && !ProfileOpen && selected is { DeletedAt: null };
        AnalyzeMeetingButton.IsEnabled = EditProjectButton.IsEnabled = idle && meeting is not null;
        ActionOpenButton.IsEnabled = ActionDoneButton.IsEnabled = ActionDismissButton.IsEnabled = idle && MeetingActions.SelectedItem is InsightRow { ActionId: not null };
        CancelMeetingButton.Visibility = runningWork is null ? Visibility.Collapsed : Visibility.Visible;
        MeetingSections.IsEnabled = idle;
    }
    private async void AnalyzeMeeting_Click(object sender, RoutedEventArgs e)
    {
        if (selected is null || meeting is null) return; var recording = selected;
        await AnalyzeMeetingAsync(recording);
    }
    private async Task AnalyzeMeetingAsync(Recording recording)
    {
        await RunWorkAsync(async token =>
        {
            StopTurnPlayback(); player.Dispose(); playbackLoaded = false;
            try
            {
                if (settings.SummaryProvider == "ollama") await LocalRuntime.StartOllamaAsync(aiModelRoot, settings, token);
                await new MeetingAnalysisService(library, AnalysisModelFactory).AnalyzeAsync(recording, settings, settings.SummaryProvider == "openrouter" ? SettingsStore.ReadKey(settings) : "",
                    new Progress<string>(message => { MeetingAnalysisStatus.Text = message; SetStatus(message); }), token);
                SetStatus("회의 분석을 저장했습니다. 근거 발화와 함께 확인해 주세요.");
            }
            finally { if (selected?.Id == recording.Id) LoadParticipants(recording); }
        });
    }
    private void InsightFilter_Changed(object sender, SelectionChangedEventArgs e) { if (loaded) RenderMeetingInsights(refreshBriefing: false); }
    private void MeetingAction_Changed(object sender, SelectionChangedEventArgs e) { if (loaded) UpdateMeetingControls(); }
    private void ActionState_Click(object sender, RoutedEventArgs e)
    {
        if (runningWork is not null || recorder is not null || MeetingActions.SelectedItem is not InsightRow { ActionId: not null } row || sender is not Button { Tag: string state }) return;
        SaveMeetingEdit("actionStatus", row.ActionId, state);
    }
    private void EditProject_Click(object sender, RoutedEventArgs e)
    {
        if (meeting is null || selected is null) return; var recording = selected;
        var dialog = new RenameWindow(meeting.ProjectName, "회의 프로젝트", "프로젝트명 · 비우면 연결 해제", 256, allowEmpty: true) { Owner = this };
        if (dialog.ShowDialog() == true) SaveMeetingEdit("projectName", "", dialog.Result, recording);
    }
    private void InsightEvidence_Click(object sender, RoutedEventArgs e) { if (sender is Button { Tag: InsightRow row }) OpenMeetingEvidence(row.RecordingId, row.TurnIds, false); }
    private void InsightListen_Click(object sender, RoutedEventArgs e) { if (sender is Button { Tag: InsightRow row }) OpenMeetingEvidence(row.RecordingId, row.TurnIds, true); }
    internal void OpenMeetingEvidence(Guid recordingId, IReadOnlyList<string> ids, bool play = false)
    {
        if (runningWork is not null || recorder is not null || transitioning || ProfileOpen) return;
        var target = recordings.FirstOrDefault(r => r.Id == recordingId && r.DeletedAt is null && !r.IsRecording);
        if (target is null) { SetStatus("원본 회의를 찾을 수 없습니다.", true); return; }
        if (selected?.Id != recordingId)
        {
            refreshingLibrary = true; SearchBox.Text = ""; FilterBox.SelectedIndex = 0; selectedFolder = null; ClearFolderSelection(); refreshingLibrary = false;
            FilterLibrary(recordingId);
        }
        else LoadParticipants(target);
        if (meeting is null) return;
        var known = meeting.Transcript.Turns.Select(t => t.Id).ToHashSet(StringComparer.Ordinal);
        if (ids.Count == 0 || ids.Any(id => !known.Contains(id))) { SetStatus("분석 이후 근거 발화가 변경되었습니다. 회의를 다시 분석해 주세요.", true); return; }
        evidenceRecordingId = recordingId; evidenceTurnIds = ids.ToHashSet(StringComparer.Ordinal);
        RenderParticipants(); ParticipantFilter.SelectedItem = ParticipantFilter.Items.Cast<ParticipantChoice>().First(c => c.Id == "@evidence");
        DetailPanel.SelectedIndex = 2;
        ParticipantTurns.SelectedIndex = 0;
        if (ParticipantTurns.SelectedItem is not null) ParticipantTurns.ScrollIntoView(ParticipantTurns.SelectedItem);
        if (play) PlayTurns(meeting.Transcript.Turns.Where(t => evidenceTurnIds.Contains(t.Id)));
    }
    private void RefreshBriefing()
    {
        if (BriefingProject is null) return;
        bool prior = renderingInsights; renderingInsights = true; int unreadable = 0;
        try
        {
            briefingSources = []; var store = new MeetingWorkspaceStore(library);
            foreach (var recording in recordings.Where(r => r.DeletedAt is null && !r.IsRecording))
            {
                try { if (store.Resolve(recording) is { } resolved) briefingSources.Add(new(recording, resolved)); }
                catch (Exception ex) when (ex is IOException or InvalidDataException or System.Text.Json.JsonException or UnauthorizedAccessException) { unreadable++; }
            }
            string? chosen = BriefingProject.SelectedItem as string;
            var projects = briefingSources.Select(s => s.Meeting.ProjectName.Trim()).Where(p => p.Length > 0).DistinctBy(MeetingBriefingBuilder.NormalizeProject).OrderBy(p => p, StringComparer.CurrentCulture).ToList();
            BriefingProject.ItemsSource = projects;
            BriefingProject.SelectedItem = projects.FirstOrDefault(p => p == chosen) ?? projects.FirstOrDefault(p => p == meeting?.ProjectName) ?? (projects.Count == 1 ? projects[0] : null);
            BriefingStatus.Text = projects.Count == 0 ? "회의에 프로젝트를 지정하면 이전 결정과 남은 일을 모아 볼 수 있습니다." : "최근 회의 순으로 결정, 미완료 업무, 미해결 질문을 각각 최대 12개씩 표시합니다.";
            if (unreadable > 0) BriefingStatus.Text += $" · 읽을 수 없는 회의 {unreadable}개는 원본을 보존하고 제외했습니다.";
        }
        finally { renderingInsights = prior; }
        RenderBriefing();
    }
    private void BriefingProject_Changed(object sender, SelectionChangedEventArgs e) { if (loaded && !renderingInsights) RenderBriefing(); }
    private void RenderBriefing()
    {
        var briefing = MeetingBriefingBuilder.Build(BriefingProject.SelectedItem as string ?? "", briefingSources);
        InsightRow Row(MeetingBriefingItem item, string section) => new(item.Text, "", section + " · " + item.RecordingTitle, item.RecordingId, item.TurnIds);
        BriefingItems.ItemsSource = briefing.Decisions.Select(i => Row(i, "최근 결정")).Concat(briefing.OpenActions.Select(i => Row(i, "미완료 업무"))).Concat(briefing.UnansweredQuestions.Select(i => Row(i, "미해결 질문"))).ToList();
    }
}
