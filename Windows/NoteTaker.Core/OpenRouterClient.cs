using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace NoteTaker.Core;

public sealed record AiText(string Text, decimal? CostUsd);

public sealed class OpenRouterClient : IDisposable
{
    private readonly HttpClient http;
    public OpenRouterClient(HttpMessageHandler? handler = null)
    {
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false })
        { BaseAddress = new Uri("https://openrouter.ai/api/v1/"), Timeout = TimeSpan.FromMinutes(10) };
    }

    public async Task<AiText> TranscribeAsync(byte[] wav, AppSettings settings, string key, CancellationToken token)
    {
        var body = new Dictionary<string, object>
        {
            ["model"] = settings.TranscriptionModel,
            ["input_audio"] = new { data = Convert.ToBase64String(wav), format = "wav" }
        };
        // Output language applies to the report; preserve the language actually spoken in STT.
        using var json = await SendAsync("audio/transcriptions", body, key, token);
        var text = json.RootElement.TryGetProperty("text", out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()! : throw new InvalidDataException("전사 응답 형식이 올바르지 않습니다.");
        return new AiText(text.Trim(), ReadCost(json.RootElement));
    }

    public async Task<AiText> CompleteAsync(string system, string content, AppSettings settings, string key, CancellationToken token)
    {
        using var json = await SendAsync("chat/completions", new
        {
            model = settings.SummaryModel,
            messages = new[] { new { role = "system", content = system }, new { role = "user", content } },
            max_tokens = 8192, stream = false
        }, key, token);
        var root = json.RootElement;
        if (!root.TryGetProperty("choices", out var choices) || choices.ValueKind != JsonValueKind.Array || choices.GetArrayLength() == 0)
            throw new InvalidDataException("모델이 회의록을 반환하지 않았습니다.");
        var choice = choices[0];
        var reason = choice.TryGetProperty("finish_reason", out var finish) ? finish.GetString() : null;
        if (reason is "length" or "error" or "content_filter" || choice.TryGetProperty("error", out _))
            throw new InvalidOperationException("모델이 회의록을 끝까지 생성하지 못했습니다. 기존 회의록은 유지됩니다. 모델을 변경하거나 다시 시도해 주세요.");
        if (!choice.TryGetProperty("message", out var message) ||
            (message.TryGetProperty("refusal", out var refusal) && refusal.ValueKind == JsonValueKind.String && !string.IsNullOrEmpty(refusal.GetString())) ||
            !message.TryGetProperty("content", out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
            throw new InvalidDataException("모델의 최종 회의록 응답이 비어 있습니다.");
        return new AiText(value.GetString()!.Trim(), ReadCost(root));
    }

    public async Task<TranscribedAudio> TranscribeDetailedAsync(byte[] wav, AppSettings settings, string key, CancellationToken token)
    {
        var body = new Dictionary<string, object>
        {
            ["model"] = settings.TranscriptionModel, ["input_audio"] = new { data = Convert.ToBase64String(wav), format = "wav" },
            ["response_format"] = "verbose_json", ["timestamp_granularities"] = new[] { "segment", "word" }
        };
        if (settings.SpeechLanguage != "auto") body["language"] = settings.SpeechLanguage;
        using var json = await SendAsync("audio/transcriptions", body, key, token, detailedTranscription: true);
        return DecodeDetailed(json.RootElement);
    }
    public static TranscribedAudio DecodeDetailed(JsonElement root)
    {
        if (!root.TryGetProperty("text", out var textElement) || textElement.ValueKind != JsonValueKind.String) throw new InvalidDataException("상세 전사에 원문이 없습니다.");
        string text = textElement.GetString()!; var words = new List<TranscriptWord>(); var segments = new List<TranscriptSegment>();
        double ReadNumber(JsonElement item, string property) => item.TryGetProperty(property, out var number) && number.ValueKind == JsonValueKind.Number && number.TryGetDouble(out double value) && double.IsFinite(value) ? value : throw new InvalidDataException("상세 전사의 시간 형식이 올바르지 않습니다.");
        if (root.TryGetProperty("words", out var array) && array.ValueKind == JsonValueKind.Array)
        {
            if (array.GetArrayLength() > 100000) throw new InvalidDataException("상세 전사 결과가 너무 큽니다.");
            foreach (var item in array.EnumerateArray())
            {
                var value = item.TryGetProperty("word", out var word) ? word : item.TryGetProperty("text", out var wordText) ? wordText : default;
                if (value.ValueKind != JsonValueKind.String) throw new InvalidDataException("단어 전사 내용이 올바르지 않습니다.");
                words.Add(new(ReadNumber(item, "start"), ReadNumber(item, "end"), value.GetString()!));
            }
        }
        TranscriptTiming.ValidateWords(words, 120);
        if (root.TryGetProperty("segments", out array) && array.ValueKind == JsonValueKind.Array)
        {
            if (array.GetArrayLength() > 20000) throw new InvalidDataException("상세 전사 결과가 너무 큽니다.");
            foreach (var item in array.EnumerateArray())
            {
                if (!item.TryGetProperty("text", out var value) || value.ValueKind != JsonValueKind.String) throw new InvalidDataException("상세 전사 내용이 올바르지 않습니다.");
                double start = ReadNumber(item, "start"), end = ReadNumber(item, "end"); string part = value.GetString()!;
                if (!string.IsNullOrWhiteSpace(part)) segments.Add(new(start, end, part) { Words = TranscriptTiming.AttachText(part, words.Where(w => w.StartSeconds >= start && w.StartSeconds < end).ToList()) });
            }
        }
        if (segments.Count == 0 && words.Count > 0)
        {
            var attached = TranscriptTiming.AttachText(text, words);
            if (attached.Count == 0) throw new TranscriptionTimingException();
            segments.Add(new(words.Min(w => w.StartSeconds), words.Max(w => w.EndSeconds), text) { Words = attached });
        }
        if (segments.Count == 0 && !string.IsNullOrWhiteSpace(text)) throw new TranscriptionTimingException();
        var result = new TranscribedAudio(text, segments); TranscriptTiming.Validate(result, 120); return result;
    }

    private async Task<JsonDocument> SendAsync(string path, object body, string key, CancellationToken token, bool detailedTranscription = false)
    {
        if (string.IsNullOrWhiteSpace(key)) throw new InvalidOperationException("설정에서 OpenRouter API 키를 저장해 주세요.");
        using var request = new HttpRequestMessage(HttpMethod.Post, path);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", key.Trim());
        request.Headers.Add("X-Title", "AI-NoteTaker Windows");
        request.Content = JsonContent.Create(body);
        try
        {
            using var response = await http.SendAsync(request, token);
            if (!response.IsSuccessStatusCode)
            {
                var error = StatusError(response.StatusCode);
                if (detailedTranscription && response.StatusCode == HttpStatusCode.BadRequest) throw new OpenRouterRequestException(response.StatusCode, error.Message);
                throw error;
            }
            var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            if (json.RootElement.TryGetProperty("error", out _))
            {
                json.Dispose();
                throw new InvalidOperationException("모델 제공자가 요청을 완료하지 못했습니다. 잠시 후 다시 시도해 주세요.");
            }
            return json;
        }
        catch (TaskCanceledException) when (!token.IsCancellationRequested)
        { throw new TimeoutException("AI 응답 대기 시간이 초과됐습니다. 완료된 전사는 저장되어 있습니다."); }
        catch (HttpRequestException)
        { throw new InvalidOperationException("OpenRouter 연결에 실패했습니다. 인터넷 연결을 확인해 주세요."); }
        catch (JsonException)
        { throw new InvalidDataException("OpenRouter 응답을 해석할 수 없습니다."); }
    }
    private static Exception StatusError(HttpStatusCode status) => new InvalidOperationException(status switch
    {
        HttpStatusCode.Unauthorized => "OpenRouter API 키가 유효하지 않습니다. 설정에서 다시 저장해 주세요.",
        HttpStatusCode.PaymentRequired => "OpenRouter 크레딧이 부족합니다.",
        HttpStatusCode.TooManyRequests => "요청 한도에 도달했습니다. 잠시 후 다시 시도해 주세요.",
        _ when (int)status is >= 300 and < 400 => "OpenRouter 리디렉션 요청은 따르지 않았습니다.",
        _ => $"OpenRouter 요청이 실패했습니다 (HTTP {(int)status}). 모델 설정과 서비스 상태를 확인해 주세요."
    });
    private static decimal? ReadCost(JsonElement root) => root.TryGetProperty("usage", out var usage) &&
        usage.TryGetProperty("cost", out var cost) && cost.ValueKind == JsonValueKind.Number && cost.TryGetDecimal(out var number) ? number : null;
    public void Dispose() => http.Dispose();
}

public sealed class OpenRouterRequestException(HttpStatusCode status, string message) : InvalidOperationException(message)
{ public HttpStatusCode Status { get; } = status; }
public sealed class TranscriptionTimingException() : InvalidOperationException("선택한 전사 모델이 시간 정보를 반환하지 않았습니다.");
