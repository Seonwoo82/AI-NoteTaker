using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json;

namespace NoteTaker.Core;

public static class QwenModels
{
    public static readonly ModelAsset Runtime = new("llama-b10809-bin-win-cuda-12.4-x64.zip",
        "https://github.com/ggml-org/llama.cpp/releases/download/b10809/llama-b10809-bin-win-cuda-12.4-x64.zip", 253938543,
        "c77bfcd9ed8d91e8721a2d6a290b907fddd4fa5412a47b21c6fa1709116b85f9");
    public static ModelAsset Model(string size) => size == "0.6b"
        ? new("Qwen3-ASR-0.6B-Q8_0.gguf", "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/Qwen3-ASR-0.6B-Q8_0.gguf", 804749248, "bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971")
        : new("Qwen3-ASR-1.7B-Q8_0.gguf", "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/Qwen3-ASR-1.7B-Q8_0.gguf", 2165034944, "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57");
    public static ModelAsset Projector(string size) => size == "0.6b"
        ? new("mmproj-Qwen3-ASR-0.6B-bf16.gguf", "https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/mmproj-Qwen3-ASR-0.6B-bf16.gguf", 378575520, "dae36c855f9a82a8916bea2238b24bda69a39d8da8b2f46dee7c103775656039")
        : new("mmproj-Qwen3-ASR-1.7B-bf16.gguf", "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/36a678687ba7d07a74ca70ccb0e36902e005fb80/mmproj-Qwen3-ASR-1.7B-bf16.gguf", 641773984, "8882e9ddab3186f9aa71b1417c847177913e1466655ac944cf86e9b846735d62");
    public static string RuntimeDirectory(string root) => Path.Combine(root, "Tools", "llama-b10809");
    public static async Task PrepareAsync(string root, string size, IProgress<string> progress, CancellationToken token)
    {
        await ModelDownload.EnsureAsync(root, Model(size), progress, token);
        await ModelDownload.EnsureAsync(root, Projector(size), progress, token);
        string folder = RuntimeDirectory(root);
        if (!File.Exists(Path.Combine(folder, "ready.txt")))
        {
            string zip = await ModelDownload.EnsureAsync(root, Runtime, progress, token);
            progress.Report("Qwen 실행 환경 압축 해제 중…");
            await Task.Run(() => ZipFile.ExtractToDirectory(zip, folder, true), token);
            token.ThrowIfCancellationRequested(); File.WriteAllText(Path.Combine(folder, "ready.txt"), Runtime.Sha256);
        }
        await LocalRuntime.PrepareCudaAsync(root, progress, token);
    }
}

