using NAudio.Wave;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class LongSpeakerTests
{
    private static float[] Vector(int index) { var values = new float[512]; values[index] = 1; return values; }
    private static SpeakerAudioWindow Window(double start, double keepStart, double keepEnd) => new(start, keepStart, keepEnd, []);
    private static AcousticDiarization Chunk(double duration, AcousticSegment[] segments, params AcousticSpeaker[] speakers) => new(SpeakerModels.EmbeddingModelId, duration, segments.ToList(), speakers.ToList());

    [Fact] public void StreamingAudioWindowsCoverEachCoreFrameOnceAndBoundMemory()
    {
        using var test = new TestFolder(); string path = Path.Combine(test.Root, "long.wav");
        using (var writer = new WaveFileWriter(path, WaveFormat.CreateIeeeFloatWaveFormat(16000, 1)))
            for (int second = 0; second < 601; second++) writer.WriteSamples(Enumerable.Repeat(second / 1000f, 16000).ToArray(), 0, 16000);
        var windows = SpeakerAudioWindows.Read(path).ToArray(); Assert.Equal(3, windows.Length);
        Assert.Equal(new[] { 0d, 300d, 600d }, windows.Select(w => w.KeepStart)); Assert.Equal(new[] { 300d, 600d, 601d }, windows.Select(w => w.KeepEnd));
        Assert.Equal(298, windows[1].Start); Assert.Equal(.3f, windows[1].Samples[2 * 16000]);
        Assert.Equal(.6f, windows[2].Samples[2 * 16000]);
        Assert.All(windows, w => Assert.InRange(w.Samples.Length, 1, (300 + 4) * 16000));
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => SpeakerAudioWindows.Read(path, cancellation.Token).First());
    }
    [Theory]
    [InlineData(21600, true)]
    [InlineData(21600.01, false)]
    [InlineData(0, false)]
    [InlineData(double.NaN, false)]
    public void SixHourLimitIsSharedAndInclusive(double seconds, bool valid)
    {
        if (valid) SpeakerAudioWindows.ValidateDuration(seconds);
        else Assert.Throws<InvalidDataException>(() => SpeakerAudioWindows.ValidateDuration(seconds));
    }
    [Fact] public void SameVoiceAcrossWindowIndicesKeepsIdentityAndOverlapIsCountedOnce()
    {
        var merger = new SpeakerChunkMerger(600);
        merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 20, "local-0"), new(290, 302, "local-1")], new("local-0", Vector(0)), new("local-1", Vector(1))));
        merger.Add(Window(298, 300, 600), Chunk(302, [new(0, 12, "local-0"), new(20, 30, "local-1")], new("local-0", Vector(1)), new("local-1", Vector(0))));
        var result = merger.Finish(); Assert.Equal(2, result.Speakers.Count); Assert.Equal(3, result.Segments.Count);
        var crossing = Assert.Single(result.Segments, s => s.Start == 290); Assert.Equal(310, crossing.End);
        Assert.Equal(result.Segments[0].SpeakerId, result.Segments[2].SpeakerId); Assert.NotEqual(result.Segments[0].SpeakerId, crossing.SpeakerId);
    }
    [Fact] public void DifferentVoicesWithSameLocalNumberStaySeparate()
    {
        var merger = new SpeakerChunkMerger(600);
        merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 20, "local-0")], new AcousticSpeaker("local-0", Vector(0))));
        merger.Add(Window(298, 300, 600), Chunk(302, [new(10, 20, "local-0")], new AcousticSpeaker("local-0", Vector(1))));
        var result = merger.Finish(); Assert.Equal(2, result.Speakers.Count); Assert.NotEqual(result.Segments[0].SpeakerId, result.Segments[1].SpeakerId);
    }
    [Fact] public void ExplicitCountGroupsGloballyWithoutInventingParticipantsInQuietWindows()
    {
        var merger = new SpeakerChunkMerger(900);
        merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", Vector(0))));
        merger.Add(Window(298, 300, 600), Chunk(304, [], []));
        merger.Add(Window(598, 600, 900), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", Vector(1))));
        var result = merger.Finish(1); Assert.Single(result.Speakers); Assert.Equal(result.Segments[0].SpeakerId, result.Segments[1].SpeakerId);
    }
    [Fact] public void GlobalCountCannotMergeSimultaneouslySpeakingPeople()
    {
        var merger = new SpeakerChunkMerger(300);
        merger.Add(Window(0, 0, 300), Chunk(300, [new(10, 20, "0"), new(15, 25, "1")], new("0", Vector(0)), new("1", Vector(1))));
        Assert.Throws<InvalidDataException>(() => merger.Finish(1));
    }
    [Fact] public void MissingWindowAndInvalidTimesCannotProduceACompletedTranscript()
    {
        var merger = new SpeakerChunkMerger(600);
        Assert.Throws<InvalidDataException>(() => merger.Add(Window(298, 300, 600), Chunk(302, [], [])));
        Assert.Throws<InvalidDataException>(() => merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 400, "0")], new AcousticSpeaker("0", Vector(0)))));
        Assert.Throws<InvalidDataException>(() => merger.Finish());
    }
    [Fact] public void AutomaticCountReconcilesRecurringVoiceBelowStrictOnlineMatch()
    {
        var changedVoice = Vector(0); changedVoice[0] = .6f; changedVoice[1] = .8f;
        var merger = new SpeakerChunkMerger(600);
        merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", Vector(0))));
        merger.Add(Window(298, 300, 600), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", changedVoice)));
        var result = merger.Finish(); Assert.Single(result.Speakers);
        Assert.Equal(result.Segments[0].SpeakerId, result.Segments[1].SpeakerId);
    }
    [Fact] public void CompleteLinkDoesNotCollapseDifferentVoicesThroughIntermediateSimilarity()
    {
        var middle = Vector(0); middle[0] = .6f; middle[1] = .8f;
        var other = Vector(0); other[0] = -.28f; other[1] = .96f;
        var merger = new SpeakerChunkMerger(900);
        merger.Add(Window(0, 0, 300), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", Vector(0))));
        merger.Add(Window(298, 300, 600), Chunk(304, [new(10, 20, "0")], new AcousticSpeaker("0", middle)));
        merger.Add(Window(598, 600, 900), Chunk(302, [new(10, 20, "0")], new AcousticSpeaker("0", other)));
        var result = merger.Finish(); Assert.Equal(2, result.Speakers.Count);
        Assert.NotEqual(result.Segments[0].SpeakerId, result.Segments[2].SpeakerId);
    }
    [Fact] public void AutomaticCountKeepsOverlappingVoicesDespiteHighEmbeddingSimilarity()
    {
        var similar = Vector(0); similar[1] = .1f;
        var merger = new SpeakerChunkMerger(300);
        merger.Add(Window(0, 0, 300), Chunk(300, [new(10, 20, "0"), new(15, 25, "1")], new("0", Vector(0)), new("1", similar)));
        Assert.Equal(2, merger.Finish().Speakers.Count);
    }
}
