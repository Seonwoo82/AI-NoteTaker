import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite
struct LocalAIBackendTests {

    private static var runtimeSmokeEnabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["NOTETAKER_LOCAL_AI_RUNTIME_SMOKE"] == "1"
            || environment["TEST_RUNNER_NOTETAKER_LOCAL_AI_RUNTIME_SMOKE"] == "1"
    }
    @Test("local model helpers recognize summary and supported speech locales")
    func localModelHelpersRecognizeSupportedIDs() {
        #expect(LocalAIProcessingMode.openRouter.rawValue == "openRouter")
        #expect(LocalAIProcessingMode.onDevice.rawValue == "onDevice")
        #expect(LocalAIModel.summaryID == "apple/on-device-summary")
        #expect(LocalAIModel.transcriptionID(localeIdentifier: "ko-KR") == "apple/on-device-speech/ko-KR")
        #expect(LocalAIModel.transcriptionID(localeIdentifier: "en-US") == "apple/on-device-speech/en-US")
        #expect(LocalAIModel.transcriptionID(localeIdentifier: "fr-FR") == nil)
        #expect(LocalAIModel.isLocal(modelID: LocalAIModel.summaryID))
        #expect(LocalAIModel.isLocal(modelID: "apple/on-device-speech/en-US"))
        #expect(!LocalAIModel.isLocal(modelID: "openai/whisper-large-v3"))
        #expect(LocalAIModel.speechLocale(modelID: "apple/on-device-speech/ko-KR") == "ko-KR")
        #expect(LocalAIModel.speechLocale(modelID: "apple/on-device-speech/fr-FR") == nil)
        #expect(LocalAIModel.summaryDescriptor.id == LocalAIModel.summaryID)
        #expect(LocalAIModel.summaryDescriptor.contextLength == 4_096)
        #expect(LocalAIModel.summaryDescriptor.maxCompletionTokens == 1_024)
    }

    @Test("routing sends local summary and transcription only to local client")
    func routingSendsLocalCallsOnlyToLocalClient() async throws {
        let cloud = RecordingAIClient(label: "cloud")
        let local = RecordingAIClient(label: "local")
        await local.setCompleteResult(AITextResponse(text: "local notes", costUSD: 0))
        await local.setTranscribeResult(AITextResponse(text: "local transcript", costUSD: 0))
        let router = RoutingAIClient(cloud: cloud, local: local)

        let notes = try await router.complete(
            system: "system",
            user: "user",
            model: LocalAIModel.summaryID,
            apiKey: "",
            maxTokens: 512
        )
        let transcript = try await router.transcribe(
            audio: Data([1, 2, 3]),
            format: "wav",
            model: LocalAIModel.transcriptionID(localeIdentifier: "ko-KR")!,
            apiKey: "",
            language: nil
        )

        #expect(notes.text == "local notes")
        #expect(transcript.text == "local transcript")
        #expect(notes.costUSD == 0)
        #expect(transcript.costUSD == 0)
        #expect(await local.completeModels == [LocalAIModel.summaryID])
        #expect(await local.transcribeModels == ["apple/on-device-speech/ko-KR"])
        #expect(await cloud.callCount == 0)
    }

    @Test("routing exposes only cloud catalog models")
    func routingModelsExposeOnlyCloudCatalog() async throws {
        let cloud = RecordingAIClient(label: "cloud")
        await cloud.setModels([OpenRouterModel(
            id: "openai/whisper-large-v3",
            name: "Whisper",
            contextLength: 0,
            inputModalities: ["audio"],
            outputModalities: ["transcription"]
        )])
        let local = RecordingAIClient(label: "local")
        let router = RoutingAIClient(cloud: cloud, local: local)

        let models = try await router.models()

        #expect(models.map(\.id) == ["openai/whisper-large-v3"])
        #expect(await cloud.modelsCallCount == 1)
        #expect(await local.modelsCallCount == 0)
    }

    @Test("routing never falls back to cloud when local summary fails")
    func routingDoesNotCloudFallbackForLocalFailure() async {
        let cloud = RecordingAIClient(label: "cloud")
        let local = RecordingAIClient(label: "local")
        await local.setCompleteError(AIError(message: "local unavailable"))
        let router = RoutingAIClient(cloud: cloud, local: local)

        await #expect(throws: AIError.self) {
            _ = try await router.complete(
                system: "system",
                user: "user",
                model: LocalAIModel.summaryID,
                apiKey: "",
                maxTokens: 512
            )
        }

        #expect(await local.completeModels == [LocalAIModel.summaryID])
        #expect(await cloud.callCount == 0)
    }

    @Test("routing rejects unknown apple on-device IDs before cloud")
    func routingRejectsUnknownLocalPrefixBeforeCloud() async {
        let cloud = RecordingAIClient(label: "cloud")
        let local = RecordingAIClient(label: "local")
        let router = RoutingAIClient(cloud: cloud, local: local)

        await #expect(throws: AIError.self) {
            _ = try await router.complete(
                system: "system",
                user: "user",
                model: "apple/on-device-unknown",
                apiKey: "",
                maxTokens: 512
            )
        }

        #expect(await local.callCount == 0)
        #expect(await cloud.callCount == 0)
    }

    @Test("routing preserves detailed transcription for cloud clients")
    func routingPreservesCloudDetailedTranscription() async throws {
        let cloud = RecordingDetailedAIClient(label: "cloud")
        await cloud.setDetailedResult(DetailedTranscriptionResult(
            text: "speaker transcript",
            words: [TimedTranscriptionWord(text: "speaker", start: 0, end: 0.5, speakerID: "speaker-1")],
            segments: [TimedTranscriptionSegment(text: "speaker transcript", start: 0, end: 1, speakerID: "speaker-1")],
            costUSD: 0.01
        ))
        let local = RecordingAIClient(label: "local")
        let router = RoutingAIClient(cloud: cloud, local: local)

        let result = try await router.transcribeDetailed(
            audio: Data([1]),
            format: "wav",
            model: "openai/whisper-large-v3",
            apiKey: "sk",
            language: "ko",
            prompt: "prompt"
        )

        #expect(result.text == "speaker transcript")
        #expect(await cloud.detailedModels == ["openai/whisper-large-v3"])
        #expect(await local.callCount == 0)
    }

    @Test("routing rejects local detailed transcription without cloud fallback")
    func routingRejectsLocalDetailedTranscription() async {
        let cloud = RecordingDetailedAIClient(label: "cloud")
        let local = RecordingAIClient(label: "local")
        let router = RoutingAIClient(cloud: cloud, local: local)

        await #expect(throws: AIError.self) {
            _ = try await router.transcribeDetailed(
                audio: Data([1]),
                format: "wav",
                model: "apple/on-device-speech/en-US",
                apiKey: "",
                language: nil,
                prompt: nil
            )
        }

        #expect(await local.callCount == 0)
        #expect(await cloud.callCount == 0)
    }

    @Test("apple on-device client validates local models without network cost")
    func appleClientValidatesLocalModels() async throws {
        let client = AppleOnDeviceAIClient()

        let models = try await client.models()

        #expect(models.contains(LocalAIModel.summaryDescriptor))
        #expect(models.contains { $0.id == "apple/on-device-speech/ko-KR" })
        #expect(models.contains { $0.id == "apple/on-device-speech/en-US" })
        try await client.validateKey("")
        await #expect(throws: AIError.self) {
            _ = try await client.complete(system: "s", user: "u", model: "openai/model", apiKey: "", maxTokens: 1)
        }
        await #expect(throws: AIError.self) {
            _ = try await client.transcribe(audio: Data([1]), format: "wav", model: "apple/on-device-speech/fr-FR", apiKey: "", language: nil)
        }
    }

    @Test("apple on-device transcription rejects non-WAV input before speech authorization")
    func appleClientRejectsNonWAVInputBeforeSpeechAuthorization() async {
        let client = AppleOnDeviceAIClient()

        await #expect(throws: AIError.self) {
            _ = try await client.transcribe(
                audio: Data([1, 2, 3]),
                format: "m4a",
                model: LocalAIModel.transcriptionID(localeIdentifier: "ko-KR")!,
                apiKey: "",
                language: nil
            )
        }
    }

    @Test(
        "runtime smoke completes synthetic Korean notes locally when enabled",
        .enabled(if: runtimeSmokeEnabled)
    )
    func runtimeSmokeCompletesSyntheticKoreanNotesLocallyWhenEnabled() async throws {
        let response = try await AppleOnDeviceAIClient(summaryTimeout: .seconds(60)).complete(
            system: "너는 회의록 작성 도우미입니다. 한국어로 두 문장 이하로 요약하세요.",
            user: "오늘 회의에서는 온디바이스 전사와 요약을 무료로 제공하고, 클라우드 전송 없이 처리하기로 했습니다. 다음 단계는 설정 화면에서 준비 상태를 보여주는 것입니다.",
            model: LocalAIModel.summaryID,
            apiKey: "",
            maxTokens: 160
        )

        #expect(response.costUSD == 0)
        #expect(!response.text.isEmpty)
        #expect(!response.text.contains("NOTE_TAKER_LOCAL_AI_COMPLETE"))
        #expect(response.text.contains("온디바이스") || response.text.contains("클라우드"))
    }

    @Test("local continuation owner resumes cancellation that happens before install")
    func continuationOwnerHandlesCancelBeforeInstall() async throws {
        let owner = LocalAIContinuationOwner<String>()
        owner.cancel()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation: continuation)
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected path.
        }
    }

    @Test("local continuation owner cancels task installed after callback")
    func continuationOwnerCancelsTaskInstalledAfterCallback() async throws {
        let owner = LocalAIContinuationOwner<String>()
        let taskCancelled = LockedFlag()

        let value = try await withCheckedThrowingContinuation { continuation in
            owner.install(continuation: continuation)
            owner.resume(returning: "done")
            owner.installTask {
                taskCancelled.set()
            }
        }

        #expect(value == "done")
        #expect(taskCancelled.isSet)
    }

    @Test("local continuation owner ignores duplicate success callbacks")
    func continuationOwnerIgnoresDuplicateSuccessCallbacks() async throws {
        let owner = LocalAIContinuationOwner<String>()

        let value = try await withCheckedThrowingContinuation { continuation in
            owner.install(continuation: continuation)
            owner.resume(returning: "first")
            owner.resume(returning: "second")
        }

        #expect(value == "first")
    }

    @Test("local continuation owner ignores duplicate error callbacks")
    func continuationOwnerIgnoresDuplicateErrorCallbacks() async throws {
        let owner = LocalAIContinuationOwner<String>()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation: continuation)
                owner.resume(throwing: AIError(message: "first"))
                owner.resume(throwing: AIError(message: "second"))
            }
            Issue.record("Expected first error")
        } catch let error as AIError {
            #expect(error.message == "first")
        }
    }

    @Test("local continuation owner cancels installed task exactly once on cancellation")
    func continuationOwnerCancelsInstalledTaskOnCancellation() async throws {
        let owner = LocalAIContinuationOwner<String>()
        let cancelCount = LockedCounter()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation: continuation)
                owner.installTask {
                    cancelCount.increment()
                }
                owner.cancel()
                owner.resume(returning: "late")
            }
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            #expect(cancelCount.value == 1)
        }
    }
}

