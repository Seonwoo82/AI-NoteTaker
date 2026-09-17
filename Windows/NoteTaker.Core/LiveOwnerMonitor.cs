using System.Buffers.Binary;
using System.Diagnostics;

namespace NoteTaker.Core;

/// <summary>One cancellable local inference at a time; audio goes through an owned process pipe.</summary>
public sealed class LiveOwnerMonitor : IAsyncDisposable
{
    private readonly LocalVoiceProfile profile;
    private readonly Func<byte[], CancellationToken, Task<VoiceEmbedding>> embed;
    private CancellationTokenSource? cancellation;
    private Task operation = Task.CompletedTask;
    private OwnerSpeechState state = OwnerSpeechState.Listening;
    private long generation, lastPoll, lastResult;
    private bool active = true, disposed;
    public OwnerSpeechState State => state is OwnerSpeechState.Owner or OwnerSpeechState.Other && Stopwatch.GetElapsedTime(lastResult).TotalSeconds > 2.5 ? OwnerSpeechState.Listening : state;
    public string? LastError { get; private set; }
    public Task CurrentOperation => operation;
    public LiveOwnerMonitor(string modelRoot, LocalVoiceProfile profile, Func<byte[], CancellationToken, Task<VoiceEmbedding>>? embed = null)
    {
        profile.Validate(); this.profile = profile; this.embed = embed ?? new SpeakerWorkerClient(modelRoot).EmbedLiveAsync;
    }
    public void SetActive(bool value)
    {
        active = value; generation++; cancellation?.Cancel(); state = value ? OwnerSpeechState.Listening : OwnerSpeechState.Unavailable; lastPoll = 0;
    }
    public void Poll(Func<RecentAudioWindow?> readWindow)
    {
        if (!active || disposed || !operation.IsCompleted || Stopwatch.GetElapsedTime(lastPoll).TotalSeconds < 1.5) return;
        lastPoll = Stopwatch.GetTimestamp(); var window = readWindow(); if (window is null) { state = OwnerSpeechState.Listening; return; }
        var tail = window.Pcm.AsSpan(Math.Max(0, window.Pcm.Length - AudioFiles.SampleRate * 4 / 3)); double energy = 0;
        for (int i = 0; i + 1 < tail.Length; i += 2) { double sample = BinaryPrimitives.ReadInt16LittleEndian(tail[i..]) / 32768d; energy += sample * sample; }
        if (tail.Length == 0 || Math.Sqrt(energy / (tail.Length / 2)) < .0001) { state = OwnerSpeechState.Silence; return; }
        var source = new CancellationTokenSource(); cancellation = source; LastError = null;
        operation = AnalyzeAsync(window, generation, source);
    }
    private async Task AnalyzeAsync(RecentAudioWindow window, long expectedGeneration, CancellationTokenSource source)
    {
        try
        {
            var result = await embed(RecentAudioBuffer.Wave(window), source.Token);
            if (!source.IsCancellationRequested && generation == expectedGeneration && active && !disposed)
            { state = OwnerVoicePolicy.Classify(result.ModelId, result.Embedding, profile); lastResult = Stopwatch.GetTimestamp(); }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (generation == expectedGeneration && !disposed) { state = OwnerSpeechState.Uncertain; LastError = ex.Message; } }
        finally { if (ReferenceEquals(cancellation, source)) cancellation = null; source.Dispose(); }
    }
    public async ValueTask DisposeAsync() { disposed = true; SetActive(false); await operation; }
}
