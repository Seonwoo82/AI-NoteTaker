using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using NAudio.Wave;

namespace NoteTaker.Core;

public sealed record ParticipantTranscriptCache(string AudioHash, string SourceFingerprint, string RequestFingerprint, string Model,
    List<TranscribedAudio> Chunks, bool Complete)
{ public int SchemaVersion { get; init; } = 1; }

public sealed class ParticipantTranscriptService(LibraryStore library, string modelRoot,
    Func<AppSettings, string, IProgress<string>, ITranscriber>? factory = null)
{
    public const string CloudFallbackModel = "openai/whisper-large-v3";
    public string CachePath(Guid id) => Path.Combine(library.DirectoryFor(id), "participant-transcript-local.json");
    public async Task<(string Model, List<TranscriptSegment> Segments)> PrepareAsync(Recording recording, TranscriptCache original,
        AppSettings settings, string key, IProgress<string> progress, CancellationToken token)
    {
        // An imported transcript is an explicit source choice; do not replace it with a second recognition.
        if (original.Source == "import" || original.Segments.Any(s => s.Words.Count > 0)) return (original.Model, original.Segments);
        string audio = library.AudioPath(recording.Id), hash = await MeetingNotesService.AudioHashAsync(audio, token);
        if (hash != original.AudioHash) throw new InvalidOperationException("현재 녹음과 전사문이 다릅니다.");
        string sourceFingerprint = Fingerprint(original);
        string requestFingerprint = $"timed-v1/{settings.TranscriptionProvider}/{settings.TranscriptionModel}/{settings.SpeechLanguage}/{ModelDownload.WhisperTurbo.Sha256}";
        ParticipantTranscriptCache? cache = null;
        if (File.Exists(CachePath(recording.Id)))
        {
            if (new FileInfo(CachePath(recording.Id)).Length > 64 * 1024 * 1024) throw new InvalidDataException("상세 전사 캐시가 너무 큽니다.");
            try { cache = JsonDisk.Read<ParticipantTranscriptCache>(CachePath(recording.Id)); } catch (JsonException) { }
        }
        if (cache?.SchemaVersion != 1 || cache.AudioHash != hash || cache.SourceFingerprint != sourceFingerprint || cache.RequestFingerprint != requestFingerprint)
            cache = new(hash, sourceFingerprint, requestFingerprint, settings.TranscriptionProvider == "openrouter" ? DetailedCloudModel(settings.TranscriptionModel) : "large-v3-turbo", [], false);
        if (cache.Chunks is not { Count: <= 180 }) throw new InvalidDataException("상세 전사 캐시가 올바르지 않습니다.");
        foreach (var chunk in cache.Chunks) TranscriptTiming.Validate(chunk, 120);
        if (cache.Complete) return Flatten(cache, recording.DurationSeconds);
        if (recording.DurationSeconds > 6 * 3600) throw new InvalidOperationException("참여자 분석은 6시간 이하 녹음을 지원합니다.");
        if (factory is null && settings.TranscriptionProvider != "openrouter")
        {
            progress.Report("참여자 발화 시간을 확인할 로컬 Whisper를 준비합니다. 기존 전사문은 유지됩니다.");
            await ModelDownload.EnsureAsync(modelRoot, ModelDownload.WhisperTurbo, progress, token);
        }
        ITranscriber Create(string model) => factory?.Invoke(settings with { TranscriptionModel = model }, key, progress) ??
            (settings.TranscriptionProvider == "openrouter" ? new CloudTranscriber(new(), settings with { TranscriptionModel = model }, key, true, true) : new WhisperTranscriber(modelRoot, settings, progress, true));
        ITranscriber engine = Create(cache.Model);
        try
        {
            int index = 0;
            foreach (var wave in AudioFiles.ReadTranscriptionChunks(audio))
            {
                token.ThrowIfCancellationRequested();
                if (index >= 180) throw new InvalidOperationException("참여자 분석은 6시간 이하 녹음을 지원합니다.");
                if (index >= cache.Chunks.Count)
                {
                    progress.Report($"참여자 발화 시간 전사 · {engine.Model} · {index + 1} / {(int)Math.Ceiling(recording.DurationSeconds / 120)}");
                    TranscribedAudio result;
                    try { result = await engine.TranscribeAsync(wave, token); }
                    catch (Exception ex) when (settings.TranscriptionProvider == "openrouter" && cache.Model != CloudFallbackModel &&
                        (ex is TranscriptionTimingException || ex is OpenRouterRequestException { Status: HttpStatusCode.BadRequest }))
                    {
                        engine.Dispose(); engine = Create(CloudFallbackModel); cache = cache with { Model = CloudFallbackModel };
                        progress.Report("선택한 모델에 시간 정보가 없어 Whisper로 참여자 발화 시간을 확인합니다.");
                        result = await engine.TranscribeAsync(wave, token);
                    }
                    using var reader = new WaveFileReader(new MemoryStream(wave)); TranscriptTiming.Validate(result, reader.TotalTime.TotalSeconds);
                    token.ThrowIfCancellationRequested(); cache.Chunks.Add(result); Save(cache, recording.Id);
                }
                index++;
            }
            if (index != cache.Chunks.Count) throw new InvalidDataException("상세 전사의 구간 수가 녹음과 다릅니다.");
            if (hash != await MeetingNotesService.AudioHashAsync(audio, token) || Fingerprint(JsonDisk.Read<TranscriptCache>(library.TranscriptPath(recording.Id))!) != sourceFingerprint)
                throw new InvalidOperationException("시간 전사 중 원본이 변경되었습니다. 다시 분석해 주세요.");
            cache = cache with { Complete = true }; Save(cache, recording.Id); return Flatten(cache, recording.DurationSeconds);
        }
        finally { engine.Dispose(); }
    }
    public static string DetailedCloudModel(string selected) => selected.StartsWith("openai/gpt", StringComparison.Ordinal) || selected.StartsWith("microsoft/mai-transcribe", StringComparison.Ordinal) ? CloudFallbackModel : selected;
    public static string Fingerprint(TranscriptCache cache) => Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(cache, JsonDisk.Options)));
    private void Save(ParticipantTranscriptCache cache, Guid id)
    {
        if (JsonSerializer.SerializeToUtf8Bytes(cache, JsonDisk.Options).Length > 64 * 1024 * 1024) throw new InvalidDataException("상세 전사 결과가 너무 큽니다.");
        JsonDisk.Write(CachePath(id), cache);
    }
    private static (string Model, List<TranscriptSegment> Segments) Flatten(ParticipantTranscriptCache cache, double duration)
    {
        var segments = new List<TranscriptSegment>();
        for (int index = 0; index < cache.Chunks.Count; index++)
        {
            double offset = index * 120, end = Math.Min(duration, offset + 120);
            foreach (var segment in cache.Chunks[index].Segments)
            {
                var absolute = TranscriptTiming.Offset(segment, offset);
                if (absolute.StartSeconds >= end) throw new InvalidDataException("상세 전사가 녹음 범위를 벗어났습니다.");
                segments.Add(absolute with { EndSeconds = Math.Min(absolute.EndSeconds, end),
                    Words = absolute.Words.Any(w => w.StartSeconds > end) ? [] : absolute.Words.Select(w => w with { EndSeconds = Math.Min(w.EndSeconds, end) }).ToList() });
            }
        }
        return (cache.Model, segments);
    }
}
