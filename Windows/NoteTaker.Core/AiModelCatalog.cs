using System.Globalization;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NoteTaker.Core;

public sealed record AiModel(string Id, string Name, int ContextLength, int? MaxCompletionTokens,
    List<string> InputModalities, List<string> OutputModalities, List<string> SupportedParameters,
    decimal? PromptPrice = null, decimal? CompletionPrice = null)
{
    [JsonIgnore] public bool SupportsSummary => ContextLength >= 8192 && InputModalities.Contains("text") && OutputModalities.Contains("text");
    [JsonIgnore] public bool SupportsTranscription => OutputModalities.Contains("transcription");
    [JsonIgnore] public string Label => Name + " · " + Id;
    [JsonIgnore] public string Detail => (ContextLength > 0 ? $"문맥 {ContextLength:N0} 토큰" : "문맥 정보 없음") +
        (MaxCompletionTokens > 0 ? $" · 최대 출력 {MaxCompletionTokens:N0} 토큰" : "") +
        (PromptPrice is { } input && CompletionPrice is { } output ? string.Create(CultureInfo.InvariantCulture, $" · 100만 토큰 입력 ${input * 1000000:0.####} / 출력 ${output * 1000000:0.####}") : "");
    public void Validate()
    {
        MeetingValidation.Utf8Text(Id, 256); MeetingValidation.Utf8Text(Name, 1024);
        MeetingValidation.Require(!Id.Any(char.IsWhiteSpace) && ContextLength is >= 0 and <= 16777216 && MaxCompletionTokens is null or >= 0 and <= 16777216 &&
            InputModalities is { Count: <= 16 } && OutputModalities is { Count: <= 16 } && SupportedParameters is { Count: <= 128 } &&
            (PromptPrice is null || PromptPrice >= 0 && PromptPrice <= decimal.MaxValue / 1000000) &&
            (CompletionPrice is null || CompletionPrice >= 0 && CompletionPrice <= decimal.MaxValue / 1000000));
        foreach (var value in InputModalities.Concat(OutputModalities).Concat(SupportedParameters)) MeetingValidation.Utf8Text(value, 128);
    }
    public static bool RequiresReasoningBudget(string id) => id == "z-ai/glm-5.3" || id.StartsWith("z-ai/glm-5.3-", StringComparison.Ordinal) || id.StartsWith("z-ai/glm-5.3:", StringComparison.Ordinal);
}

public sealed record AiModelCatalog(DateTimeOffset FetchedAt, List<AiModel> Models)
{
    public int SchemaVersion { get; init; } = 1;
    public void Validate()
    {
        MeetingValidation.Require(SchemaVersion == 1 && Models is { Count: > 0 and <= 10000 } && Models.Select(m => m?.Id).Distinct(StringComparer.Ordinal).Count() == Models.Count);
        foreach (var model in Models) { MeetingValidation.Require(model is not null); model!.Validate(); }
    }
}
public sealed class AiModelCatalogClient(HttpMessageHandler? handler = null) : IDisposable
{
    private readonly HttpClient http = new(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }) { BaseAddress = new("https://openrouter.ai/api/v1/"), Timeout = TimeSpan.FromSeconds(30) };
    public async Task<AiModelCatalog> FetchAsync(CancellationToken token)
    {
        // The default endpoint currently lists text models; STT has a separate modality query.
        var parts = await Task.WhenAll(ReadAsync("models", token), ReadAsync("models?output_modalities=transcription", token));
        var merged = parts.SelectMany(p => p).GroupBy(m => m.Id, StringComparer.Ordinal).Select(group =>
        {
            var first = group.First(); return first with { InputModalities = group.SelectMany(m => m.InputModalities).Distinct().ToList(), OutputModalities = group.SelectMany(m => m.OutputModalities).Distinct().ToList() };
        }).OrderBy(m => m.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
        var catalog = new AiModelCatalog(DateTimeOffset.UtcNow, merged); catalog.Validate(); return catalog;
    }
    private async Task<List<AiModel>> ReadAsync(string path, CancellationToken token)
    {
        using var response = await http.GetAsync(path, HttpCompletionOption.ResponseHeadersRead, token); response.EnsureSuccessStatusCode();
        await using var stream = await response.Content.ReadAsStreamAsync(token); using var buffer = new MemoryStream(); byte[] bytes = new byte[16384]; int read;
        while ((read = await stream.ReadAsync(bytes, token)) > 0) { if (buffer.Length + read > 16 * 1024 * 1024) throw new InvalidDataException("모델 목록이 너무 큽니다."); buffer.Write(bytes, 0, read); }
        using var json = JsonDocument.Parse(buffer.ToArray()); return Decode(json.RootElement);
    }
    public static List<AiModel> Decode(JsonElement root)
    {
        if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array || data.GetArrayLength() > 10000) throw new InvalidDataException("모델 목록 형식이 올바르지 않습니다.");
        string? Text(JsonElement value, string field) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(field, out var part) && part.ValueKind == JsonValueKind.String ? part.GetString() : null;
        int? Number(JsonElement value, string field) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(field, out var part) && part.ValueKind == JsonValueKind.Number && part.TryGetInt32(out int number) ? number : null;
        List<string> List(JsonElement value, string field) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(field, out var part) && part.ValueKind == JsonValueKind.Array ? part.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.String).Select(p => p.GetString()!).ToList() : [];
        decimal? Price(JsonElement value, string field) => decimal.TryParse(Text(value, field), NumberStyles.Float, CultureInfo.InvariantCulture, out decimal result) && result >= 0 ? result : null;
        var result = new List<AiModel>();
        foreach (var row in data.EnumerateArray())
        {
            string? id = Text(row, "id"), name = Text(row, "name"); if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(name)) continue;
            var architecture = row.TryGetProperty("architecture", out var arch) ? arch : default;
            var provider = row.TryGetProperty("top_provider", out var top) ? top : default;
            var pricing = row.TryGetProperty("pricing", out var prices) ? prices : default;
            var model = new AiModel(id, name, Number(row, "context_length") ?? 0, Number(provider, "max_completion_tokens"), List(architecture, "input_modalities"), List(architecture, "output_modalities"), List(row, "supported_parameters"), Price(pricing, "prompt"), Price(pricing, "completion"));
            model.Validate(); result.Add(model);
        }
        return result;
    }
    public void Dispose() => http.Dispose();
}
public sealed class AiModelCatalogStore(string root)
{
    private readonly string path = Path.Combine(root, "model-catalog-local.json");
    public AiModelCatalog? Load()
    {
        if (!File.Exists(path)) return null;
        if (new FileInfo(path).Length > 8 * 1024 * 1024) throw new InvalidDataException("저장된 모델 목록이 너무 큽니다.");
        var catalog = JsonDisk.Read<AiModelCatalog>(path) ?? throw new InvalidDataException("모델 목록이 비어 있습니다."); catalog.Validate(); return catalog;
    }
    public void Save(AiModelCatalog catalog)
    {
        catalog.Validate();
        if (JsonSerializer.SerializeToUtf8Bytes(catalog, JsonDisk.Options).Length > 8 * 1024 * 1024) throw new InvalidDataException("모델 목록이 저장 범위를 초과했습니다.");
        JsonDisk.Write(path, catalog);
    }
}
