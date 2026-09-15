namespace NoteTaker.Core;

public sealed record MeetingBriefingSource(Recording Recording, ResolvedMeeting Meeting);
public sealed record MeetingBriefingItem(string Id, Guid RecordingId, string RecordingTitle, string Text, List<string> TurnIds);
public sealed record MeetingBriefing(List<MeetingBriefingItem> Decisions, List<MeetingBriefingItem> OpenActions, List<MeetingBriefingItem> UnansweredQuestions);
public static class MeetingBriefingBuilder
{
    public const int MaximumItemsPerSection = 12;
    public static string NormalizeProject(string name) => MeetingProfile.Normalized(name);
    public static MeetingBriefing Build(string project, IEnumerable<MeetingBriefingSource> sources, Guid? excluding = null)
    {
        var result = new MeetingBriefing([], [], []); string normalized = NormalizeProject(project);
        if (normalized.Length == 0) return result;
        foreach (var source in sources.Where(s => s.Recording.DeletedAt is null && !s.Recording.IsRecording && s.Recording.Id != excluding && NormalizeProject(s.Meeting.ProjectName) == normalized)
            .OrderByDescending(s => s.Recording.CreatedAt).ThenByDescending(s => s.Recording.Id.ToString("D"), StringComparer.Ordinal))
        {
            var insights = source.Meeting.Source.Insights; if (insights is null) continue;
            MeetingBriefingItem Item(string kind, string id, string text, IEnumerable<string> turns) => new($"{source.Recording.Id:D}:{kind}:{id}", source.Recording.Id, source.Recording.Title, text, turns.Distinct(StringComparer.Ordinal).ToList());
            foreach (var decision in insights.Decisions.Take(MaximumItemsPerSection - result.Decisions.Count))
                result.Decisions.Add(Item("decision", decision.Id, decision.Topic + ": " + decision.Steps[^1].Text, decision.Steps.SelectMany(s => s.EvidenceTurnIds)));
            foreach (var action in insights.Actions.Where(a => source.Meeting.ActionStates.GetValueOrDefault(a.Id, "open") == "open").Take(MaximumItemsPerSection - result.OpenActions.Count))
                result.OpenActions.Add(Item("action", action.Id, action.Text, action.EvidenceTurnIds));
            foreach (var question in insights.Questions.Where(q => q.Status is "unanswered" or "uncertain").Take(MaximumItemsPerSection - result.UnansweredQuestions.Count))
                result.UnansweredQuestions.Add(Item("question", question.Id, question.Question, question.QuestionTurnIds));
        }
        return result;
    }
}
