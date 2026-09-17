using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NoteTaker.Core;

public sealed record MeetingEdit(Guid Id, [property: JsonPropertyName("recordingID")] Guid RecordingId, int AudioVersion,
    long ModifiedAt, string Kind, [property: JsonPropertyName("targetID")] string TargetId, string Value)
{
    public int SchemaVersion { get; init; } = 1;
    public void Validate()
    {
        MeetingValidation.Require(SchemaVersion == 1 && Id != Guid.Empty && RecordingId != Guid.Empty && AudioVersion >= 1);
        MeetingValidation.Timestamp(ModifiedAt); MeetingValidation.TargetId(TargetId, Kind == "projectName"); MeetingValidation.Utf8Text(Value, 256, true);
        switch (Kind)
        {
            case "speakerName": MeetingValidation.Utf8Text(Value, 256); break;
            case "projectName": MeetingValidation.Require(TargetId == ""); break;
            case "speakerOwner": MeetingValidation.Require(Value is "true" or "false"); break;
            case "turnSpeaker": MeetingValidation.TargetId(Value, true); break;
            case "actionStatus": MeetingValidation.Require(Value is "open" or "done" or "dismissed"); break;
            default: throw new InvalidDataException("지원하지 않는 회의 수정입니다.");
        }
    }
}
public sealed record ResolvedMeeting(MeetingIntelligenceDocument Source, MeetingTranscript Transcript,
    string ProjectName, Dictionary<string, string> ActionStates, int UnresolvedEditCount)
{
    public IReadOnlyList<TranscriptTurn> OwnTurns => Transcript.Turns.Where(t => Transcript.Speakers.Any(s => s.IsOwner && s.Id == t.SpeakerId)).ToList();
    public static ResolvedMeeting Resolve(MeetingIntelligenceDocument source, IEnumerable<MeetingEdit> edits, double duration)
    {
        source.Validate(duration);
        var latest = new Dictionary<(string Kind, string Target), MeetingEdit>(); int unresolved = 0;
        foreach (var edit in edits)
        {
            try { edit.Validate(); if (edit.RecordingId != source.RecordingId || edit.AudioVersion != source.AudioVersion) { unresolved++; continue; } }
            catch (InvalidDataException) { unresolved++; continue; }
            var key = (edit.Kind, edit.TargetId);
            if (!latest.TryGetValue(key, out var old) || Compare(edit, old) > 0) latest[key] = edit;
        }
        var speakers = source.Transcript.Speakers.ToList(); var turns = source.Transcript.Turns.ToList();
        var actionStates = new Dictionary<string, string>(source.ActionStates); string project = source.ProjectName;
        if (!speakers.Any(s => s.Id == "owner") && latest.Values.Any(e => e.Kind == "turnSpeaker" && e.Value == "owner" && turns.Any(t => t.Id == e.TargetId)))
            speakers.Add(new("owner", speakers.FirstOrDefault(s => s.IsOwner)?.Name ?? "나", true, true));
        foreach (var edit in latest.Values.OrderBy(e => e.ModifiedAt).ThenBy(e => e.Id.ToString("D").ToUpperInvariant(), StringComparer.Ordinal))
        {
            int speakerIndex = speakers.FindIndex(s => s.Id == edit.TargetId), turnIndex = turns.FindIndex(t => t.Id == edit.TargetId);
            switch (edit.Kind)
            {
                case "speakerName" when speakerIndex >= 0: speakers[speakerIndex] = speakers[speakerIndex] with { Name = edit.Value, ManuallyAssigned = true }; break;
                case "speakerOwner" when speakerIndex >= 0: speakers[speakerIndex] = speakers[speakerIndex] with { IsOwner = edit.Value == "true", ManuallyAssigned = true }; break;
                case "turnSpeaker" when turnIndex >= 0 && (edit.Value == "" || speakers.Any(s => s.Id == edit.Value)):
                    turns[turnIndex] = turns[turnIndex] with { SpeakerId = edit.Value == "" ? null : edit.Value }; break;
                case "actionStatus" when source.Insights?.Actions.Any(a => a.Id == edit.TargetId) == true: actionStates[edit.TargetId] = edit.Value; break;
                case "projectName": project = edit.Value; break;
                default: unresolved++; break;
            }
        }
        var transcript = source.Transcript with { Speakers = speakers, Turns = turns }; transcript.Validate(duration);
        return new(source, transcript, project, actionStates, unresolved);
    }
    private static int Compare(MeetingEdit first, MeetingEdit second) => first.ModifiedAt != second.ModifiedAt
        ? first.ModifiedAt.CompareTo(second.ModifiedAt) : string.CompareOrdinal(first.Id.ToString("D").ToUpperInvariant(), second.Id.ToString("D").ToUpperInvariant());
}