public sealed class QwenTranscriber(string root, AppSettings settings, IProgress<string> progress) : ITranscriber
{
    private Process? process;
    private HttpClient? http;
    public string Provider => "qwen";
    public string Model => "qwen3-asr-" + settings.QwenAsrModel;
    public string Fingerprint => $"llama-b10809/{QwenModels.Model(settings.QwenAsrModel).Sha256}/{QwenModels.Projector(settings.QwenAsrModel).Sha256}/auto/pcm16k-v1/chunk120";
    public int ChunkSeconds => 120;
    public async Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (AudioFiles.IsDigitalSilence(wav)) return new TranscribedAudio("", []);
        if (http is null)
        {
            await ModelDownload.VerifyAsync(ModelDownload.PathFor(root, QwenModels.Model(settings.QwenAsrModel)), QwenModels.Model(settings.QwenAsrModel), token);
            await ModelDownload.VerifyAsync(ModelDownload.PathFor(root, QwenModels.Projector(settings.QwenAsrModel)), QwenModels.Projector(settings.QwenAsrModel), token);
            try { await StartAsync(settings.UseGpu, token); }
            catch (Exception ex) when (settings.UseGpu && ex is not OperationCanceledException)
            { Dispose(); progress.Report("Qwen GPU 초기화 실패 · CPU로 다시 시작합니다."); await StartAsync(false, token); }
        }
        using var response = await http!.PostAsJsonAsync("v1/chat/completions", new
        {
            model = "local-asr", messages = new[] { new { role = "user", content = new object[]
            { new { type = "input_audio", input_audio = new { data = Convert.ToBase64String(wav), format = "wav" } } } } },
            temperature = 0, max_tokens = 4096, stream = false
        }, token);
        if (!response.IsSuccessStatusCode) throw new InvalidOperationException($"Qwen 전사 요청을 처리하지 못했습니다 (HTTP {(int)response.StatusCode}).");
        using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
        var choices = json.RootElement.GetProperty("choices");
        if (choices.GetArrayLength() == 0 || choices[0].GetProperty("finish_reason").GetString() != "stop") throw new InvalidDataException("Qwen 전사가 끝까지 완료되지 않았습니다.");
        string text = choices[0].GetProperty("message").GetProperty("content").GetString() ?? "";
        int marker = text.IndexOf("<asr_text>", StringComparison.Ordinal);
        if (marker >= 0) text = text[(marker + "<asr_text>".Length)..];
        text = text.Replace("<|im_end|>", "", StringComparison.Ordinal).Trim();
        return new(text, []);
    }
    private async Task StartAsync(bool gpu, CancellationToken token)
    {
        string executable = Path.Combine(QwenModels.RuntimeDirectory(root), "llama-server.exe");
        if (!File.Exists(executable)) throw new InvalidOperationException("Qwen 실행 환경이 없습니다. AI 설정에서 모델을 준비해 주세요.");
        progress.Report($"{Model} 로딩 중 · {(gpu ? "GPU" : "CPU")}");
        using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); int port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop();
        string apiKey = Convert.ToHexString(RandomNumberGenerator.GetBytes(24));
        var start = new ProcessStartInfo(executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (string argument in new[] { "-m", ModelDownload.PathFor(root, QwenModels.Model(settings.QwenAsrModel)), "--mmproj", ModelDownload.PathFor(root, QwenModels.Projector(settings.QwenAsrModel)),
            "--host", "127.0.0.1", "--port", port.ToString(), "--api-key", apiKey, "--no-webui", "--ctx-size", "8192", "--parallel", "1", "--gpu-layers", gpu ? "99" : "0" }) start.ArgumentList.Add(argument);
        if (!gpu) start.ArgumentList.Add("--no-mmproj-offload");
        start.Environment["PATH"] = Path.Combine(root, "Tools", "cuda12") + Path.PathSeparator + Path.Combine(LocalRuntime.OllamaDirectory(root), "lib", "ollama", "cuda_v12") + Path.PathSeparator + Environment.GetEnvironmentVariable("PATH");
        process = Process.Start(start) ?? throw new IOException("Qwen 실행에 실패했습니다.");
        process.OutputDataReceived += (_, _) => { }; process.ErrorDataReceived += (_, _) => { };
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
        http = new HttpClient(new HttpClientHandler { UseProxy = false, AllowAutoRedirect = false, UseCookies = false })
        { BaseAddress = new Uri($"http://127.0.0.1:{port}/"), Timeout = TimeSpan.FromMinutes(10) };
        http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        for (int i = 0; i < 240; i++)
        {
            token.ThrowIfCancellationRequested();
            if (process.HasExited) throw new IOException($"Qwen 프로세스가 종료됐습니다 (코드 {process.ExitCode}).");
            using var healthTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            healthTimeout.CancelAfter(TimeSpan.FromSeconds(2));
            try { using var health = await http.GetAsync("health", healthTimeout.Token); if (health.IsSuccessStatusCode) return; }
            catch (HttpRequestException) { }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { }
            await Task.Delay(500, token);
        }
        throw new TimeoutException("Qwen 모델 로딩 시간이 초과됐습니다.");
    }
    public void Dispose()
    {
        http?.Dispose(); http = null;
        if (process is not null)
        {
            try { if (!process.HasExited) { process.Kill(true); process.WaitForExit(2000); } } catch (InvalidOperationException) { }
            process.Dispose(); process = null;
        }
    }
}
