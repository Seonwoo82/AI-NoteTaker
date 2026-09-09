import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Contextual transcript cleanup")
struct TranscriptCleanupTests {
    @Test("cleanup preserves meaningful context and numbers while removing explicit noise")
    func cleanupPreservesMeaningAndOriginal() throws {
        let raw = "예산은 30만원입니다.\n\n[문 닫히는 소리]\n\n아직 승인되지 않았습니다."
        let source = try TranscriptCleanupSource.make(transcript: raw, speakerTranscript: nil)
        let batches = try TranscriptCleanupPrompts.batches(source: source, maximumBytes: 8_000)
        var responses: [String: String] = [:]
        for batch in batches {
            let text = try response(batch, transform: { $0.contains("[문 닫히는 소리]") ? "" : $0 })
            responses.merge(try batch.decode(text)) { old, _ in old }
        }
        let cleaned = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: responses)
        try cleaned.validate(transcript: raw, speakerTranscript: nil)
        #expect(cleaned.cleanedText.contains("30만원"))
        #expect(cleaned.cleanedText.contains("아직 승인되지 않았습니다"))
        #expect(!cleaned.cleanedText.contains("문 닫히는 소리"))
        #expect(cleaned.removedPassageCount == 1)
        #expect(source.passages[1].text == "[문 닫히는 소리]")
        #expect(throws: AIError.self) { try cleaned.validate(transcript: raw + "Changed", speakerTranscript: nil) }
    }

    @Test("model responses cannot change numbers, IDs or add instruction fields")
    func malformedOrChangedFactsAreRejected() throws {
        let source = try TranscriptCleanupSource.make(transcript: "[00:30] 예산은 30만원입니다.", speakerTranscript: nil)
        let batch = try #require(TranscriptCleanupPrompts.batches(source: source, maximumBytes: 4_000).first)
        #expect(throws: AIError.self) { _ = try batch.decode(response(batch, transform: { $0.replacingOccurrences(of: "30만원", with: "90만원") })) }
        #expect(throws: AIError.self) { _ = try batch.decode("{\"passages\":[]}") }
        #expect(throws: AIError.self) { _ = try batch.decode("{\"passages\":[{\"id\":\"wrong\",\"text\":\"30만원\"}]}") }
        let unsafe = "{\"passages\":[{\"id\":\"u0\",\"text\":\"[00:30] 예산은 30만원입니다.\",\"speaker\":\"other\"}]}"
        #expect(throws: AIError.self) { _ = try batch.decode(unsafe) }
    }

    @Test("long Unicode transcripts fit each model request and retain complete source IDs")
    func requestsStayBounded() throws {
        let raw = String(repeating: "일정과 예산 30만원을 검토합니다. ", count: 500)
        let source = try TranscriptCleanupSource.make(transcript: raw, speakerTranscript: nil)
        let batches = try TranscriptCleanupPrompts.batches(source: source, maximumBytes: 4_000)
        #expect(batches.count > 1)
        #expect(batches.allSatisfy { $0.prompt.utf8.count <= 4_000 })
        var responses: [String: String] = [:]
        for batch in batches { responses.merge(try batch.decode(response(batch, transform: { $0 }))) { old, _ in old } }
        let cleaned = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: responses)
        try cleaned.validate(transcript: raw, speakerTranscript: nil)
        #expect(cleaned.passages.map(\.id) == source.passages.map(\.id))
        #expect(cleaned.cleanedText.filter { !$0.isWhitespace } == raw.filter { !$0.isWhitespace })
    }

    @Test("response ordering cannot reorder the original conversation")
    func responseIDsRestoreSourceOrder() throws {
        let source = try TranscriptCleanupSource.make(transcript: "First opinion.\n\nSecond opinion.", speakerTranscript: nil)
        let batches = try TranscriptCleanupPrompts.batches(source: source, maximumBytes: 8_000)
        let batch = try #require(batches.first)
        let reversed = batch.units.reversed().map { ["id": $0.id, "text": $0.text] }
        let data = try JSONSerialization.data(withJSONObject: ["passages": reversed])
        let answers = try batch.decode(String(decoding: data, as: UTF8.self))
        let cleaned = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: answers)
        #expect(cleaned.passages.map(\.text) == ["First opinion.", "Second opinion."])
    }

    @Test("excessive deletion and empty cleanup cannot replace a conversation")
    func excessiveDeletionIsRejected() throws {
        let source = try TranscriptCleanupSource.make(transcript: String(repeating: "의견을 유지합니다. ", count: 200), speakerTranscript: nil)
        let batches = try TranscriptCleanupPrompts.batches(source: source, maximumBytes: 8_000)
        let empty = Dictionary(uniqueKeysWithValues: batches.flatMap(\.units).map { ($0.id, "") })
        #expect(throws: AIError.self) { _ = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: empty) }
        let tiny = Dictionary(uniqueKeysWithValues: batches.flatMap(\.units).map { ($0.id, "의견") })
        #expect(throws: AIError.self) { _ = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: tiny) }
    }

    @Test("short conversations receive the same excessive-deletion protection")
    func shortConversationCannotBeErased() throws {
        let source = try TranscriptCleanupSource.make(transcript: "이 안건은 다음 분기에 다시 검토하고 비용 산정 결과를 받아 결정합니다.\n\n회의 종료.", speakerTranscript: nil)
        let batches = try TranscriptCleanupPrompts.batches(source: source, maximumBytes: 8_000)
        let answers = Dictionary(uniqueKeysWithValues: batches.flatMap(\.units).map { ($0.id, $0.sourceID == "p0" ? "" : $0.text) })
        #expect(throws: AIError.self) { _ = try TranscriptCleanupPrompts.result(source: source, modelID: "fixture/model", batches: batches, responses: answers) }
    }

    @Test("separate repeated amounts and timestamp occurrences cannot disappear")
    func repeatedFactsKeepTheirOccurrences() throws {
        let source = try TranscriptCleanupSource.make(transcript: "개발팀에 30만원을 배정합니다. 디자인팀에도 30만원을 배정합니다.", speakerTranscript: nil)
        let batch = try #require(TranscriptCleanupPrompts.batches(source: source, maximumBytes: 8_000).first)
        #expect(throws: AIError.self) { _ = try batch.decode(response(batch, transform: { _ in "개발팀에 30만원을 배정합니다." })) }
        let timed = try TranscriptCleanupSource.make(transcript: "[00:30] 의견 A. [00:30] 의견 B.", speakerTranscript: nil)
        let timedBatch = try #require(TranscriptCleanupPrompts.batches(source: timed, maximumBytes: 8_000).first)
        #expect(throws: AIError.self) { _ = try timedBatch.decode(response(timedBatch, transform: { _ in "[00:30] 의견 A. 00:30 의견 B." })) }
    }

    @Test("minutes and analysis prompts ignore noise without suppressing dissent")
    func allGeneratorsUseContextPolicy() {
        for prompt in [MeetingNotesPrompts.system(language: "ko", partial: false),
                       MeetingNotesPrompts.system(language: "en", partial: true), MeetingAnalysisPrompt.systemPrompt] {
            #expect(prompt.contains("background noise"))
            #expect(prompt.contains("dissent"))
            #expect(prompt.contains("untrusted"))
        }
        #expect(TranscriptCleanupPrompts.system.contains("not summarize or translate"))
    }

    private func response(_ batch: TranscriptCleanupPrompts.Batch, transform: (String) -> String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["passages": batch.units.map { ["id": $0.id, "text": transform($0.text)] }])
        return String(decoding: data, as: UTF8.self)
    }
}
