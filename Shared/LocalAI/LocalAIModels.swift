import Foundation

nonisolated enum LocalAIProcessingMode: String, CaseIterable, Codable, Sendable {
    case openRouter
    case onDevice
}

nonisolated struct LocalAIStatus: Equatable, Sendable {
    let isAvailable: Bool
    let message: String

    init(isAvailable: Bool, message: String) {
        self.isAvailable = isAvailable
        self.message = message
    }
}

nonisolated enum LocalAIModel {
    static let summaryID = "apple/on-device-summary"
    static let supportedSpeechLocales = ["ko-KR", "en-US"]
    private static let speechPrefix = "apple/on-device-speech/"

    static func transcriptionID(localeIdentifier: String) -> String? {
        guard supportedSpeechLocales.contains(localeIdentifier) else { return nil }
        return speechPrefix + localeIdentifier
    }

    static func isLocal(modelID: String) -> Bool {
        modelID == summaryID || speechLocale(modelID: modelID) != nil
    }

    static func hasLocalPrefix(modelID: String) -> Bool {
        modelID == summaryID || modelID.hasPrefix("apple/on-device-")
    }

    static func speechLocale(modelID: String) -> String? {
        guard modelID.hasPrefix(speechPrefix) else { return nil }
        let locale = String(modelID.dropFirst(speechPrefix.count))
        return supportedSpeechLocales.contains(locale) ? locale : nil
    }

    static var summaryDescriptor: OpenRouterModel {
        OpenRouterModel(
            id: summaryID,
            name: "Apple On-Device Summary",
            contextLength: 4_096,
            inputModalities: ["text"],
            outputModalities: ["text"],
            promptPrice: "0",
            completionPrice: "0",
            maxCompletionTokens: 1_024
        )
    }

    static var speechDescriptors: [OpenRouterModel] {
        supportedSpeechLocales.map { locale in
            OpenRouterModel(
                id: speechPrefix + locale,
                name: "Apple On-Device Speech (\(locale))",
                contextLength: 0,
                inputModalities: ["audio"],
                outputModalities: ["transcription"],
                promptPrice: "0",
                completionPrice: "0",
                maxCompletionTokens: nil
            )
        }
    }
}
