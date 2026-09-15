using System.Net.Http.Json;
using System.Text.Json;
using Whisper.net;

namespace NoteTaker.Core;

public sealed record TranscribedAudio(string Text, IReadOnlyList<TranscriptSegment> Segments);
public interface ITranscriber : IDisposable
{
    string Provider { get; }
    string Model { get; }
    string Fingerprint { get; }
    int ChunkSeconds { get; }
    Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token);
}
public interface ISummarizer : IDisposable
{
    string Model { get; }
    int MaximumInputBytes { get; }
    Task<AiText> CompleteAsync(string system, string text, CancellationToken token);
}

public sealed class CloudTranscriber(OpenRouterClient client, AppSettings settings, string key, bool ownsClient = false) : ITranscriber
{
    public string Provider => "openrouter";
    public string Model => settings.TranscriptionModel;
    public string Fingerprint => $"openrouter/{Model}/auto/pcm16k-v1/chunk120";
    public int ChunkSeconds => 120;
    public async Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token) => new((await client.TranscribeAsync(wav, settings, key, token)).Text, []);
    public void Dispose() { if (ownsClient) client.Dispose(); }
}
public sealed class CloudSummarizer(OpenRouterClient client, AppSettings settings, string key, bool ownsClient = false) : ISummarizer
{
    public string Model => settings.SummaryModel;
    public int MaximumInputBytes => 48000;
    public Task<AiText> CompleteAsync(string system, string text, CancellationToken token) => client.CompleteAsync(system, text, settings, key, token);
    public void Dispose() { if (ownsClient) client.Dispose(); }
}

public sealed class WhisperTranscriber(string root, AppSettings settings, IProgress<string> progress) : ITranscriber
{
    private WhisperFactory? factory;
    public string Provider => "whisper";
    public string Model => "large-v3-turbo";
    public string Fingerprint => $"whisper.net-1.9.1/{Model}/{ModelDownload.WhisperTurbo.Sha256}/{settings.SpeechLanguage}/pcm16k-v1/chunk120/temp0";
    public int ChunkSeconds => 120;
    public Task<TranscribedAudio> TranscribeAsync(byte[] wav, CancellationToken token) => Task.Run(async () =>
    {
        token.ThrowIfCancellationRequested();
        if (AudioFiles.IsDigitalSilence(wav)) return new TranscribedAudio("", []);
        if (factory is null)
        {
            string path = ModelDownload.PathFor(root, ModelDownload.WhisperTurbo);
            progress.Report("Whisper 모델 확인 중…"); await ModelDownload.VerifyAsync(path, ModelDownload.WhisperTurbo, token);
            progress.Report("Whisper 모델 로딩 중…");
            if (settings.UseGpu) LocalRuntime.LoadCudaDependencies(root);
            try { factory = WhisperFactory.FromPath(path, new() { UseGpu = settings.UseGpu }); }
            catch (Exception ex) when (settings.UseGpu && ex is not OperationCanceledException)
            {
                progress.Report("GPU 초기화 실패 · CPU로 전사합니다.");
                factory = WhisperFactory.FromPath(path, new() { UseGpu = false });
            }
            progress.Report($"Whisper 실행 엔진 · {Whisper.net.LibraryLoader.RuntimeOptions.LoadedLibrary}");
        }
        using var processor = factory.CreateBuilder().WithLanguage(settings.SpeechLanguage)
            .WithThreads(Math.Clamp(Environment.ProcessorCount / 2, 2, 8)).WithTemperature(0).WithNoSpeechThreshold(.6f).Build();
        using var stream = new MemoryStream(wav, writable: false);
        var segments = new List<TranscriptSegment>();
        await foreach (var segment in processor.ProcessAsync(stream, token))
        {
            if (!string.IsNullOrWhiteSpace(segment.Text)) segments.Add(new(segment.Start.TotalSeconds, segment.End.TotalSeconds, segment.Text.Trim()));
        }
        return new TranscribedAudio(string.Join(" ", segments.Select(x => x.Text)), segments);
    }, token);
    public void Dispose() { factory?.Dispose(); factory = null; }
}

