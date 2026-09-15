using System.Text.Json;
using NoteTaker.Core;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using SherpaOnnx;

if (args.Length is not (4 or 5 or 6) || args[0] is not ("diarize" or "embed")) return 2;
try
{
    string command = args[0], source = Path.GetFullPath(args[1]), root = Path.GetFullPath(args[2]), output = Path.GetFullPath(args[3]);
    await SpeakerModels.VerifyAsync(root, default);
    Progress("화자 분석용 오디오를 읽는 중…");
    var samples = ReadAudio(source, command == "embed" ? 60 : 4 * 3600);
    if (samples.Length < 1600) throw new InvalidDataException("분석할 음성이 너무 짧습니다.");
    if (command == "embed") NormalizeQuietSpeech(samples);
    var config = new OfflineSpeakerDiarizationConfig();
    config.Segmentation.Pyannote.Model = ModelDownload.PathFor(root, SpeakerModels.Segmentation);
    config.Segmentation.NumThreads = 2;
    config.Embedding.Model = ModelDownload.PathFor(root, SpeakerModels.Embedding);
    config.Embedding.NumThreads = 2;
    int knownCount = args.Length == 6 ? int.Parse(args[5], System.Globalization.CultureInfo.InvariantCulture) : 0;
    if (knownCount is < 0 or > 64) throw new InvalidDataException("참여자 수가 올바르지 않습니다.");
    config.Clustering.NumClusters = knownCount == 0 ? -1 : knownCount;
    config.Clustering.Threshold = args.Length >= 5 ? float.Parse(args[4], System.Globalization.CultureInfo.InvariantCulture) : .9f;
    if (!float.IsFinite(config.Clustering.Threshold) || config.Clustering.Threshold is < .05f or > 1.5f) throw new InvalidDataException("화자 구분 설정이 올바르지 않습니다.");
    using var diarizer = new OfflineSpeakerDiarization(config);
    if (diarizer.SampleRate != 16000) throw new InvalidDataException("화자 모델의 오디오 형식이 맞지 않습니다.");
    Progress("음성 구간과 참여자를 구분하는 중…");
    // Native callbacks report progress but do not honor a cancellation return value.
    // The app owns this worker process and terminates it when the user cancels.
    var callback = new OfflineSpeakerDiarizationProgressCallback((done, total, _) => { Progress($"화자 특징 분석 · {done} / {total}"); return 0; });
    var rawSegments = diarizer.ProcessWithCallback(samples, callback, 0);
    var segments = rawSegments.Select(x => new AcousticSegment(Math.Max(0, x.Start), Math.Min(samples.Length / 16000d, x.End), "acoustic-" + x.Speaker))
        .Where(x => x.End > x.Start).OrderBy(x => x.Start).ToList();
    var ownerConfig = new SpeakerEmbeddingExtractorConfig { Model = ModelDownload.PathFor(root, SpeakerModels.Embedding), NumThreads = 2 };
    using var extractor = new SpeakerEmbeddingExtractor(ownerConfig);
    if (extractor.Dim != SpeakerModels.EmbeddingDimensions) throw new InvalidDataException("화자 모델 차원이 맞지 않습니다.");
    if (command == "embed")
    {
        double voiced = UnionDuration(segments);
        if (voiced < 3) throw new InvalidDataException("말소리가 충분하지 않습니다. 조용한 곳에서 예문을 읽어 주세요.");
        if (segments.GroupBy(s => s.SpeakerId).Count(g => g.Sum(s => s.End - s.Start) >= 3) > 1)
            throw new InvalidDataException("여러 목소리가 감지되었습니다. 혼자 조용한 곳에서 예문을 읽어 주세요.");
        var speech = CollectSamples(samples, segments, 30);
        var embedding = Extract(extractor, speech);
        JsonDisk.Write(output, new VoiceEmbedding(SpeakerModels.EmbeddingModelId, embedding, samples.Length / 16000d, voiced));
    }
    else
    {
        var speakers = new List<AcousticSpeaker>();
        foreach (string id in segments.Select(x => x.SpeakerId).Distinct())
        {
            var speech = CollectSamples(samples, segments.Where(x => x.SpeakerId == id).OrderByDescending(x => x.End - x.Start), 30);
            if (speech.Length >= 8000) speakers.Add(new AcousticSpeaker(id, Extract(extractor, speech)));
        }
        JsonDisk.Write(output, new AcousticDiarization(SpeakerModels.EmbeddingModelId, samples.Length / 16000d, segments, speakers));
    }
    return 0;
}
catch (Exception ex)
{
    Console.Error.WriteLine(ex is InvalidDataException ? ex.Message : "로컬 화자 분석을 완료하지 못했습니다: " + ex.GetType().Name);
    return 1;
}

