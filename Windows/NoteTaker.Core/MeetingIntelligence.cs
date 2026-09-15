using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NoteTaker.Core;

// Property names are the shared Apple/Cloudflare schema, including capitalized ID suffixes.
public sealed record MeetingSpeaker(string Id, string Name, bool IsOwner = false, bool ManuallyAssigned = false);
public sealed record TranscriptTurn(string Id, double Start, double End,
    [property: JsonPropertyName("speakerID")] string? SpeakerId, string Text);
public sealed record MeetingTranscript(
    [property: JsonPropertyName("recordingID")] Guid RecordingId, int AudioVersion,
    [property: JsonPropertyName("transcriptionModelID")] string TranscriptionModelId,
    List<MeetingSpeaker> Speakers, List<TranscriptTurn> Turns)
{
    public int SchemaVersion { get; init; } = 1;
    public void Validate(double duration)
    {
        MeetingValidation.Require(SchemaVersion == 1 && RecordingId != Guid.Empty && AudioVersion >= 1 && double.IsFinite(duration) && duration >= 0);
        MeetingValidation.Text(TranscriptionModelId, 256);
        MeetingValidation.Require(Speakers is { Count: <= 64 } && Turns is { Count: <= 20000 });
        var speakerIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var speaker in Speakers!)
        {
            MeetingValidation.Require(speaker is not null);
            MeetingValidation.Text(speaker!.Id, 128); MeetingValidation.Text(speaker.Name, 4000, requireTrimmed: false);
            MeetingValidation.Require(speakerIds.Add(speaker.Id));
        }
        var turnIds = new HashSet<string>(StringComparer.Ordinal); double previous = 0;
        foreach (var turn in Turns!)
        {
            MeetingValidation.Require(turn is not null);
            MeetingValidation.Text(turn!.Id, 128); MeetingValidation.Text(turn.Text, 4000, requireTrimmed: false);
            MeetingValidation.Require(turnIds.Add(turn.Id) && double.IsFinite(turn.Start) && double.IsFinite(turn.End) &&
                turn.Start >= previous && turn.Start >= 0 && turn.End > turn.Start && turn.End <= duration && (turn.SpeakerId is null || speakerIds.Contains(turn.SpeakerId)));
            previous = turn.Start;
        }
    }
}
public sealed record MeetingAction(string Id, string Kind, string Text,
    [property: JsonPropertyName("actorSpeakerID")] string? ActorSpeakerId,
    [property: JsonPropertyName("targetSpeakerID")] string? TargetSpeakerId, string? DueText,
    [property: JsonPropertyName("evidenceTurnIDs")] List<string> EvidenceTurnIds);
public sealed record MeetingQuestion(string Id, string Question,
    [property: JsonPropertyName("questionTurnIDs")] List<string> QuestionTurnIds, string? Answer,
    [property: JsonPropertyName("answerTurnIDs")] List<string> AnswerTurnIds, string Status);
public sealed record MeetingDecisionStep(string Kind, string Text,
    [property: JsonPropertyName("speakerID")] string? SpeakerId,
    [property: JsonPropertyName("evidenceTurnIDs")] List<string> EvidenceTurnIds);
