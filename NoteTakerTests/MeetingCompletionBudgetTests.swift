import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Meeting completion allowance")
struct MeetingCompletionBudgetTests {
    @Test("larger output preserves input and prompt space for every supported context",
          arguments: [8_192, 16_384, 32_768, 128_000, 1_000_000])
    func contextSpaceIsPreserved(context: Int) {
        let model = OpenRouterModel(id: "fixture", name: "Fixture", contextLength: context,
            inputModalities: ["text"], outputModalities: ["text"])
        let budget = MeetingCompletionBudget(model: model)
        #expect(budget.outputTokens + budget.inputBytes + 2_048 <= context)
        #expect(budget.partialOutputTokens <= budget.outputTokens)
        #expect(budget.partialOutputTokens <= 32_768)
        #expect(budget.inputBytes > 0)
    }

    @Test("old cached model records still decode and unknown contexts remain conservative")
    func olderCatalogRemainsReadable() throws {
        let old = try JSONDecoder().decode(OpenRouterModel.self, from: Data(#"{"id":"old","name":"Old","contextLength":1000000,"inputModalities":["text"],"outputModalities":["text"]}"#.utf8))
        #expect(old.maxCompletionTokens == nil)
        #expect(MeetingCompletionBudget(model: old).outputTokens == 131_072)
        #expect(MeetingCompletionBudget(model: nil).outputTokens == 2_048)
        #expect(MeetingCompletionBudget(model: nil, modelID: "z-ai/glm-5.3").outputTokens == 4_096)
        #expect(MeetingCompletionBudget(model: nil, fallbackContext: 32_000).outputTokens == 8_000)
    }

    @Test("invalid optional provider metadata never creates an invalid token request", arguments: [0, -1])
    func invalidProviderLimitIsIgnored(limit: Int) {
        let model = OpenRouterModel(id: "fixture", name: "Fixture", contextLength: 8_192,
            inputModalities: ["text"], outputModalities: ["text"], maxCompletionTokens: limit)
        #expect(MeetingCompletionBudget(model: model).outputTokens == 2_048)
    }
}