static void Progress(string message) => Console.WriteLine(JsonSerializer.Serialize(new { progress = message }));
static float[] ReadAudio(string path, int maximumSeconds)
{
    using var reader = new AudioFileReader(path);
    if (reader.TotalTime.TotalSeconds > maximumSeconds) throw new InvalidDataException($"화자 분석은 최대 {maximumSeconds / 60}분까지 지원합니다.");
    ISampleProvider source = reader;
    if (source.WaveFormat.Channels == 2) source = new StereoToMonoSampleProvider(source);
    if (source.WaveFormat.Channels != 1) throw new InvalidDataException("모노 또는 스테레오 파일이 필요합니다.");
    source = new WdlResamplingSampleProvider(source, 16000);
    var result = new float[Math.Min(maximumSeconds * 16000, (int)Math.Ceiling(reader.TotalTime.TotalSeconds * 16000) + 16000)];
    int count = 0, read;
    while (count < result.Length && (read = source.Read(result, count, result.Length - count)) > 0) count += read;
    Array.Resize(ref result, count);
    foreach (float sample in result) if (!float.IsFinite(sample)) throw new InvalidDataException("오디오 데이터가 올바르지 않습니다.");
    return result;
}
static float[] CollectSamples(float[] samples, IEnumerable<AcousticSegment> segments, int seconds)
{
    var result = new List<float>(seconds * 16000);
    foreach (var segment in segments)
    {
        int start = Math.Clamp((int)(segment.Start * 16000), 0, samples.Length);
        int end = Math.Min(Math.Clamp((int)(segment.End * 16000), start, samples.Length), start + seconds * 16000 - result.Count);
        result.AddRange(samples.AsSpan(start, end - start));
        if (result.Count >= seconds * 16000) break;
    }
    return result.ToArray();
}
static float[] Extract(SpeakerEmbeddingExtractor extractor, float[] samples)
{
    using var stream = extractor.CreateStream(); stream.AcceptWaveform(16000, samples); stream.InputFinished();
    if (!extractor.IsReady(stream)) throw new InvalidDataException("목소리 특징을 계산할 말소리가 부족합니다.");
    var result = extractor.Compute(stream);
    if (!SpeakerWorkerClient.ValidEmbedding(result)) throw new InvalidDataException("목소리 특징이 올바르지 않습니다.");
    return result;
}
static void NormalizeQuietSpeech(float[] samples)
{
    double mean = samples.Average(x => (double)x), sum = 0; float peak = 0;
    for (int i = 0; i < samples.Length; i++) { samples[i] -= (float)mean; peak = Math.Max(peak, Math.Abs(samples[i])); sum += samples[i] * samples[i]; }
    double rms = Math.Sqrt(sum / samples.Length);
    if (rms < .0001 || peak < .0005) throw new InvalidDataException("마이크 입력이 너무 작거나 말소리가 없습니다.");
    float gain = (float)Math.Min(12, Math.Min(.08 / rms, .95 / peak));
    if (gain > 1) for (int i = 0; i < samples.Length; i++) samples[i] *= gain;
}
static double UnionDuration(List<AcousticSegment> segments)
{
    double total = 0, end = 0;
    foreach (var segment in segments) { total += Math.Max(0, segment.End - Math.Max(end, segment.Start)); end = Math.Max(end, segment.End); }
    return total;
}
