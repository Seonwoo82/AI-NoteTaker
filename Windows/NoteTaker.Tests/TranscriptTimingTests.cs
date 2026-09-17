using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class TranscriptTimingTests
{
    private static float[] Vector(int index) { var value = new float[512]; value[index] = 1; return value; }
    [Fact] public void NativeByteCaptureDistinguishesIdenticalReplacementStrings()
    {
        var capture = new WhisperUtf8Capture(); IntPtr first = Marshal.AllocHGlobal(3), second = Marshal.AllocHGlobal(3);
        try
        {
            Marshal.Copy(new byte[] { 0xEA, 0xB0, 0 }, 0, first, 3); Marshal.Copy(new byte[] { 0x80, 0, 0 }, 0, second, 3);
            string a = capture.GetStringUtf8(first), b = capture.GetStringUtf8(second);
            Assert.Equal("�", a); Assert.Equal("�", b); Assert.NotSame(a, b);
            Assert.Equal(new byte[] { 0xEA, 0xB0 }, capture.Bytes(a)); Assert.Equal(new byte[] { 0x80 }, capture.Bytes(b));
            var words = WhisperTokenAlignment.Align("가", [new(capture.Bytes(a), 1, 1.1), new(capture.Bytes(b), 1.1, 1.2)]);
            Assert.Equal("가", Assert.Single(words).Text); Assert.Equal(1.2, words[0].EndSeconds);
        }
        finally { Marshal.FreeHGlobal(first); Marshal.FreeHGlobal(second); }
    }
    [Fact] public void Utf8TimingNeverSplitsEmojiOrCombiningCharactersOrDropsText()
    {
        string text = "가 e\u0301 👩‍💻 끝"; byte[] bytes = Encoding.UTF8.GetBytes(text);
        var units = WhisperTokenAlignment.Align(text, bytes.Select((b, i) => new EncodedTranscriptToken([b], i * .01, (i + 1) * .01)).ToList());
        Assert.Equal(text, string.Concat(units.Select(w => w.Text))); Assert.Contains(units, w => w.Text == "👩‍💻"); Assert.Contains(units, w => w.Text == "e\u0301");
        Assert.Empty(WhisperTokenAlignment.Align("different", [new(bytes, 0, 1)]));
        Assert.Empty(WhisperTokenAlignment.Align(text, [new(bytes, -1, 1)]));
    }
    [Fact] public void WordTimesSplitSpeakerChangesAndPointTextStaysVisibleAndUnassigned()
    {
        var source = new TranscriptSegment(0, 5, "첫째 둘째 ? 끝") { Words = [new(0, 1, "첫째"), new(2, 3, " 둘째"), new(3, 3, " ?"), new(3.5, 4, " 끝")] };
        var acoustic = new AcousticDiarization("test", 5, [new(0, 1.5, "a"), new(1.5, 5, "b")], [new("a", []), new("b", [])]);
        var result = MeetingTranscriptAssembler.Assemble(Guid.NewGuid(), 1, "test", 5, [source], acoustic);
        Assert.Equal(new[] { "a", "b", null }, result.Turns.Select(t => t.SpeakerId)); Assert.Equal("? 끝", result.Turns[^1].Text);
        Assert.Equal("첫째둘째?끝", string.Concat(result.Turns.Select(t => t.Text)).Replace(" ", ""));
        Assert.Equal(2, result.Turns[1].Start);
    }
    [Fact] public void OffsetMovesSegmentAndWordTimesTogether()
    {
        var segment = new TranscriptSegment(1, 3, "내용") { Words = [new(1.5, 2.5, "내용")] };
        var later = TranscriptTiming.Offset(segment, 120); Assert.Equal(121, later.StartSeconds); Assert.Equal(121.5, later.Words[0].StartSeconds); Assert.Equal(122.5, later.Words[0].EndSeconds);
    }
    [Fact] public async Task CloudRequestsVerboseTimestampsAndPreservesOriginalSpacing()
    {
        using var client = new OpenRouterClient(new StubHandler(async (request, token) =>
        {
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token));
            Assert.Equal("verbose_json", body.RootElement.GetProperty("response_format").GetString());
            Assert.Equal(new[] { "segment", "word" }, body.RootElement.GetProperty("timestamp_granularities").EnumerateArray().Select(x => x.GetString()));
            return StubHandler.Json("""{"text":"Hello, world!","words":[{"word":"Hello","start":0,"end":1},{"word":"world","start":1.2,"end":2}],"segments":[{"text":"Hello, world!","start":0,"end":2}]}""");
        }));
        var result = await client.TranscribeDetailedAsync([], new(), "fixture-key", default); var segment = Assert.Single(result.Segments);
        Assert.Equal("Hello, world!", string.Concat(segment.Words.Select(w => w.Text))); Assert.Equal(1.2, segment.Words[1].StartSeconds);
    }
    [Theory]
    [InlineData("""{"text":"test","words":[{"word":"test","start":-1,"end":1}]}""")]
    [InlineData("""{"text":"test","words":[{"word":"test","start":"bad","end":1}]}""")]
    public void CloudRejectsInvalidWordTimes(string json)
    {
        using var document = JsonDocument.Parse(json); Assert.Throws<InvalidDataException>(() => OpenRouterClient.DecodeDetailed(document.RootElement));
    }
    [Fact] public void AcousticIdentityDoesNotFollowChangedGroupIndicesOrAmbiguousSplits()
    {
        var previous = new AcousticDiarization("test", 4, [], [new("old-a", Vector(0)), new("old-b", Vector(1))]);
        var current = new AcousticDiarization("test", 4, [new(0, 1, "s0"), new(2, 3, "s1")], [new("s0", Vector(1)), new("s1", Vector(0))]);
        var mapped = SpeakerIdentity.Reconcile(current, previous); Assert.Equal("old-b", mapped.Segments[0].SpeakerId); Assert.Equal("old-a", mapped.Segments[1].SpeakerId);
        var split = current with { Speakers = [new("s0", Vector(0)), new("s1", Vector(0))] };
        Assert.DoesNotContain(SpeakerIdentity.Reconcile(split, previous).Speakers, s => s.Id == "old-a");
    }
    [Fact] public void TimingUpgradePreservesOnlyCorrectionsWithExactlyMatchingSourceText()
    {
        Guid id = Guid.NewGuid(); var old = new MeetingTranscript(id, 1, "old", [new("a", "이름")], [new("old-turn", 0, 5, "a", "원래 발화")]);
        var current = old with { Turns = [new("new-1", .1, 1, "a", "원래"), new("new-2", 2, 4.8, "a", "발화")] };
        var edit = new MeetingEdit(Guid.NewGuid(), id, 1, 10, "turnSpeaker", "old-turn", "owner");
        Assert.Equal("old-turn", Assert.Single(SpeakerIdentity.PreserveCorrectedTurns(current, old, [edit]).Turns).Id);
        var changed = current with { Turns = [new("new", .1, 4.8, "a", "달라진 전사")] };
        Assert.Equal("new", Assert.Single(SpeakerIdentity.PreserveCorrectedTurns(changed, old, [edit]).Turns).Id);
    }
    [Fact] public async Task DetailedCacheResumesAndLeavesOriginalTranscriptUntouched()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root); var recording = new Recording { DurationSeconds = 120.2 }; library.Save(recording); TestFolder.Wave(library.AudioPath(recording.Id), 120.2);
        var original = new TranscriptCache(await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "original", "ko", ["원래 전사문"], true);
        JsonDisk.Write(library.TranscriptPath(recording.Id), original); string unchanged = File.ReadAllText(library.TranscriptPath(recording.Id));
        int count = 0;
        var first = new ParticipantTranscriptService(library, folder.Root, (_, _, _) => new TimingFixture(() => ++count == 2 ? throw new OperationCanceledException() : Sample()));
        await Assert.ThrowsAsync<OperationCanceledException>(() => first.PrepareAsync(recording, original, new(), "", new Progress<string>(), default));
        Assert.Single(JsonDisk.Read<ParticipantTranscriptCache>(first.CachePath(recording.Id))!.Chunks);
        int resumed = 0; var second = new ParticipantTranscriptService(library, folder.Root, (_, _, _) => new TimingFixture(() => { resumed++; return Sample(); }));
        var result = await second.PrepareAsync(recording, original, new(), "", new Progress<string>(), default);
        Assert.Equal(1, resumed); Assert.Equal(120, result.Segments[1].Words[0].StartSeconds); Assert.Equal(unchanged, File.ReadAllText(library.TranscriptPath(recording.Id)));
        await second.PrepareAsync(recording, original, new(), "", new Progress<string>(), default); Assert.Equal(1, resumed);
    }
    [Fact] public async Task UnsupportedDetailedCloudModelRetriesWhisperOnceAndRetainsSelection()
    {
        using var folder = new TestFolder(); var library = new LibraryStore(folder.Root); var recording = new Recording { DurationSeconds = .2 }; library.Save(recording); TestFolder.Wave(library.AudioPath(recording.Id), .2);
        var original = new TranscriptCache(await MeetingNotesService.AudioHashAsync(library.AudioPath(recording.Id), default), "model", "ko", ["원문"], true); JsonDisk.Write(library.TranscriptPath(recording.Id), original);
        var settings = new AppSettings { TranscriptionProvider = "openrouter", TranscriptionModel = "other-model" }; var requested = new List<string>();
        var service = new ParticipantTranscriptService(library, folder.Root, (s, _, _) => { requested.Add(s.TranscriptionModel); return new TimingFixture(() => s.TranscriptionModel == "other-model" ? throw new OpenRouterRequestException(HttpStatusCode.BadRequest, "unsupported") : Sample()); });
        var result = await service.PrepareAsync(recording, original, settings, "fixture", new Progress<string>(), default);
        Assert.Equal(new[] { "other-model", ParticipantTranscriptService.CloudFallbackModel }, requested); Assert.Equal(ParticipantTranscriptService.CloudFallbackModel, result.Model); Assert.Equal("other-model", settings.TranscriptionModel);
    }
    private static TranscribedAudio Sample() => new("말", [new TranscriptSegment(0, .1, "말") { Words = [new(0, .1, "말")] }]);
    private sealed class TimingFixture(Func<TranscribedAudio> run) : ITranscriber
    {
        public string Provider => "fixture"; public string Model => "fixture"; public string Fingerprint => "fixture"; public int ChunkSeconds => 120;
        public Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token) => Task.FromResult(run()); public void Dispose() { }
    }
}