private actor RecordingAIClient: OpenRouterServing {
    let label: String
    var completeResult = AITextResponse(text: "")
    var transcribeResult = AITextResponse(text: "")
    var completeError: Error?
    var transcribeError: Error?
    private var modelCatalog: [OpenRouterModel] = []
    private(set) var completeModels: [String] = []
    private(set) var transcribeModels: [String] = []
    private(set) var modelsCallCount = 0
    private(set) var validateKeyCallCount = 0

    init(label: String) {
        self.label = label
    }

    func setCompleteResult(_ result: AITextResponse) {
        completeResult = result
    }

    func setTranscribeResult(_ result: AITextResponse) {
        transcribeResult = result
    }

    func setCompleteError(_ error: Error) {
        completeError = error
    }

    func setModels(_ models: [OpenRouterModel]) {
        modelCatalog = models
    }

    var callCount: Int {
        completeModels.count + transcribeModels.count + modelsCallCount + validateKeyCallCount
    }

    func models() async throws -> [OpenRouterModel] {
        modelsCallCount += 1
        return modelCatalog
    }

    func validateKey(_ apiKey: String) async throws {
        validateKeyCallCount += 1
    }

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcribeModels.append(model)
        if let transcribeError { throw transcribeError }
        return transcribeResult
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completeModels.append(model)
        if let completeError { throw completeError }
        return completeResult
    }
}

