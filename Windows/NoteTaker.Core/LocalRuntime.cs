using System.Diagnostics;
using System.IO.Compression;

namespace NoteTaker.Core;

public static class LocalRuntime
{
    public static readonly ModelAsset CudaZip = new("cudart-llama-b10809-win-cuda-12.4-x64.zip",
        "https://github.com/ggml-org/llama.cpp/releases/download/b10809/cudart-llama-bin-win-cuda-12.4-x64.zip", 391443627,
        "8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6");
    public static readonly ModelAsset OllamaZip = new("ollama-windows-amd64-v0.34.0.zip",
        "https://github.com/ollama/ollama/releases/download/v0.34.0/ollama-windows-amd64.zip", 1469375054,
        "a7dd1b174f39d3d1b8a25d4cbc86045d0e190b17187bfdcbe2f2ee3b5a11470e");
    private static Process? ownedOllama;
    private static bool cudaLoaded;
    public static void LoadCudaDependencies(string root)
    {
        if (cudaLoaded) return;
        var folders = new[] { Path.Combine(root, "Tools", "cuda12"), Path.Combine(OllamaDirectory(root), "lib", "ollama", "cuda_v12") };
        foreach (string folder in folders)
        {
            foreach (var name in new[] { "cublasLt64_12.dll", "cublas64_12.dll", "cudart64_12.dll" })
            {
                string path = Path.Combine(folder, name);
                if (File.Exists(path)) System.Runtime.InteropServices.NativeLibrary.TryLoad(path, out _);
            }
        }
        cudaLoaded = true;
    }
    public static async Task PrepareCudaAsync(string root, IProgress<string> progress, CancellationToken token)
    {
        if (File.Exists(Path.Combine(OllamaDirectory(root), "lib", "ollama", "cuda_v12", "cublas64_12.dll"))) return;
        string folder = Path.Combine(root, "Tools", "cuda12");
        if (File.Exists(Path.Combine(folder, "ready.txt"))) return;
        string zip = await ModelDownload.EnsureAsync(root, CudaZip, progress, token);
        await Task.Run(() => ZipFile.ExtractToDirectory(zip, folder, true), token);
        token.ThrowIfCancellationRequested(); File.WriteAllText(Path.Combine(folder, "ready.txt"), CudaZip.Sha256);
    }
    public static string OllamaDirectory(string root) => Path.Combine(root, "Tools", "ollama-0.34.0");
    public static async Task PrepareOllamaAsync(string root, AppSettings settings, IProgress<string> progress, CancellationToken token)
    {
        if (!await IsOllamaRunningAsync(settings, token))
        {
            if (!File.Exists(Path.Combine(OllamaDirectory(root), "ready.txt")))
            {
                progress.Report("Ollama 실행 환경 다운로드 · 약 1.47 GB");
                string zip = await ModelDownload.EnsureAsync(root, OllamaZip, progress, token);
                progress.Report("Ollama 실행 환경 압축 해제 중…");
                await Task.Run(() => ZipFile.ExtractToDirectory(zip, OllamaDirectory(root), true), token);
                token.ThrowIfCancellationRequested();
                File.WriteAllText(Path.Combine(OllamaDirectory(root), "ready.txt"), OllamaZip.Sha256);
            }
            await StartOllamaAsync(root, settings, token);
        }
        using var client = new OllamaSummarizer(settings);
        await client.PrepareAsync(progress, token);
    }
    public static async Task StartOllamaAsync(string root, AppSettings settings, CancellationToken token)
    {
        if (await IsOllamaRunningAsync(settings, token)) return;
        if (ownedOllama is { HasExited: false }) throw new InvalidOperationException("기존 로컬 모델 작업을 종료한 뒤 Ollama 주소를 변경해 주세요.");
        string executable = Path.Combine(OllamaDirectory(root), "ollama.exe");
        if (!File.Exists(executable) || !File.Exists(Path.Combine(OllamaDirectory(root), "ready.txt")))
            throw new InvalidOperationException("Ollama가 실행되지 않았습니다. AI 설정에서 무료 모델 준비를 실행해 주세요.");
        var address = OllamaSummarizer.LocalAddress(settings.OllamaAddress);
        var start = new ProcessStartInfo(executable, "serve") { UseShellExecute = false, CreateNoWindow = true };
        start.Environment["OLLAMA_HOST"] = address.GetLeftPart(UriPartial.Authority);
        start.Environment["OLLAMA_MODELS"] = Path.Combine(root, "Models", "Ollama");
        start.Environment["OLLAMA_NO_CLOUD"] = "1";
        ownedOllama = Process.Start(start) ?? throw new IOException("Ollama를 시작하지 못했습니다.");
        for (int i = 0; i < 60; i++)
        {
            if (ownedOllama.HasExited) throw new IOException("Ollama가 종료됐습니다. GPU 드라이버와 설치 상태를 확인해 주세요.");
            if (await IsOllamaRunningAsync(settings, token)) return;
            await Task.Delay(250, token);
        }
        throw new TimeoutException("Ollama 시작 시간이 초과됐습니다.");
    }
    public static async Task<bool> IsOllamaRunningAsync(AppSettings settings, CancellationToken token)
    {
        using var http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false, UseProxy = false }) { BaseAddress = OllamaSummarizer.LocalAddress(settings.OllamaAddress), Timeout = TimeSpan.FromSeconds(2) };
        try
        {
            using var response = await http.GetAsync("api/version", token);
            if (!response.IsSuccessStatusCode) return false;
            using var json = System.Text.Json.JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            return json.RootElement.TryGetProperty("version", out var version) && !string.IsNullOrWhiteSpace(version.GetString());
        }
        catch (Exception ex) when (ex is HttpRequestException or System.Text.Json.JsonException || ex is TaskCanceledException && !token.IsCancellationRequested) { return false; }
    }
    public static void StopOwned()
    {
        if (ownedOllama is not null)
        {
            try { if (!ownedOllama.HasExited) ownedOllama.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { }
            ownedOllama.Dispose(); ownedOllama = null;
        }
    }
}
