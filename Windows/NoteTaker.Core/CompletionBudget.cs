namespace NoteTaker.Core;

public sealed record CompletionBudget(int InputBytes, int OutputTokens, int PartialOutputTokens)
{
    public static CompletionBudget ForModel(AiModel? model, string modelId, int fallbackContext = 8192)
    {
        if (model?.Id != modelId) model = null;
        model?.Validate(); int context = model?.ContextLength > 0 ? model.ContextLength : Math.Max(1, fallbackContext);
        int provider = model?.MaxCompletionTokens > 0 ? model.MaxCompletionTokens.Value : int.MaxValue;
        int reasoningFloor = AiModel.RequiresReasoningBudget(modelId) ? Math.Min(4096, context / 2) : 1;
        int output = Math.Max(1, Math.Min(131072, Math.Min(Math.Max(reasoningFloor, context / 4), provider)));
        int input = Math.Max(1, Math.Min(96000, context - output - Math.Min(2048, context / 4)));
        return new(input, output, Math.Min(32768, output));
    }
    public static CompletionBudget Local { get; } = new(10240, 4096, 4096); // 16K context, 4K response, 2K prompt reserve.
    public static TimeSpan TimeoutFor(int outputTokens) => TimeSpan.FromSeconds(Math.Clamp(outputTokens / 32d, 180, 3600));
}
