using System.Text.Json;
using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class MeetingIntelligenceTests
{
    private static readonly Guid RecordId = Guid.Parse("00000000-0000-0000-0000-000000000123");
    private static MeetingIntelligenceDocument Document() => new(RecordId, 1, 10, Guid.NewGuid(), "프로젝트", new(RecordId, 1, "whisper", [new("a", "참여자 1"), new("b", "참여자 2")],
        [new("t1", 0, 3, "a", "금요일에 견적을 보내겠습니다."), new("t2", 4, 7, "b", "그럼 검토하겠습니다.")]),
        new([new("a1", "commitment", "견적 발송", "a", null, "금요일", ["t1"])], [], []), [], "test-model");
    private static MeetingEdit Edit(string kind, string target, string value, long time = 11) => new(Guid.NewGuid(), RecordId, 1, time, kind, target, value);

    [Fact] public void SharedJsonNamesMatchAppleSchemaAndRoundTrip()
    {
        var document = Document(); document.Validate(8);
        string json = JsonSerializer.Serialize(document, JsonDisk.Options);
        using var parsed = JsonDocument.Parse(json); var data = parsed.RootElement;
        Assert.True(data.TryGetProperty("recordingID", out _)); Assert.True(data.TryGetProperty("mutationID", out _));
        Assert.True(data.GetProperty("transcript").TryGetProperty("transcriptionModelID", out _));
        Assert.True(data.GetProperty("transcript").GetProperty("turns")[0].TryGetProperty("speakerID", out _));
        Assert.True(data.GetProperty("insights").GetProperty("actions")[0].TryGetProperty("evidenceTurnIDs", out _));
        var restored = JsonSerializer.Deserialize<MeetingIntelligenceDocument>(json, JsonDisk.Options)!; restored.Validate(8);
        Assert.Equal(document.Transcript.Turns, restored.Transcript.Turns);
    }
    [Theory] [InlineData("unknown", "금요일")] [InlineData("t1", "다음 달")]
    public void RejectsInventedEvidenceAndDeadlines(string evidence, string due)
    {
        var document = Document(); var action = document.Insights!.Actions[0] with { EvidenceTurnIds = [evidence], DueText = due };
        Assert.Throws<InvalidDataException>(() => (document with { Insights = new([action], [], []) }).Validate(8));
    }
    [Fact] public void RejectsUnbackedAnswerAndInvalidTimeOrSpeaker()
    {
        var document = Document();
        Assert.Throws<InvalidDataException>(() => new MeetingInsights([], [new("q1", "언제?", ["t1"], "내일", [], "answered")], []).Validate(document.Transcript));
        foreach (var turn in new[] { new TranscriptTurn("x", double.NaN, 1, "a", "내용"), new("x", 0, 9, "a", "내용"), new("x", 0, 1, "unknown", "내용") })
            Assert.Throws<InvalidDataException>(() => (document.Transcript with { Turns = [turn] }).Validate(8));
    }
    [Fact] public void ManualNamesOwnerTurnsAndActionStatesSurviveReanalysis()
    {
        var edits = new[] { Edit("speakerName", "a", "김민수"), Edit("speakerOwner", "a", "true"), Edit("turnSpeaker", "t2", "owner"), Edit("actionStatus", "a1", "done"), Edit("projectName", "", "신규 프로젝트") };
        var source = Document(); var first = ResolvedMeeting.Resolve(source, edits, 8);
        var later = ResolvedMeeting.Resolve(source with { ModifiedAt = 200, MutationId = Guid.NewGuid() }, edits.Reverse(), 8);
        Assert.Equal("김민수", later.Transcript.Speakers[0].Name); Assert.Equal(2, later.OwnTurns.Count);
        Assert.Equal("done", later.ActionStates["a1"]); Assert.Equal("신규 프로젝트", later.ProjectName); Assert.Equal(0, later.UnresolvedEditCount);
        Assert.Equal(first.Transcript.Turns, later.Transcript.Turns); Assert.Equal("참여자 1", source.Transcript.Speakers[0].Name);
    }
    [Fact] public void UnmappedHistoryIsRetainedAndLatestFieldWinsDeterministically()
    {
        var first = Edit("speakerName", "a", "이전", 11); var last = Edit("speakerName", "a", "최신", 12);
        var unmapped = Edit("turnSpeaker", "removed", "a");
        var resolved = ResolvedMeeting.Resolve(Document(), [last, unmapped, first], 8);
        Assert.Equal("최신", resolved.Transcript.Speakers[0].Name); Assert.Equal(1, resolved.UnresolvedEditCount);
    }
    [Fact] public void TurnIdentityIsStableAcrossCultureAndAmbiguousSpeakerStaysUnassigned()
    {
        var previousCulture = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            string expected = MeetingTranscriptAssembler.TurnId(RecordId, 1, 1.25, 2.75, "원문");
            System.Globalization.CultureInfo.CurrentCulture = new("fr-FR");
            Assert.Equal(expected, MeetingTranscriptAssembler.TurnId(RecordId, 1, 1.25, 2.75, "원문"));
            var acoustic = new AcousticDiarization("test", 8, [new(0, 3, "a"), new(3, 8, "b")], [new("a", []), new("b", [])]);
            var result = MeetingTranscriptAssembler.Assemble(RecordId, 1, "test", 8,
                [new(0, 2, "원문 1"), new(2, 5, "여러 화자 원문"), new(5, 9, "끝부분")], acoustic);
            Assert.Equal("a", result.Turns[0].SpeakerId); Assert.Null(result.Turns[1].SpeakerId);
            Assert.Equal("b", result.Turns[2].SpeakerId); Assert.Equal(8, result.Turns[2].End);
        }
        finally { System.Globalization.CultureInfo.CurrentCulture = previousCulture; }
    }
    [Fact] public void DiskEditsPersistAndConcurrentOrCorruptDocumentsCannotBeOverwritten()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root); var store = new MeetingWorkspaceStore(library);
        var recording = new Recording { Id = RecordId, DurationSeconds = 8 }; library.Save(recording);
        store.Save(recording, Document(), null); string oldRevision = store.Revision(RecordId)!;
        store.Append(recording, "speakerName", "a", "고친 이름"); store.Save(recording, Document(), oldRevision);
        var reopened = new MeetingWorkspaceStore(library); Assert.Equal("고친 이름", reopened.Resolve(recording)!.Transcript.Speakers[0].Name);
        Assert.Throws<InvalidOperationException>(() => store.Save(recording, Document(), oldRevision));
        File.WriteAllText(store.DocumentPath(RecordId), "broken");
        Assert.Throws<JsonException>(() => store.Save(recording, Document(), store.Revision(RecordId)));
        Assert.Equal("broken", File.ReadAllText(store.DocumentPath(RecordId)));
    }
    [Fact] public void SharedEditLimitsUseUtf8AndPrintableAsciiTargets()
    {
        Assert.Throws<InvalidDataException>(() => Edit("speakerName", "a", new string('한', 86)).Validate());
        Assert.Throws<InvalidDataException>(() => Edit("turnSpeaker", "발화", "a").Validate());
        Assert.Throws<InvalidDataException>(() => Edit("turnSpeaker", "t1", "speaker\n").Validate());
        Edit("speakerName", "a", new string('한', 85)).Validate();
        Assert.Throws<InvalidDataException>(() => (Document() with { ProjectName = new string('한', 86) }).Validate(8));
    }
    [Fact] public void PcmRangesConcatenateExactFramesWithoutInterveningAudioOrDuplicates()
    {
        using var folder = new TestFolder(); string path = Path.Combine(folder.Root, "ranges.wav");
        using (var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(16000, 2)))
        {
            var samples = Enumerable.Range(0, 16000 * 4).SelectMany(frame => new[] { frame / 64000f, -frame / 64000f }).ToArray();
            writer.WriteSamples(samples, 0, samples.Length);
        }
        using var reader = new AudioFileReader(path);
        var ranges = new AudioRangeSampleProvider(reader, [new(0, .5), new(.25, 1), new(2, 2.5)]);
        var actual = new List<float>(); var buffer = new float[1130]; int read;
        while ((read = ranges.Read(buffer, 0, buffer.Length)) > 0) actual.AddRange(buffer.Take(read));
        var expected = Enumerable.Range(0, 16000).Concat(Enumerable.Range(32000, 8000)).SelectMany(frame => new[] { frame / 64000f, -frame / 64000f });
        Assert.Equal(expected, actual); Assert.True(ranges.Finished); Assert.Equal(0, ranges.Read(buffer, 0, buffer.Length));
    }
}
