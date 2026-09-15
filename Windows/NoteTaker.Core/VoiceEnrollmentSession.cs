using NAudio.Wave;

namespace NoteTaker.Core;

public sealed class VoiceEnrollmentSession(string root, string modelRoot, Func<IRecordingSession>? recordingFactory = null) : IAsyncDisposable
{
    private IRecordingSession? recording;
    private string? audioPath, trimmedPath, expectedRevision;
    public bool IsRecording => recording is not null;
    public double Duration => recording?.DurationSeconds ?? 0;
    public float Level => recording?.MicrophoneLevel ?? 0;
    public string? Failure => recording?.Failure;

    public async Task StartAsync(string? microphoneId, IProgress<string> progress, CancellationToken token)
    {
        if (recording is not null || audioPath is not null) throw new InvalidOperationException("이미 목소리를 등록하는 중입니다.");
        expectedRevision = new MeetingProfileStore(root).VoiceRevision;
        await SpeakerModels.PrepareAsync(modelRoot, progress, token); token.ThrowIfCancellationRequested();
        string directory = Path.Combine(root, "VoiceWork"); Directory.CreateDirectory(directory);
        audioPath = Path.Combine(directory, "enroll-" + Guid.NewGuid().ToString("N") + ".wav");
        recording = recordingFactory?.Invoke() ?? new AudioRecorder();
        try
        {
            await recording.StartAsync(audioPath, RecordingMode.Microphone, microphoneId, null);
            token.ThrowIfCancellationRequested();
        }
        catch { await DisposeAsync(); throw; }
    }
    public async Task<LocalVoiceProfile> FinishAsync(IProgress<string> progress, CancellationToken token)
    {
        if (recording is null || audioPath is null) throw new InvalidOperationException("목소리 녹음을 먼저 시작해 주세요.");
        try
        {
            string? failure = recording.Failure;
            await recording.StopAsync(); failure ??= recording.Failure;
            await recording.DisposeAsync(); recording = null; token.ThrowIfCancellationRequested();
            if (failure is not null) throw new InvalidDataException(failure);
            using (var reader = new AudioFileReader(audioPath))
            {
                if (reader.TotalTime.TotalSeconds < 10) throw new InvalidDataException("10초 이상 예문을 읽어 주세요. 기존 목소리 프로필은 유지됩니다.");
                if (reader.TotalTime.TotalSeconds > 30)
                {
                    trimmedPath = Path.ChangeExtension(audioPath, ".trimmed.wav");
                    var samples = new AudioRangeSampleProvider(reader, [new(0, 30)]);
                    using var writer = new WaveFileWriter(trimmedPath, samples.WaveFormat);
                    var buffer = new float[16000]; int read;
                    while ((read = samples.Read(buffer, 0, buffer.Length)) > 0) { token.ThrowIfCancellationRequested(); writer.WriteSamples(buffer, 0, read); }
                }
            }
            progress.Report("목소리 특징을 확인하는 중…");
            var result = await new SpeakerWorkerClient(modelRoot).EmbedAsync(trimmedPath ?? audioPath, progress, token);
            var profile = new LocalVoiceProfile(result.ModelId, result.Embedding, DateTimeOffset.UtcNow, result.SampleDuration); profile.Validate();
            token.ThrowIfCancellationRequested(); new MeetingProfileStore(root).SaveVoice(profile, expectedRevision); return profile;
        }
        finally { await DisposeAsync(); }
    }
    public async ValueTask DisposeAsync()
    {
        Exception? failure = null;
        if (recording is { } active)
        {
            try { await active.DisposeAsync(); }
            catch (Exception ex) { failure = ex; }
            finally { recording = null; }
        }
        // Only this session's GUID-named temporary recordings are removed.
        foreach (string? path in new[] { audioPath, trimmedPath })
        {
            try { if (path is not null && File.Exists(path)) File.Delete(path); }
            catch (Exception ex) { failure ??= ex; }
        }
        if (failure is not null) throw new IOException("등록용 녹음을 정리하지 못했습니다. 파일 사용 상태를 확인해 주세요.", failure);
        audioPath = trimmedPath = null;
    }
}
