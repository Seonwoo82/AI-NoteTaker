using NoteTaker.Core;
using SherpaOnnx;

internal static class LongSpeakerDiarization
{
    public static void Run(string audio, string root, string output, double duration, int knownCount, float threshold, Action<string> progress)
    {
        var config = new OfflineSpeakerDiarizationConfig();
        config.Segmentation.Pyannote.Model = ModelDownload.PathFor(root, SpeakerModels.Segmentation); config.Segmentation.NumThreads = 2;
        config.Embedding.Model = ModelDownload.PathFor(root, SpeakerModels.Embedding); config.Embedding.NumThreads = 2;
        // An individual window may contain fewer people than the complete meeting. Apply the requested count globally.
        config.Clustering.NumClusters = -1; config.Clustering.Threshold = threshold;
        using var diarizer = new OfflineSpeakerDiarization(config);
        using var extractor = new SpeakerEmbeddingExtractor(new SpeakerEmbeddingExtractorConfig { Model = config.Embedding.Model, NumThreads = 2 });
        if (diarizer.SampleRate != SpeakerAudioWindows.SampleRate || extractor.Dim != SpeakerModels.EmbeddingDimensions) throw new InvalidDataException("화자 모델의 형식이 맞지 않습니다.");
        var merged = new SpeakerChunkMerger(duration); int index = 0;
        foreach (var window in SpeakerAudioWindows.Read(audio))
        {
            index++; progress($"긴 회의 화자 분석 · {index} / {(int)Math.Ceiling(duration / SpeakerAudioWindows.WindowSeconds)}");
            // Skip only exact digital silence. Ordinary quiet speech/noise still goes through the model.
            int first = Array.FindIndex(window.Samples, sample => sample != 0), last = Array.FindLastIndex(window.Samples, sample => sample != 0);
            var segments = new List<AcousticSegment>(); var speakers = new List<AcousticSpeaker>();
            if (first >= 0)
            {
                first = Math.Max(0, first - 4000); last = Math.Min(window.Samples.Length - 1, last + 4000);
                var samples = window.Samples[first..(last + 1)]; double offset = first / 16000d;
                if (samples.Length >= 1600)
                {
                    var callback = new OfflineSpeakerDiarizationProgressCallback((done, total, _) => { progress($"긴 회의 구간 {index} · 화자 특징 {done} / {total}"); return 0; });
                    var raw = diarizer.ProcessWithCallback(samples, callback, 0);
                    segments = raw.Select(s => new AcousticSegment(Math.Max(0, s.Start) + offset, Math.Min(samples.Length / 16000d, s.End) + offset, "local-" + s.Speaker))
                        .Where(s => s.End > s.Start).OrderBy(s => s.Start).ToList();
                    foreach (var id in segments.Select(s => s.SpeakerId).Distinct())
                    {
                        var speech = new List<float>(30 * 16000);
                        foreach (var segment in segments.Where(s => s.SpeakerId == id).OrderByDescending(s => s.End - s.Start))
                        {
                            int start = Math.Clamp((int)(segment.Start * 16000), 0, window.Samples.Length);
                            int end = Math.Min(Math.Clamp((int)(segment.End * 16000), start, window.Samples.Length), start + 30 * 16000 - speech.Count);
                            speech.AddRange(window.Samples.AsSpan(start, end - start)); if (speech.Count == 30 * 16000) break;
                        }
                        if (speech.Count < 8000) continue;
                        using var stream = extractor.CreateStream(); stream.AcceptWaveform(16000, speech.ToArray()); stream.InputFinished();
                        if (!extractor.IsReady(stream)) continue;
                        var embedding = extractor.Compute(stream);
                        if (!SpeakerWorkerClient.ValidEmbedding(embedding)) throw new InvalidDataException("화자 특징이 올바르지 않습니다.");
                        speakers.Add(new(id, embedding));
                    }
                }
            }
            merged.Add(window, new(SpeakerModels.EmbeddingModelId, window.Samples.Length / 16000d, segments, speakers));
        }
        progress("전체 회의의 참여자를 연결하는 중…");
        JsonDisk.Write(output, merged.Finish(knownCount));
    }
}
