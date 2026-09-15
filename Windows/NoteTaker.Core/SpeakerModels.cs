using System.Diagnostics;

namespace NoteTaker.Core;

public static class SpeakerModels
{
    public const string EmbeddingModelId = "sherpa-1.13.8-3dspeaker-eres2net-512";
    public const int EmbeddingDimensions = 512;
    public static readonly ModelAsset SegmentationArchive = new("Speaker/segmentation-3.0.tar.bz2",
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
        6958444, "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488");
    public static readonly ModelAsset Segmentation = new("Speaker/segmentation-3.0.onnx", "", 5992913,
        "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079");
    public static readonly ModelAsset Embedding = new("Speaker/3dspeaker-eres2net.onnx",
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx",
        39593761, "1a331345f04805badbb495c775a6ddffcdd1a732567d5ec8b3d5749e3c7a5e4b");
    private static readonly SemaphoreSlim preparation = new(1);
    public static async Task VerifyAsync(string root, CancellationToken token)
    {
        await ModelDownload.VerifyAsync(ModelDownload.PathFor(root, Segmentation), Segmentation, token);
        await ModelDownload.VerifyAsync(ModelDownload.PathFor(root, Embedding), Embedding, token);
    }
    public static async Task PrepareAsync(string root, IProgress<string> progress, CancellationToken token)
    {
        await preparation.WaitAsync(token);
        try
        {
            string segmentation = ModelDownload.PathFor(root, Segmentation);
            bool valid = false;
            try { await ModelDownload.VerifyAsync(segmentation, Segmentation, token); valid = true; }
            catch (InvalidDataException) { }
            if (!valid)
            {
                string archive = await ModelDownload.EnsureAsync(root, SegmentationArchive, progress, token);
                string staging = Path.Combine(Path.GetDirectoryName(archive)!, "extract-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(staging);
                var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "tar.exe"))
                { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardError = true };
                foreach (string argument in new[] { "-xjf", archive, "-C", staging, "sherpa-onnx-pyannote-segmentation-3-0/model.onnx", "sherpa-onnx-pyannote-segmentation-3-0/LICENSE" }) start.ArgumentList.Add(argument);
                using var process = Process.Start(start) ?? throw new IOException("화자 모델 압축을 풀 수 없습니다.");
                using var registration = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
                var error = process.StandardError.ReadToEndAsync(token);
                await process.WaitForExitAsync(CancellationToken.None); token.ThrowIfCancellationRequested();
                if (process.ExitCode != 0) throw new IOException("화자 모델 압축 해제에 실패했습니다.");
                await error;
                string extracted = Path.Combine(staging, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx");
                await ModelDownload.VerifyAsync(extracted, Segmentation, token); token.ThrowIfCancellationRequested();
                File.Move(extracted, segmentation, overwrite: true);
                File.Copy(Path.Combine(staging, "sherpa-onnx-pyannote-segmentation-3-0", "LICENSE"), Path.Combine(Path.GetDirectoryName(segmentation)!, "SEGMENTATION-LICENSE.txt"), overwrite: true);
            }
            await ModelDownload.EnsureAsync(root, Embedding, progress, token);
        }
        finally { preparation.Release(); }
    }
}

public sealed record AcousticSegment(double Start, double End, string SpeakerId);
public sealed record AcousticSpeaker(string Id, float[] Embedding);
public sealed record AcousticDiarization(string ModelId, double Duration, List<AcousticSegment> Segments, List<AcousticSpeaker> Speakers);
public sealed record VoiceEmbedding(string ModelId, float[] Embedding, double SampleDuration, double SpeechDuration);