private actor RecordingDetailedAIClient: OpenRouterServing, DetailedTranscriptionServing {
    let label: String
    var detailedResult = DetailedTranscriptionResult(text: "", words: [], segments: [])
    private(set) var completeModels: [String] = []
    private(set) var transcribeModels: [String] = []
    private(set) var detailedModels: [String] = []
    private(set) var modelsCallCount = 0
    private(set) var validateKeyCallCount = 0

    init(label: String) {
        self.label = label
    }

    func setDetailedResult(_ result: DetailedTranscriptionResult) {
        detailedResult = result
    }

    var callCount: Int {
        completeModels.count + transcribeModels.count + detailedModels.count + modelsCallCount + validateKeyCallCount
    }

    func models() async throws -> [OpenRouterModel] {
        modelsCallCount += 1
        return []
    }

    func validateKey(_ apiKey: String) async throws {
        validateKeyCallCount += 1
    }

    func transcribe(audio: Data, format: String, model: String, apiKey: String, language: String?) async throws -> AITextResponse {
        transcribeModels.append(model)
        return AITextResponse(text: label)
    }

    func complete(system: String, user: String, model: String, apiKey: String, maxTokens: Int) async throws -> AITextResponse {
        completeModels.append(model)
        return AITextResponse(text: label)
    }

    func transcribeDetailed(
        audio: Data,
        format: String,
        model: String,
        apiKey: String,
        language: String?,
        prompt: String?
    ) async throws -> DetailedTranscriptionResult {
        detailedModels.append(model)
        return detailedResult
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
