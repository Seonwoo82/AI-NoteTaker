using System.Text;
using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class MeetingAnalysisTests
{
    private static MeetingIntelligenceDocument Document(Recording r) => new(r.Id, 1, 10, Guid.NewGuid(), "제품 출시", new(r.Id, 1, "fixture", [new("a", "민수", true), new("b", "지영")],
        [new("t1", 0, 3, "a", "금요일까지 견적을 보내겠습니다."), new("t2", 3, 6, "b", "출시일은 언제인가요?"), new("t3", 6, 9, "a", "출시일은 다음 회의에 정하기로 합시다.")]),
        null, [], "fixture");
    private static MeetingInsights Insights(string id = "a1") => new([new(id, "commitment", "견적 보내기", "a", null, "금요일", ["t1"])],
        [new("q1", "출시일은?", ["t2"], null, [], "unanswered")], [new("d1", "출시일", "deferred", [new("deferred", "다음 회의에서 결정", "a", ["t3"])])]);
    private static string Json(MeetingInsights insights) => JsonSerializer.Serialize(insights, JsonDisk.Options);
    private static (LibraryStore Library, Recording Recording, MeetingWorkspaceStore Store) Setup(TestFolder folder)
    {
        var library = new LibraryStore(folder.Root); var r = new Recording { DurationSeconds = 10 }; library.Save(r); TestFolder.Wave(library.AudioPath(r.Id), 10);
        var store = new MeetingWorkspaceStore(library); store.Save(r, Document(r), null); return (library, r, store);
    }
    private sealed class FixtureModel(Func<string, CancellationToken, Task<string>> run, int maximum = 16000) : ISummarizer
    {
        public string Model => "fixture-analysis"; public int MaximumInputBytes => maximum;
        public async Task<AiText> CompleteAsync(string system, string text, CancellationToken token) => new(await run(text, token), null);
        public void Dispose() { }
    }
    private sealed class StructuredFixture(Func<string, JsonElement, string> run) : IStructuredSummarizer
    {
        public string Model => "structured-fixture"; public int MaximumInputBytes => 16000;
        public Task<AiText> CompleteAsync(string system, string text, CancellationToken token) => throw new InvalidOperationException("Expected structured request.");
        public Task<AiText> CompleteStructuredAsync(string system, string text, JsonElement schema, CancellationToken token) => Task.FromResult(new AiText(run(system, schema), null));
        public void Dispose() { }
    }
    [Theory] [InlineData(false)] [InlineData(true)] public async Task LocalCategoriesPublishTogetherAndDiscardInvalidFinalCategory(bool failLast)
    {
        using var folder = new TestFolder(); var (library, r, store) = Setup(folder); string? revision = store.Revision(r.Id); int calls = 0;
        var model = new StructuredFixture((system, schema) =>
        {
            Assert.Null(store.Load(r)!.Insights); calls++;
            string active = calls == 1 ? "actions" : calls == 2 ? "questions" : "decisions";
            foreach (string category in new[] { "actions", "questions", "decisions" })
                Assert.Equal(category != active, schema.GetProperty("properties").GetProperty(category).GetProperty("maxItems").GetInt32() == 0);
            return calls switch { 1 => Json(Insights() with { Questions = [], Decisions = [] }), 2 => Json(Insights() with { Actions = [], Decisions = [] }), _ => failLast ? "broken" : Json(Insights() with { Actions = [], Questions = [] }) };
        });
        var service = new MeetingAnalysisService(library, (_, _) => model);
        if (failLast)
        {
            await Assert.ThrowsAsync<InvalidDataException>(() => service.AnalyzeAsync(r, new(), "", new Progress<string>(), default));
            Assert.Equal(revision, store.Revision(r.Id));
        }
        else
        {
            var result = await service.AnalyzeAsync(r, new(), "", new Progress<string>(), default);
            Assert.Single(result.Insights!.Actions); Assert.Single(result.Insights.Questions); Assert.Single(result.Insights.Decisions);
        }
        Assert.Equal(3, calls);
    }
    [Fact] public void DateSpacingCanOnlyBeRestoredFromOneVerbatimCitedSpan()
    {
        var transcript = Document(new Recording()).Transcript with { Turns = [new("t1", 0, 3, "a", "6월 20일까지 보내겠습니다.")] };
        var insights = new MeetingInsights([Insights().Actions[0] with { DueText = "6 월 20 일" }], [], []);
        Assert.Equal("6월 20일", MeetingAnalysisPrompt.Decode(Json(insights), transcript).Actions[0].DueText);
        Assert.Throws<InvalidDataException>(() => MeetingAnalysisPrompt.Decode(Json(insights with { Actions = [insights.Actions[0] with { DueText = "6월 21일" }] }), transcript));
        var ambiguous = transcript with { Turns = [new("t1", 0, 3, "a", "6월 20일 또는 6 월20일")] };
        Assert.Throws<InvalidDataException>(() => MeetingAnalysisPrompt.Decode(Json(insights), ambiguous));
    }
    [Fact] public void JsonExtractionHandlesFencesQuotesAndRejectsInventedEvidence()
    {
        var transcript = Document(new Recording { DurationSeconds = 10 }).Transcript;
        var value = Insights() with { Actions = [Insights().Actions[0] with { Text = "문자열 {중괄호}와 \"인용\"" }] };
        Assert.Equal(value.Actions[0].Text, MeetingAnalysisPrompt.Decode("```json\n" + Json(value) + "\n```", transcript).Actions[0].Text);
        Assert.Throws<InvalidDataException>(() => MeetingAnalysisPrompt.Decode(Json(value with { Actions = [value.Actions[0] with { EvidenceTurnIds = ["invented"] }] }), transcript));
        Assert.Throws<InvalidDataException>(() => MeetingAnalysisPrompt.Decode("{\"actions\":[", transcript));
    }
    [Fact] public async Task LocalStructuredRequestConstrainsSpeakerTurnIdsAndDoesNotUseCredentials()
    {
        var transcript = Document(new Recording()).Transcript;
        using var model = new OllamaSummarizer(new(), new StubHandler(async (request, token) =>
        {
            Assert.Null(request.Headers.Authorization);
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token)); var root = json.RootElement;
            Assert.Equal("object", root.GetProperty("format").GetProperty("type").GetString());
            var action = root.GetProperty("format").GetProperty("properties").GetProperty("actions").GetProperty("items").GetProperty("properties");
            Assert.Equal("a", action.GetProperty("actorSpeakerID").GetProperty("enum")[0].GetString());
            Assert.Equal("t1", action.GetProperty("evidenceTurnIDs").GetProperty("items").GetProperty("enum")[0].GetString());
            Assert.False(root.GetProperty("think").GetBoolean()); Assert.Equal(8192, root.GetProperty("options").GetProperty("num_predict").GetInt32());
            return StubHandler.Json(JsonSerializer.Serialize(new { done = true, done_reason = "stop", message = new { content = Json(Insights()) } }));
        }));
        var response = await model.CompleteStructuredAsync(MeetingAnalysisPrompt.System, MeetingAnalysisPrompt.User(transcript, ""), MeetingAnalysisPrompt.JsonSchema(transcript), default);
        Assert.Single(MeetingAnalysisPrompt.Decode(response.Text, transcript).Actions);
        Assert.Equal(MeetingBriefingBuilder.NormalizeProject("Café"), MeetingBriefingBuilder.NormalizeProject("cafe"));
    }
    [Fact] public void PartitionsCoverAllTurnsWithBoundedOverlapAndActualUtf8Budget()
    {
        var transcript = Document(new Recording()).Transcript with { Turns = Enumerable.Range(0, 45).Select(i => new TranscriptTurn("t" + i, i * 3, i * 3 + 2, "a", new string('가', 360))).ToList() };
        var parts = MeetingAnalysisPrompt.Partition(transcript, "프로필은 참고", 6000);
        Assert.True(parts.Count > 1); var seen = new HashSet<string>();
        foreach (var part in parts)
        {
            Assert.Contains(part.Turns, t => !seen.Contains(t.Id)); Assert.True(Encoding.UTF8.GetByteCount(MeetingAnalysisPrompt.System) + Encoding.UTF8.GetByteCount(MeetingAnalysisPrompt.User(part, "프로필은 참고")) <= 6000);
            Assert.True(part.Turns.Count(t => seen.Contains(t.Id)) <= 3); foreach (var turn in part.Turns) seen.Add(turn.Id);
        }
        Assert.Equal(transcript.Turns.Count, seen.Count);
        Assert.Throws<InvalidOperationException>(() => MeetingAnalysisPrompt.Partition(transcript, "", 100));
    }
    [Fact] public async Task ReanalysisUsesCorrectionsAndPreservesStatusAcrossChangedModelItemIds()
    {
        using var folder = new TestFolder(); var (library, r, store) = Setup(folder);
        store.Append(r, "speakerName", "a", "확인된 이름"); store.Append(r, "projectName", "", "새 프로젝트");
        var service = new MeetingAnalysisService(library, (_, _) => new FixtureModel((text, _) => { Assert.Contains("확인된 이름", text); return Task.FromResult(Json(Insights(Guid.NewGuid().ToString("N")))); }));
        var first = await service.AnalyzeAsync(r, new(), "", new Progress<string>(), default); string id = first.Insights!.Actions[0].Id;
        store.Append(r, "actionStatus", id, "done");
        var second = await service.AnalyzeAsync(r, new(), "", new Progress<string>(), default);
        Assert.Equal(id, second.Insights!.Actions[0].Id); Assert.Equal("done", store.Resolve(r)!.ActionStates[id]); Assert.Equal("새 프로젝트", store.Resolve(r)!.ProjectName);
        Assert.Equal("민수", second.Transcript.Speakers[0].Name); Assert.Equal("확인된 이름", store.Resolve(r)!.Transcript.Speakers[0].Name);
    }
    [Theory] [InlineData("invalid")] [InlineData("cancel")] [InlineData("edits")] [InlineData("document")] [InlineData("audio")] [InlineData("deleted")] [InlineData("profile")] [InlineData("transcript")]
    public async Task FailedOrStaleAnalysisDoesNotPublish(string failure)
    {
        using var folder = new TestFolder(); var (library, r, store) = Setup(folder); string? expected = store.Revision(r.Id);
        using var cancellation = new CancellationTokenSource();
        var service = new MeetingAnalysisService(library, (_, _) => new FixtureModel((_, _) =>
        {
            if (failure == "cancel") cancellation.Cancel();
            if (failure == "edits") new MeetingWorkspaceStore(library).Append(r, "speakerName", "a", "새 이름");
            if (failure == "document") { store.Save(r, Document(r) with { ProjectName = "동시에 바뀐 문서" }, expected); expected = store.Revision(r.Id); }
            if (failure == "audio") File.AppendAllText(library.AudioPath(r.Id), "changed");
            if (failure == "deleted") library.Save(r with { DeletedAt = DateTimeOffset.Now });
            if (failure == "transcript") File.WriteAllText(library.TranscriptPath(r.Id), "changed after analysis began");
            if (failure == "profile") { var profile = new MeetingProfileStore(library.Root); profile.Save(new MeetingProfile { DisplayName = "변경된 프로필" }, profile.ProfileRevision); }
            return Task.FromResult(failure == "invalid" ? "invalid" : Json(Insights()));
        }));
        await Assert.ThrowsAnyAsync<Exception>(() => service.AnalyzeAsync(r, new(), "", new Progress<string>(), cancellation.Token));
        Assert.Equal(expected, store.Revision(r.Id)); Assert.Null(store.Load(r)!.Insights);
    }
    [Fact] public async Task InvalidLaterChunkDoesNotPublishAnIncompleteResult()
    {
        using var folder = new TestFolder(); var (library, r, store) = Setup(folder);
        r = r with { DurationSeconds = 200 }; library.Save(r);
        var doc = Document(r) with { Transcript = Document(r).Transcript with { Turns = Enumerable.Range(0, 45).Select(i => new TranscriptTurn("t" + i, i * 3, i * 3 + 2, "a", new string('가', 360))).ToList() } };
        store.Save(r, doc, store.Revision(r.Id)); string? revision = store.Revision(r.Id); int calls = 0;
        var service = new MeetingAnalysisService(library, (_, _) => new FixtureModel((_, _) => Task.FromResult(++calls == 2 ? "broken" : Json(new([], [], []))), 6000));
        await Assert.ThrowsAsync<InvalidDataException>(() => service.AnalyzeAsync(r, new(), "", new Progress<string>(), default));
        Assert.Equal(2, calls); Assert.Equal(revision, store.Revision(r.Id));
    }
    [Fact] public void BriefingUsesLatestMeetingsManualStatesProjectsAndOriginalEvidence()
    {
        var recordings = Enumerable.Range(0, 20).Select(i => new Recording { Title = "회의 " + i, DurationSeconds = 10, CreatedAt = DateTimeOffset.UnixEpoch.AddDays(i) }).ToList();
        var sources = recordings.Select(r => new MeetingBriefingSource(r, ResolvedMeeting.Resolve(Document(r) with { Insights = Insights() }, [], 10))).ToList();
        var last = sources[^1]; sources[^1] = last with { Meeting = last.Meeting with { ActionStates = new() { ["a1"] = "done" } } };
        var briefing = MeetingBriefingBuilder.Build(" 제품 출시 ", sources);
        Assert.Equal(12, briefing.Decisions.Count); Assert.Equal("회의 19", briefing.Decisions[0].RecordingTitle);
        Assert.Equal("회의 18", briefing.OpenActions[0].RecordingTitle); Assert.Equal(["t1"], briefing.OpenActions[0].TurnIds);
        Assert.Equal(12, briefing.UnansweredQuestions.Count); Assert.Empty(MeetingBriefingBuilder.Build("다른 프로젝트", sources).Decisions);
        Assert.DoesNotContain(MeetingBriefingBuilder.Build("제품 출시", sources, recordings[^1].Id).Decisions, i => i.RecordingId == recordings[^1].Id);
        var deleted = sources.Select(s => s with { Recording = s.Recording with { DeletedAt = DateTimeOffset.Now } });
        Assert.Empty(MeetingBriefingBuilder.Build("제품 출시", deleted).OpenActions);
    }
}
