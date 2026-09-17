using System.Text.Json;
using NoteTaker.Core;
using Xunit;

namespace NoteTaker.Tests;

public sealed class ModelCatalogTests
{
    private static AiModel TextModel(string id = "fixture/model", int context = 32768, int? output = 2000) => new(id, "모델", context, output, ["text"], ["text"], ["reasoning"], .000001m, .000002m);
    [Fact] public async Task CatalogMergesAnonymousTextAndTranscriptionEndpointsAndRetainsNullLimits()
    {
        var paths = new List<string>(); using var client = new AiModelCatalogClient(new StubHandler((request, _) =>
        {
            Assert.Null(request.Headers.Authorization); lock (paths) paths.Add(request.RequestUri!.PathAndQuery);
            return Task.FromResult(StubHandler.Json(request.RequestUri!.Query.Length == 0
                ? """{"data":[{"id":"fixture/model","name":"text","context_length":32768,"top_provider":{"max_completion_tokens":2000},"architecture":{"input_modalities":["text"],"output_modalities":["text"]},"pricing":{"prompt":"0.000001","completion":"0.000002"}}]}"""
                : """{"data":[{"id":"fixture/stt","name":"speech","context_length":null,"top_provider":{"max_completion_tokens":null},"architecture":{"input_modalities":["audio"],"output_modalities":["transcription"]}},{"id":"fixture/model","name":"text","context_length":32768,"architecture":{"input_modalities":["text","audio"],"output_modalities":["text"]}}]}"""));
        }));
        var catalog = await client.FetchAsync(default);
        Assert.Equal(2, catalog.Models.Count); Assert.Contains("/api/v1/models?output_modalities=transcription", paths);
        var text = catalog.Models.Single(m => m.SupportsSummary); Assert.Contains("audio", text.InputModalities); Assert.Equal(2000, text.MaxCompletionTokens); Assert.Contains("입력 $1", text.Detail);
        var speech = catalog.Models.Single(m => m.SupportsTranscription); Assert.False(speech.SupportsSummary); Assert.Null(speech.MaxCompletionTokens);
        using var folder = new TestFolder(); var store = new AiModelCatalogStore(folder.Root); store.Save(catalog);
        Assert.Equal(2, store.Load()!.Models.Count);
        Assert.Throws<InvalidDataException>(() => store.Save(catalog with { Models = [text, text] })); Assert.Equal(2, store.Load()!.Models.Count);
        Assert.Throws<InvalidDataException>(() => (text with { PromptPrice = decimal.MaxValue }).Validate());
    }
    [Fact] public void BudgetHonorsProviderLimitAndReasoningFloorWithoutReusingAnotherModelsMetadata()
    {
        Assert.Equal(new CompletionBudget(28720, 2000, 2000), CompletionBudget.ForModel(TextModel(), "fixture/model"));
        Assert.Equal(new CompletionBudget(4096, 2048, 2048), CompletionBudget.ForModel(TextModel(), "unknown"));
        var forced = TextModel("z-ai/glm-5.3", 8192, null); Assert.Equal(4096, CompletionBudget.ForModel(forced, forced.Id).OutputTokens);
        Assert.Equal(2000, CompletionBudget.ForModel(forced with { MaxCompletionTokens = 2000 }, forced.Id).OutputTokens);
        Assert.True(AiModel.RequiresReasoningBudget("z-ai/glm-5.3:free")); Assert.False(AiModel.RequiresReasoningBudget("z-ai/glm-5.30"));
        Assert.Equal(180, CompletionBudget.TimeoutFor(2000).TotalSeconds); Assert.Equal(3600, CompletionBudget.TimeoutFor(131072).TotalSeconds);
    }
    [Fact] public async Task CloudRequestSendsChosenOutputBudgetAndKnownReasoningOptions()
    {
        using var client = new OpenRouterClient(new StubHandler(async (request, token) =>
        {
            using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(token)); var body = json.RootElement;
            Assert.Equal(1000, body.GetProperty("max_tokens").GetInt32()); Assert.Equal("low", body.GetProperty("reasoning").GetProperty("effort").GetString());
            Assert.True(body.GetProperty("reasoning").GetProperty("exclude").GetBoolean());
            return StubHandler.Json("""{"choices":[{"finish_reason":"stop","message":{"content":"# 결과"}}]}""");
        }));
        await client.CompleteAsync("system", "text", new AppSettings { SummaryModel = "z-ai/glm-5.3", SummaryModelInfo = TextModel("z-ai/glm-5.3", 8192, 2000) }, "fixture-key", default, 1000);
    }
    [Fact] public void EnhancementSelectionInheritsOnlyWhenEmpty()
    {
        var settings = new AppSettings { SummaryModel = "summary", SummaryModelInfo = TextModel("summary"), EnhancementModel = "revise", EnhancementModelInfo = TextModel("revise"), LocalEnhancementModel = "qwen3.5:9b" };
        var selected = AiProviders.EnhancementSettings(settings); Assert.Equal("revise", selected.SummaryModel); Assert.Equal("revise", selected.SummaryModelInfo!.Id); Assert.Equal("qwen3.5:9b", selected.LocalSummaryModel);
        var inherited = AiProviders.EnhancementSettings(settings with { EnhancementModel = "", LocalEnhancementModel = "" }); Assert.Equal("summary", inherited.SummaryModel); Assert.Equal(settings.LocalSummaryModel, inherited.LocalSummaryModel);
    }
}