public sealed record MeetingDecision(string Id, string Topic, string Status, List<MeetingDecisionStep> Steps);
public sealed record MeetingInsights(List<MeetingAction> Actions, List<MeetingQuestion> Questions, List<MeetingDecision> Decisions)
{
    public int SchemaVersion { get; init; } = 1;
    public void Validate(MeetingTranscript transcript)
    {
        MeetingValidation.Require(SchemaVersion == 1 && Actions is { Count: <= 200 } && Questions is { Count: <= 200 } && Decisions is { Count: <= 200 });
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var speakers = transcript.Speakers.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        var turns = transcript.Turns.ToDictionary(t => t.Id, StringComparer.Ordinal);
        void Id(string id) { MeetingValidation.Text(id, 128); MeetingValidation.Require(ids.Add(id)); }
        void Speaker(string? id) => MeetingValidation.Require(id is null || speakers.Contains(id));
        void Evidence(List<string>? values, bool allowEmpty = false) => MeetingValidation.Require(values is not null &&
            (allowEmpty || values.Count > 0) && values.Count <= 20000 && values.Distinct(StringComparer.Ordinal).Count() == values.Count && values.All(v => v is not null && turns.ContainsKey(v)));
        foreach (var action in Actions!)
        {
            MeetingValidation.Require(action is not null); Id(action!.Id); MeetingValidation.Text(action.Text, 4000);
            MeetingValidation.Require(action.Kind is "commitment" or "request"); Speaker(action.ActorSpeakerId); Speaker(action.TargetSpeakerId); Evidence(action.EvidenceTurnIds);
            if (action.DueText is { } due)
            {
                MeetingValidation.Text(due, 4000);
                MeetingValidation.Require(action.EvidenceTurnIds.Any(id => CultureInfo.InvariantCulture.CompareInfo.IndexOf(turns[id].Text, due.Trim(), CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace) >= 0));
            }
        }
        foreach (var question in Questions!)
        {
            MeetingValidation.Require(question is not null); Id(question!.Id); MeetingValidation.Text(question.Question, 4000);
            Evidence(question.QuestionTurnIds); Evidence(question.AnswerTurnIds, true);
            MeetingValidation.Require(question.Status is "answered" or "partial" or "unanswered" or "uncertain");
            if (question.Answer is not null) MeetingValidation.Text(question.Answer, 4000);
            if (question.Status is "answered" or "partial") MeetingValidation.Require(question.Answer is not null && question.AnswerTurnIds.Count > 0);
            if (question.Status == "unanswered") MeetingValidation.Require(question.Answer is null && question.AnswerTurnIds.Count == 0);
            if (question.Status == "uncertain" && question.Answer is not null) MeetingValidation.Require(question.AnswerTurnIds.Count > 0);
        }
        foreach (var decision in Decisions!)
        {
            MeetingValidation.Require(decision is not null); Id(decision!.Id); MeetingValidation.Text(decision.Topic, 4000);
            MeetingValidation.Require(decision.Status is "decided" or "deferred" or "unresolved" && decision.Steps is { Count: > 0 and <= 30 });
            foreach (var step in decision.Steps!)
            {
                MeetingValidation.Require(step is not null); MeetingValidation.Text(step!.Text, 4000);
                MeetingValidation.Require(step.Kind is "proposal" or "concern" or "decision" or "deferred" or "revised"); Speaker(step.SpeakerId); Evidence(step.EvidenceTurnIds);
            }
        }
    }
}
public sealed record MeetingIntelligenceDocument(
    [property: JsonPropertyName("recordingID")] Guid RecordingId, int AudioVersion, long ModifiedAt,
    [property: JsonPropertyName("mutationID")] Guid MutationId, string ProjectName, MeetingTranscript Transcript, MeetingInsights? Insights,
    Dictionary<string, string> ActionStates, [property: JsonPropertyName("analysisModelID")] string AnalysisModelId)
{
    public int SchemaVersion { get; init; } = 1;
    public const int MaximumBytes = 4 * 1024 * 1024;
    public void Validate(double duration)
    {
        MeetingValidation.Require(SchemaVersion == 1 && RecordingId != Guid.Empty && MutationId != Guid.Empty && AudioVersion >= 1 && Transcript is not null &&
            Transcript.RecordingId == RecordingId && Transcript.AudioVersion == AudioVersion && ActionStates is not null);
        MeetingValidation.Timestamp(ModifiedAt); MeetingValidation.Utf8Text(ProjectName, 256, true); MeetingValidation.Utf8Text(AnalysisModelId, 256);
        Transcript!.Validate(duration); Insights?.Validate(Transcript);
        var actionIds = Insights?.Actions.Select(a => a.Id).ToHashSet(StringComparer.Ordinal) ?? [];
        foreach (var state in ActionStates!) MeetingValidation.Require(actionIds.Contains(state.Key) && state.Value is "open" or "done" or "dismissed");
        MeetingValidation.Require(JsonSerializer.SerializeToUtf8Bytes(this, JsonDisk.Options).Length <= MaximumBytes);
    }
}
public static class MeetingValidation
{
    public static void Require(bool valid) { if (!valid) throw new InvalidDataException("회의 분석 데이터의 형식·시간·근거가 올바르지 않습니다. 이전 자료는 유지됩니다."); }
    public static void Text(string? text, int maximum, bool allowEmpty = false, bool requireTrimmed = true) => Require(text is not null &&
        StringInfo.ParseCombiningCharacters(text.Trim()).Length <= maximum && (!requireTrimmed || text == text.Trim()) && (allowEmpty || text.Trim().Length > 0));
    public static void Utf8Text(string? text, int maximum, bool allowEmpty = false) => Require(text is not null && Encoding.UTF8.GetByteCount(text) <= maximum && (allowEmpty || text.Trim().Length > 0));
    public static void TargetId(string? value, bool allowEmpty = false) => Require(value is not null && value.Length <= 128 && (allowEmpty || value.Length > 0) && value.All(c => c is >= ' ' and <= '~'));
    public static void Timestamp(long value) => Require(value is >= 0 and <= 9007199254740991);
}

public static class MeetingTranscriptAssembler
{
    public static string TurnId(Guid recordingId, int audioVersion, double start, double end, string text)
    {
        string source = string.Create(CultureInfo.InvariantCulture, $"{recordingId.ToString("D").ToUpperInvariant()}|{audioVersion}|{start:F3}|{end:F3}|{text}");
        return "turn-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source)).AsSpan(0, 8));
    }
    public static MeetingTranscript Assemble(Guid recordingId, int audioVersion, string model, double duration,
        IReadOnlyList<TranscriptSegment> source, AcousticDiarization diarization)
    {
        var speakers = new List<MeetingSpeaker>(); var turns = new List<TranscriptTurn>();
        var known = diarization.Speakers.Select(s => s.Id).ToHashSet(StringComparer.Ordinal);
        var published = new HashSet<string>(StringComparer.Ordinal);
        foreach (var segment in source.OrderBy(s => s.StartSeconds))
        {
            if (!double.IsFinite(segment.StartSeconds) || !double.IsFinite(segment.EndSeconds) || segment.StartSeconds < 0 ||
                segment.StartSeconds >= duration || segment.EndSeconds <= segment.StartSeconds || string.IsNullOrWhiteSpace(segment.Text)) continue;
            double start = segment.StartSeconds, end = Math.Min(duration, segment.EndSeconds);
            // Segment-only timestamps cannot prove which person spoke each word when a segment spans a speaker change.
            // Leave those turns unassigned; do not manufacture precise word timing or a majority speaker.
            var candidates = diarization.Segments.Where(s => s.Start < end && s.End > start).Select(s => s.SpeakerId).Distinct(StringComparer.Ordinal).ToList();
            string? speakerId = candidates.Count == 1 && known.Contains(candidates[0]) ? candidates[0] : null;
            if (speakerId is not null && published.Add(speakerId)) speakers.Add(new(speakerId, $"참여자 {speakers.Count + 1}"));
            string text = segment.Text.Trim();
            turns.Add(new(TurnId(recordingId, audioVersion, start, end, text), start, end, speakerId, text));
        }
        var result = new MeetingTranscript(recordingId, audioVersion, model, speakers, turns);
        result.Validate(duration); return result;
    }
}
