import Foundation

/// Reasoning and the visible report share the provider's completion allowance.
nonisolated struct MeetingCompletionBudget: Equatable {
    let inputBytes: Int
    let outputTokens: Int
    let partialOutputTokens: Int

    init(model: OpenRouterModel?, modelID: String = "", fallbackContext: Int = 8_192) {
        let context = model.map(\.contextLength).flatMap { $0 > 0 ? $0 : nil } ?? max(1, fallbackContext)
        let providerLimit = model?.maxCompletionTokens.flatMap { $0 > 0 ? $0 : nil } ?? Int.max
        let reasoningFloor = OpenRouterModel.requiresReasoningBudget(for: model?.id ?? modelID)
            ? min(4_096, context / 2) : 1
        outputTokens = max(1, min(131_072, max(reasoningFloor, context / 4), providerLimit))
        partialOutputTokens = min(32_768, outputTokens)
        // Count transcript UTF-8 bytes conservatively and leave space for prompts.
        let promptReserve = min(2_048, context / 4)
        inputBytes = max(1, min(96_000, context - outputTokens - promptReserve))
    }

    static func requestTimeout(outputTokens: Int) -> TimeInterval {
        max(180, min(3_600, Double(outputTokens) / 32))
    }

    static let resourceTimeout: TimeInterval = 3_660
}
