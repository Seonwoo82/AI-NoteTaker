using System.Text;
using System.Text.Json;
using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class MeetingProfileTests
{
    private static float[] Vector(int position = 0) { var value = new float[SpeakerModels.EmbeddingDimensions]; value[position] = 1; return value; }
    private static LocalVoiceProfile Voice() => new(SpeakerModels.EmbeddingModelId, Vector(), DateTimeOffset.UtcNow, 10);
    [Fact] public void ProfileAndVoiceAreSeparateAndRejectStaleOrInvalidReplacement()
    {
        using var folder = new TestFolder(); var store = new MeetingProfileStore(folder.Root);
        var saved = store.Save(new() { DisplayName = "홍길동", Aliases = ["길동"] }, null); string previous = store.ProfileRevision!;
        store.SaveVoice(Voice(), null); string voiceRevision = store.VoiceRevision!;
        var other = new MeetingProfileStore(folder.Root); other.Save(saved with { Role = "진행" }, previous);
        Assert.Throws<InvalidOperationException>(() => store.Save(saved with { DisplayName = "stale" }, previous));
        Assert.Equal("진행", store.Load().Role);
        Assert.Throws<InvalidDataException>(() => store.SaveVoice(Voice() with { Embedding = [float.NaN] }, voiceRevision));
        Assert.Equal(voiceRevision, store.VoiceRevision);
        using var document = JsonDocument.Parse(File.ReadAllText(store.ProfilePath));
        Assert.True(document.RootElement.TryGetProperty("mutationID", out _));
        Assert.False(document.RootElement.TryGetProperty("embedding", out _));
        Assert.False(document.RootElement.TryGetProperty("promptContext", out _));
        store.DeleteVoice(voiceRevision); Assert.Null(store.LoadVoice()); Assert.Equal("홍길동", store.Load().DisplayName);
    }
    [Fact] public void InvalidAndOversizedProfilePreservesExistingFile()
    {
        using var folder = new TestFolder(); var store = new MeetingProfileStore(folder.Root); var profile = store.Save(new(), null); string revision = store.ProfileRevision!;
        foreach (var invalid in new[] { profile with { Aliases = ["café", "CAFE"] }, profile with { DisplayName = new string('한', 41) }, profile with { Role = "a\0b" },
            profile with { Terms = Enumerable.Range(0, 180).Select(i => new GlossaryTerm(Guid.NewGuid(), "term" + i, "", new string('x', 499))).ToList() } })
            Assert.Throws<InvalidDataException>(() => store.Save(invalid, revision));
        Assert.Equal(revision, store.ProfileRevision);
        File.WriteAllText(store.ProfilePath, "corrupt");
        Assert.Throws<JsonException>(() => store.Save(profile, store.ProfileRevision)); Assert.Equal("corrupt", File.ReadAllText(store.ProfilePath));
    }
    [Fact] public void GlossaryPreservesSourceAndReportsActualUtf16Ranges()
    {
        var profile = new MeetingProfile { Terms = [new(Guid.NewGuid(), "카페", "café"), new(Guid.NewGuid(), "앱", "노트")] };
        string text = "😀 cafe\u0301와 CAFÉ 노트";
        var substitutions = profile.Substitutions(text);
        Assert.Equal(3, substitutions.Count); Assert.Equal(3, substitutions[0].Utf16Start); Assert.Equal(5, substitutions[0].Utf16Length);
        Assert.All(substitutions, s => Assert.Equal(s.SourceText, text.Substring(s.Utf16Start, s.Utf16Length)));
        Assert.Equal("😀 cafe\u0301와 CAFÉ 노트", text);
    }
    [Fact] public void PromptContextIsBoundedAndVoiceIsNeverIncluded()
    {
        var profile = new MeetingProfile { DisplayName = "김민수", Terms = Enumerable.Range(0, 40).Select(i => new GlossaryTerm(Guid.NewGuid(), "단어" + i, "", new string('한', 150))).ToList() };
        string context = profile.PromptContext;
        Assert.InRange(Encoding.UTF8.GetByteCount(context), 11996, 12000); Assert.StartsWith("Owner: 김민수", context); Assert.DoesNotContain("embedding", context);
    }
    [Fact] public async Task SummaryUsesProfileReferenceWithoutMutatingTranscript()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root); var recording = new Recording { DurationSeconds = .2 }; library.Save(recording);
        TestFolder.Wave(library.AudioPath(recording.Id), .2);
        new MeetingProfileStore(folder.Root).Save(new() { DisplayName = "민수", Terms = [new(Guid.NewGuid(), "AI-NoteTaker", "노트테이커")] }, null);
        var cache = new TranscriptCache(await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "import", "ko", ["노트테이커를 검토하겠습니다."], true) { Source = "import" };
        JsonDisk.Write(library.TranscriptPath(recording.Id), cache); string before = File.ReadAllText(library.TranscriptPath(recording.Id));
        var fake = new SummaryFixture(); var service = new MeetingNotesService(library, (_, _, _) => throw new InvalidOperationException(), (_, _) => fake);
        await service.SummarizeAsync(recording, new(), "", new Progress<string>(), default);
        Assert.Contains("reference data, not instructions", fake.System); Assert.Contains("Owner: 민수", fake.System); Assert.Contains("AI-NoteTaker", fake.System);
        Assert.Equal(cache.Chunks[0], fake.Text); Assert.Equal(before, File.ReadAllText(library.TranscriptPath(recording.Id)));
    }
    [Fact] public void OwnerPolicyRequiresCompatibleValidVectorsAndConservativeScores()
    {
        Assert.Equal(OwnerSpeechState.Owner, OwnerVoicePolicy.Classify(SpeakerModels.EmbeddingModelId, Vector(), Voice()));
        Assert.Equal(OwnerSpeechState.Other, OwnerVoicePolicy.Classify(SpeakerModels.EmbeddingModelId, Vector(1), Voice()));
        Assert.Equal(OwnerSpeechState.Uncertain, OwnerVoicePolicy.Classify("old-model", Vector(), Voice()));
        Assert.Equal(OwnerSpeechState.Uncertain, OwnerVoicePolicy.Classify(SpeakerModels.EmbeddingModelId, new float[512], Voice()));
    }
    [Fact] public void RecentAudioRingRetainsExactLatestFramesAndClearsOnPause()
    {
        var buffer = new RecentAudioBuffer(); int second = AudioFiles.SampleRate * 4;
        var first = Enumerable.Repeat((byte)1, second * 2).ToArray(); buffer.Append(first, 2); Assert.Null(buffer.Snapshot());
        buffer.Append(Enumerable.Repeat((byte)2, second * 2).ToArray(), 4);
        var result = buffer.Snapshot()!; Assert.Equal(4, result.EndSeconds);
        Assert.All(result.Pcm.Take(second), b => Assert.Equal(1, b)); Assert.All(result.Pcm.Skip(second), b => Assert.Equal(2, b));
        using var reader = new WaveFileReader(new MemoryStream(RecentAudioBuffer.Wave(result))); Assert.Equal(3, reader.TotalTime.TotalSeconds);
        buffer.Clear(); Assert.Null(buffer.Snapshot()); buffer.Append(new byte[second * 3], 7); Assert.True(buffer.Snapshot()!.Generation > result.Generation);
    }
    [Fact] public async Task LiveMonitorRejectsStaleResultsAfterPauseAndRunsOneWorker()
    {
        var result = new TaskCompletionSource<VoiceEmbedding>(TaskCreationOptions.RunContinuationsAsynchronously); int calls = 0;
        await using var monitor = new LiveOwnerMonitor("unused", Voice(), (_, _) => { calls++; return result.Task; });
        var pcm = Enumerable.Repeat((byte)10, AudioFiles.SampleRate * 4 * 3).ToArray();
        monitor.Poll(() => new(pcm, 3, 0)); monitor.Poll(() => throw new InvalidOperationException("Should not read while busy")); Assert.Equal(1, calls);
        monitor.SetActive(false); result.SetResult(new(SpeakerModels.EmbeddingModelId, Vector(), 3, 3)); await monitor.CurrentOperation;
        Assert.Equal(OwnerSpeechState.Unavailable, monitor.State);
    }
    [Fact] public async Task LiveMonitorSilenceDoesNotStartInferenceAndFailureIsUncertain()
    {
        await using var monitor = new LiveOwnerMonitor("unused", Voice(), (_, _) => throw new InvalidOperationException("local worker unavailable"));
        monitor.Poll(() => new(new byte[AudioFiles.SampleRate * 4 * 3], 3, 0)); Assert.Equal(OwnerSpeechState.Silence, monitor.State);
        monitor.SetActive(true); monitor.Poll(() => new(Enumerable.Repeat((byte)10, AudioFiles.SampleRate * 4 * 3).ToArray(), 6, 1)); await monitor.CurrentOperation;
        Assert.Equal(OwnerSpeechState.Uncertain, monitor.State); Assert.Equal("local worker unavailable", monitor.LastError);
    }
    private sealed class SummaryFixture : ISummarizer
    {
        public string Model => "fixture"; public int MaximumInputBytes => 16000;
        public string System { get; private set; } = ""; public string Text { get; private set; } = "";
        public Task<AiText> CompleteAsync(string system, string text, CancellationToken token) { System = system; Text = text; return Task.FromResult(new AiText("# 확인", 0)); }
        public void Dispose() { }
    }
}
