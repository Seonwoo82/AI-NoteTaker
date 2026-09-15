using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed class SpeakerWorkerClient(string root, string? executable = null, int knownSpeakerCount = 0)
{
    public async Task<AcousticDiarization> DiarizeAsync(string audioPath, IProgress<string> progress, CancellationToken token)
    {
        var result = await RunAsync<AcousticDiarization>("diarize", audioPath, progress, token);
        if (result.ModelId != SpeakerModels.EmbeddingModelId || !double.IsFinite(result.Duration) || result.Duration <= 0 ||
            result.Segments is null || result.Speakers is null || result.Speakers.Count > 64 || result.Segments.Count > 20000)
            throw new InvalidDataException("화자 분석 결과가 올바르지 않습니다.");
        var ids = result.Speakers.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
        if (ids.Count != result.Speakers.Count || result.Speakers.Any(x => !ValidEmbedding(x.Embedding))) throw new InvalidDataException("화자 특징이 올바르지 않습니다.");
        double previous = 0;
        foreach (var segment in result.Segments)
        {
            if (!double.IsFinite(segment.Start) || !double.IsFinite(segment.End) || segment.Start < previous || segment.Start < 0 || segment.End <= segment.Start || segment.End > result.Duration || string.IsNullOrWhiteSpace(segment.SpeakerId))
                throw new InvalidDataException("화자 구간 시간이 올바르지 않습니다.");
            previous = segment.Start;
        }
        return result;
    }
    public async Task<VoiceEmbedding> EmbedAsync(string audioPath, IProgress<string> progress, CancellationToken token)
    {
        var result = await RunAsync<VoiceEmbedding>("embed", audioPath, progress, token);
        if (result.ModelId != SpeakerModels.EmbeddingModelId || !ValidEmbedding(result.Embedding) || !double.IsFinite(result.SampleDuration) ||
            !double.IsFinite(result.SpeechDuration) || result.SampleDuration is <= 0 or > 60 || result.SpeechDuration < 3 || result.SpeechDuration > result.SampleDuration)
            throw new InvalidDataException("목소리 등록 결과가 올바르지 않습니다.");
        return result;
    }
    private async Task<T> RunAsync<T>(string command, string audioPath, IProgress<string> progress, CancellationToken token)
    {
        if (knownSpeakerCount is < 0 or > 64) throw new InvalidDataException("참여자 수는 자동 또는 1~64명으로 설정해 주세요.");
        await SpeakerModels.VerifyAsync(root, token);
        string worker = executable ?? Path.Combine(AppContext.BaseDirectory, "SpeechWorker", "AI-NoteTaker.SpeechWorker.exe");
        if (!File.Exists(worker)) throw new InvalidDataException("화자 분석 실행 파일이 없습니다. 앱을 폴더째 다시 설치해 주세요.");
        string work = Path.Combine(root, "VoiceWork"); Directory.CreateDirectory(work);
        string output = Path.Combine(work, Guid.NewGuid().ToString("N") + ".json");
        var start = new ProcessStartInfo(worker)
        { UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string argument in new[] { command, Path.GetFullPath(audioPath), Path.GetFullPath(root), output }) start.ArgumentList.Add(argument);
        start.ArgumentList.Add("0.9"); start.ArgumentList.Add(knownSpeakerCount.ToString(System.Globalization.CultureInfo.InvariantCulture));
        // Framework-dependent development builds use the same SDK runtime as their parent.
        string? sdk = Directory.GetParent(RuntimeEnvironment.GetRuntimeDirectory())?.Parent?.Parent?.FullName;
        if (sdk is not null && File.Exists(Path.Combine(sdk, "dotnet.exe"))) { start.Environment["DOTNET_ROOT"] = sdk; start.Environment["DOTNET_ROOT_X64"] = sdk; }
        token.ThrowIfCancellationRequested();
        using var process = Process.Start(start) ?? throw new IOException("화자 분석을 시작할 수 없습니다.");
        using var registration = token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { } });
        try
        {
            var errors = process.StandardError.ReadToEndAsync();
            var messages = Task.Run(async () =>
            {
                while (await process.StandardOutput.ReadLineAsync() is { } line)
                {
                    if (line.Length > 4096) continue;
                    try
                    {
                        using var json = JsonDocument.Parse(line);
                        if (json.RootElement.TryGetProperty("progress", out var value) && value.ValueKind == JsonValueKind.String) progress.Report(value.GetString()!);
                    }
                    catch (JsonException) { }
                }
            });
            await process.WaitForExitAsync(CancellationToken.None); await messages;
            string error = await errors; token.ThrowIfCancellationRequested();
            if (process.ExitCode != 0)
            {
                string message = error.Trim().Split('\n').LastOrDefault() ?? "";
                throw new InvalidDataException(message.Length is > 0 and <= 200 ? message : "화자 분석을 완료하지 못했습니다. 이전 전사문과 회의록은 유지됩니다.");
            }
            if (!File.Exists(output) || new FileInfo(output).Length > 4 * 1024 * 1024) throw new InvalidDataException("화자 분석 결과를 읽을 수 없습니다.");
            return JsonDisk.Read<T>(output) ?? throw new InvalidDataException("화자 분석 결과가 비어 있습니다.");
        }
        finally { if (File.Exists(output)) File.Delete(output); }
    }
    public static bool ValidEmbedding(float[]? values) => values is { Length: SpeakerModels.EmbeddingDimensions } && values.All(float.IsFinite) && values.Sum(x => (double)x * x) > 1e-12;
    public static double Cosine(float[] first, float[] second)
    {
        if (!ValidEmbedding(first) || !ValidEmbedding(second)) throw new InvalidDataException("비교할 목소리 특징이 올바르지 않습니다.");
        double product = 0, firstNorm = 0, secondNorm = 0;
        for (int i = 0; i < first.Length; i++) { product += first[i] * second[i]; firstNorm += first[i] * first[i]; secondNorm += second[i] * second[i]; }
        return Math.Clamp(product / Math.Sqrt(firstNorm * secondNorm), -1, 1);
    }
}