public sealed class OllamaSummarizer : ISummarizer
{
    private readonly HttpClient http;
    public string Model { get; }
    public int MaximumInputBytes => 16000;
    public OllamaSummarizer(AppSettings settings, HttpMessageHandler? handler = null)
    {
        Model = settings.LocalSummaryModel;
        if (Model is not ("qwen3.5:4b" or "qwen3.5:9b")) throw new InvalidOperationException("지원하는 로컬 요약 모델을 선택해 주세요.");
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseProxy = false })
        { BaseAddress = LocalAddress(settings.OllamaAddress), Timeout = TimeSpan.FromMinutes(15) };
    }
    public static Uri LocalAddress(string address)
    {
        if (!Uri.TryCreate(address.TrimEnd('/') + "/", UriKind.Absolute, out var uri) || uri.Scheme != "http" || !uri.IsLoopback ||
            !string.IsNullOrEmpty(uri.UserInfo) || uri.AbsolutePath != "/" || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new InvalidOperationException("Ollama 주소는 이 PC의 http://127.0.0.1:포트 형식이어야 합니다.");
        return uri;
    }
    public async Task<AiText> CompleteAsync(string system, string text, CancellationToken token)
    {
        try
        {
            using var response = await http.PostAsJsonAsync("api/chat", new
            {
                model = Model, messages = new[] { new { role = "system", content = system }, new { role = "user", content = text } },
                stream = false, think = false, keep_alive = 0, options = new { num_ctx = 8192, num_predict = 4096, temperature = .1 }
            }, token);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound) throw new InvalidOperationException("로컬 요약 모델이 없습니다. AI 설정에서 모델을 준비해 주세요.");
            response.EnsureSuccessStatusCode();
            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            var data = json.RootElement;
            if (!data.TryGetProperty("done", out var done) || !done.GetBoolean() || data.TryGetProperty("error", out _) ||
                (data.TryGetProperty("done_reason", out var reason) && reason.GetString() == "length"))
                throw new InvalidDataException("로컬 모델이 회의록을 끝까지 생성하지 못했습니다. 기존 회의록은 보존됩니다.");
            if (!data.TryGetProperty("message", out var message) || !message.TryGetProperty("content", out var content) || string.IsNullOrWhiteSpace(content.GetString()))
                throw new InvalidDataException("로컬 모델의 회의록 응답이 비어 있습니다.");
            return new(content.GetString()!.Trim(), 0);
        }
        catch (HttpRequestException) { throw new InvalidOperationException("Ollama에 연결할 수 없습니다. AI 설정에서 실행 상태와 주소를 확인해 주세요."); }
    }
    public async Task PrepareAsync(IProgress<string> progress, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "api/pull") { Content = JsonContent.Create(new { model = Model, stream = true }) };
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token); response.EnsureSuccessStatusCode();
        using var reader = new StreamReader(await response.Content.ReadAsStreamAsync(token));
        bool success = false;
        while (await reader.ReadLineAsync(token) is { } line)
        {
            if (string.IsNullOrWhiteSpace(line)) continue;
            using var json = JsonDocument.Parse(line); var data = json.RootElement;
            if (data.TryGetProperty("error", out _)) throw new InvalidOperationException("Ollama 모델 다운로드에 실패했습니다. 연결 상태를 확인하고 다시 시도해 주세요.");
            var status = data.TryGetProperty("status", out var value) ? value.GetString() : "";
            success |= status == "success";
            string detail = data.TryGetProperty("total", out var total) && total.GetInt64() > 0 && data.TryGetProperty("completed", out var completed)
                ? $"{completed.GetInt64() * 100 / total.GetInt64()}%" : status ?? "";
            progress.Report($"{Model} 준비 중 · {detail}");
        }
        if (!success) throw new IOException("모델 다운로드가 중단되었습니다. 다시 실행하면 이어받습니다.");
    }
    public void Dispose() => http.Dispose();
}

public static class AiProviders
{
    public static ITranscriber Transcriber(string root, AppSettings settings, string key, IProgress<string> progress) => settings.TranscriptionProvider switch
    {
        "whisper" => new WhisperTranscriber(root, settings, progress),
        "qwen" => new QwenTranscriber(root, settings, progress),
        "openrouter" => new CloudTranscriber(new(), settings, key, true),
        _ => throw new InvalidOperationException("지원하지 않는 전사 엔진입니다.")
    };
    public static ISummarizer Summarizer(AppSettings settings, string key) => settings.SummaryProvider switch
    {
        "ollama" => new OllamaSummarizer(settings), "openrouter" => new CloudSummarizer(new(), settings, key, true),
        _ => throw new InvalidOperationException("지원하지 않는 회의록 엔진입니다.")
    };
}
