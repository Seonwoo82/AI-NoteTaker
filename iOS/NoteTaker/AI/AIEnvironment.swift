import Foundation

@MainActor
struct AIEnvironment {
    let client: any OpenRouterServing
    let keyStore: any APIKeyStoring
    let chunker: any MeetingAudioChunking
    let defaults: UserDefaults

    static func live() -> AIEnvironment {
        AIEnvironment(client: OpenRouterClient(), keyStore: KeychainAPIKeyStore(),
                      chunker: MeetingAudioChunker(), defaults: .standard)
    }

    static func testing(configured: Bool = false) -> AIEnvironment {
        let defaults = UserDefaults(suiteName: "NoteTakerAIUITests.\(UUID())")!
        let keyStore = InMemoryAPIKeyStore()
        if configured {
            try? keyStore.save("ui-fixture-key")
            defaults.set("fixture/summary", forKey: "ai.modelID")
            defaults.set("fixture/transcription", forKey: "ai.transcriptionModelID")
            defaults.set(true, forKey: "ai.autoGenerate")
        }
        return AIEnvironment(client: FakeOpenRouterClient(), keyStore: keyStore,
                             chunker: FakeMeetingAudioChunker(), defaults: defaults)
    }
}

nonisolated struct FakeMeetingAudioChunker: MeetingAudioChunking {
    func chunkCount(for url: URL) async throws -> Int { 1 }
    func chunk(for url: URL, index: Int) async throws -> AudioChunk {
        AudioChunk(data: Data("fixture-audio".utf8), format: "wav", startTime: 0, duration: 1)
    }
}

nonisolated struct FakeOpenRouterClient: OpenRouterServing {
    func models() async throws -> [OpenRouterModel] {
        [OpenRouterModel(id: "fixture/summary", name: "Demo Meeting Model", contextLength: 32_000,
                         inputModalities: ["text"], outputModalities: ["text"]),
         OpenRouterModel(id: "fixture/transcription", name: "Demo Transcription", contextLength: 0,
                         inputModalities: ["audio"], outputModalities: ["transcription"])]
    }
    func validateKey(_ apiKey: String) async throws {}
    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        try await Task.sleep(for: .milliseconds(150))
        return AITextResponse(text: "오늘 제품 회의에서 회의록 기능과 다음 주 출시 준비를 논의했습니다. 디자인 검토 후 일정을 확정하기로 했습니다.")
    }
    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        try await Task.sleep(for: .milliseconds(150))
        return AITextResponse(text: """
        # 제품 회의록

        **AI 회의록 기능**과 다음 주 출시 준비를 논의했습니다. 사용자가 녹음에 집중하면서도 결정 사항과 후속 업무를 빠르게 확인할 수 있는 흐름을 검토했습니다.

        ## 녹음부터 회의록까지 이어지는 자동화
        녹음이 끝나면 음성을 전사하고, 선택한 AI 모델이 주제별 회의록을 작성하는 흐름을 검토했습니다. 메인 창을 닫고 메뉴 막대에서 녹음한 경우에도 같은 흐름을 유지하기로 했습니다.

        ## 검토와 공유가 쉬운 문서 구성
        요약과 전사문을 함께 확인하고, Markdown을 복사해 Notion 등에서 활용하는 방안을 논의했습니다. 실제 출시 일정은 디자인 검토를 마친 뒤 확정합니다.

        ## Action Items
        ### 담당자 미정
        - [ ] 디자인 검토 — 담당자 미정
        - [ ] 출시 일정 확정 — 기한 미정

        ## 미결 사항
        | 항목 | 상태 |
        | --- | --- |
        | 출시 날짜 | 검토 후 확정 |
        """, costUSD: 0)
    }
}
