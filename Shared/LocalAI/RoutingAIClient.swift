import Foundation

nonisolated struct RoutingAIClient: OpenRouterServing, DetailedTranscriptionServing {
    private let cloud: any OpenRouterServing
    private let local: any OpenRouterServing

    init(cloud: any OpenRouterServing, local: any OpenRouterServing = AppleOnDeviceAIClient()) {
        self.cloud = cloud
        self.local = local
    }

    func models() async throws -> [OpenRouterModel] {
        try await cloud.models()
    }

    func validateKey(_ apiKey: String) async throws {
        try await cloud.validateKey(apiKey)
    }

    func transcribe(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?
    ) async throws -> AITextResponse {
        if LocalAIModel.speechLocale(modelID: model) != nil {
            return try await local.transcribe(audio: audio, format: format, model: model, apiKey: apiKey, language: language)
        }
        try rejectUnknownLocalModel(model)
        return try await cloud.transcribe(audio: audio, format: format, model: model, apiKey: apiKey, language: language)
    }

    func complete(
        system: String,
        user: String,
        model: String,
        apiKey: String,
        maxTokens: Int
    ) async throws -> AITextResponse {
        if model == LocalAIModel.summaryID {
            return try await local.complete(system: system, user: user, model: model, apiKey: apiKey, maxTokens: maxTokens)
        }
        try rejectUnknownLocalModel(model)
        return try await cloud.complete(system: system, user: user, model: model, apiKey: apiKey, maxTokens: maxTokens)
    }

    func transcribeDetailed(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?,
        prompt: String?
    ) async throws -> DetailedTranscriptionResult {
        guard !LocalAIModel.hasLocalPrefix(modelID: model) else {
            throw AIError(message: "온디바이스 전사는 화자별 타임스탬프를 지원하지 않아요. 이 기능은 OpenRouter 전사 모델을 선택해 주세요.")
        }
        guard let detailedCloud = cloud as? any DetailedTranscriptionServing else {
            throw AIError(message: "선택한 전사 클라이언트가 상세 전사를 지원하지 않아요.")
        }
        return try await detailedCloud.transcribeDetailed(
            audio: audio,
            format: format,
            model: model,
            apiKey: apiKey,
            language: language,
            prompt: prompt
        )
    }

    private func rejectUnknownLocalModel(_ model: String) throws {
        guard !LocalAIModel.hasLocalPrefix(modelID: model) else {
            throw AIError(message: "알 수 없는 온디바이스 AI 모델입니다. 로컬 모델 설정을 다시 확인해 주세요.")
        }
    }
}