public sealed class MeetingWorkspaceStore(LibraryStore library)
{
    private readonly object gate = JsonDisk.Gate;
    public string DocumentPath(Guid id) => Path.Combine(library.DirectoryFor(id), "meeting-intelligence.json");
    private string EditsPath(Guid id) => Path.Combine(library.DirectoryFor(id), "meeting-edits-local.json");
    private string EditsRevision(Guid id) => File.Exists(EditsPath(id)) ? Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(EditsPath(id)))) : "absent";
    public MeetingWorkspaceSnapshot Snapshot(Recording recording)
    {
        lock (gate) return new(Load(recording), Edits(recording.Id), Revision(recording.Id), EditsRevision(recording.Id));
    }
    public string? Revision(Guid id) => File.Exists(DocumentPath(id)) ? Convert.ToHexStringLower(SHA256.HashData(File.ReadAllBytes(DocumentPath(id)))) : null;
    public MeetingIntelligenceDocument? Load(Recording recording)
    {
        string path = DocumentPath(recording.Id); if (!File.Exists(path)) return null;
        MeetingValidation.Require(new FileInfo(path).Length <= MeetingIntelligenceDocument.MaximumStoredBytes);
        var document = JsonDisk.Read<MeetingIntelligenceDocument>(path) ?? throw new InvalidDataException("회의 분석 문서가 비어 있습니다.");
        document.Validate(recording.DurationSeconds);
        MeetingValidation.Require(document.RecordingId == recording.Id && document.AudioVersion == recording.AudioVersion);
        return document;
    }
    public ResolvedMeeting? Resolve(Recording recording)
    {
        var document = Load(recording); return document is null ? null : ResolvedMeeting.Resolve(document, Edits(recording.Id), recording.DurationSeconds);
    }
    public IReadOnlyList<MeetingEdit> Edits(Guid id)
    {
        string path = EditsPath(id); if (!File.Exists(path)) return [];
        MeetingValidation.Require(new FileInfo(path).Length <= 16 * 1024 * 1024);
        var edits = JsonDisk.Read<List<MeetingEdit>>(path) ?? throw new InvalidDataException("수동 수정 이력이 비어 있습니다.");
        MeetingValidation.Require(edits.All(e => e is not null) && edits.Select(e => e.Id).Distinct().Count() == edits.Count);
        foreach (var edit in edits) { edit.Validate(); MeetingValidation.Require(edit.RecordingId == id); }
        return edits;
    }
    public MeetingEdit Append(Recording recording, string kind, string target, string value)
    {
        lock (gate)
        {
            var document = Load(recording) ?? throw new InvalidDataException("참여자 분석을 먼저 실행해 주세요.");
            var edits = Edits(recording.Id).ToList();
            long timestamp = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), edits.Count == 0 ? 0 : checked(edits.Max(e => e.ModifiedAt) + 1));
            var edit = new MeetingEdit(Guid.NewGuid(), recording.Id, recording.AudioVersion, timestamp, kind, target, value); edit.Validate();
            var before = ResolvedMeeting.Resolve(document, edits, recording.DurationSeconds); edits.Add(edit);
            var after = ResolvedMeeting.Resolve(document, edits, recording.DurationSeconds);
            MeetingValidation.Require(after.UnresolvedEditCount <= before.UnresolvedEditCount);
            MeetingValidation.Require(JsonSerializer.SerializeToUtf8Bytes(edits, JsonDisk.Options).Length <= 16 * 1024 * 1024);
            JsonDisk.Write(EditsPath(recording.Id), edits); return edit;
        }
    }
    public void Save(Recording recording, MeetingIntelligenceDocument document, string? expectedRevision, string? expectedEditsRevision = null)
    {
        lock (gate)
        {
            // Reading the old data before writing also prevents overwriting an unreadable document.
            var previous = Load(recording); _ = Edits(recording.Id);
            if (Revision(recording.Id) != expectedRevision) throw new InvalidOperationException("분석 중 문서가 변경되었습니다. 최신 문서를 확인한 뒤 다시 실행해 주세요.");
            if (expectedEditsRevision is not null && EditsRevision(recording.Id) != expectedEditsRevision) throw new InvalidOperationException("분석 중 수동 수정이 변경되었습니다. 최신 내용을 확인한 뒤 다시 실행해 주세요.");
            MeetingValidation.Require(document.RecordingId == recording.Id && document.AudioVersion == recording.AudioVersion);
            long timestamp = Math.Max(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), previous is null ? 0 : checked(previous.ModifiedAt + 1));
            var stamped = document with { ModifiedAt = timestamp, MutationId = Guid.NewGuid() }; stamped.Validate(recording.DurationSeconds);
            JsonDisk.Write(DocumentPath(recording.Id), stamped);
        }
    }
}
public sealed record MeetingWorkspaceSnapshot(MeetingIntelligenceDocument? Document, IReadOnlyList<MeetingEdit> Edits, string? Revision, string EditsRevision);
