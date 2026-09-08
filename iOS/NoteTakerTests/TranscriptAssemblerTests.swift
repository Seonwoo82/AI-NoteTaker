import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Transcript assembler")
struct TranscriptAssemblerTests {
    private let recordingID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    @Test("word timing splits speakers even when a broad segment is also supplied")
    func wordTimingTakesPrecedenceOverBroadSegments() throws {
        let chunk = TimedTranscriptChunk(startTime: 0, result: DetailedTranscriptionResult(text: "Hello there",
            words: [TimedTranscriptionWord(text: "Hello", start: 0, end: 0.4, speakerID: nil),
                    TimedTranscriptionWord(text: "there", start: 0.5, end: 1, speakerID: nil)],
            segments: [TimedTranscriptionSegment(text: "Hello there", start: 0, end: 1, speakerID: nil)]))
        let transcript = try TranscriptAssembler.assemble(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "fixture", chunks: [chunk],
            diarization: AcousticDiarization(speakers: [AcousticSpeaker(id: "a", embedding: [1, 0]),
                AcousticSpeaker(id: "b", embedding: [0, 1])], spans: [
                AcousticSpeakerSpan(start: 0, end: 0.4, speakerID: "a"),
                AcousticSpeakerSpan(start: 0.5, end: 1, speakerID: "b")]),
            ownerVoice: nil, embeddingModelID: "fixture", duration: 1)
        #expect(transcript.turns.map(\.text) == ["Hello", "there"])
        #expect(transcript.turns.map(\.speakerID) == ["speaker-a", "speaker-b"])
    }

    @Test("manual owner target exists without inventing owner speech")
    func manualOwnerTargetWithoutEnrollment() throws {
        let chunk = TimedTranscriptChunk(startTime: 0, result: DetailedTranscriptionResult(text: "Hello", words: [],
            segments: [TimedTranscriptionSegment(text: "Hello", start: 0, end: 1, speakerID: nil)]))
        let transcript = try TranscriptAssembler.assemble(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "fixture", chunks: [chunk], diarization: AcousticDiarization(speakers: [], spans: []),
            ownerVoice: nil, embeddingModelID: "fixture", duration: 1)
        #expect(transcript.speakers.contains { $0.id == "owner" && $0.isOwner })
        #expect(transcript.turns.first?.speakerID == nil)
        let document = MeetingIntelligenceDocument(recordingID: recordingID, audioVersion: 1, modifiedAt: 1,
            mutationID: UUID(), projectName: "", transcript: transcript, insights: nil, analysisModelID: "fixture")
        let edit = MeetingEdit(id: UUID(), recordingID: recordingID, audioVersion: 1, modifiedAt: 2,
            kind: .turnSpeaker, targetID: transcript.turns[0].id, value: "owner")
        let resolved = try document.resolved(edits: [edit])
        #expect(resolved.ownerTurns.count == 1)
        #expect(resolved.unresolvedEditCount == 0)
    }

    @Test("diarization overlap assigns speakers and leaves ambiguous words unknown")
    func alignsSpeakersAndKeepsAmbiguousOverlapUnknown() throws {
        let chunk = TimedTranscriptChunk(
            startTime: 0,
            result: DetailedTranscriptionResult(
                text: "I can own this yes",
                words: [
                    TimedTranscriptionWord(text: "I", start: 0.10, end: 0.35, speakerID: nil),
                    TimedTranscriptionWord(text: "can", start: 0.36, end: 0.60, speakerID: nil),
                    TimedTranscriptionWord(text: "own", start: 1.20, end: 1.55, speakerID: nil),
                    TimedTranscriptionWord(text: "this", start: 1.56, end: 1.90, speakerID: nil),
                    TimedTranscriptionWord(text: "yes", start: 2.10, end: 2.40, speakerID: nil)
                ],
                segments: []
            )
        )
        let diarization = AcousticDiarization(
            speakers: [
                AcousticSpeaker(id: "cluster-a", embedding: [1, 0]),
                AcousticSpeaker(id: "cluster-b", embedding: [0, 1])
            ],
            spans: [
                AcousticSpeakerSpan(start: 0, end: 1, speakerID: "cluster-a"),
                AcousticSpeakerSpan(start: 1, end: 2, speakerID: "cluster-b"),
                AcousticSpeakerSpan(start: 2, end: 3, speakerID: "cluster-a"),
                AcousticSpeakerSpan(start: 2, end: 3, speakerID: "cluster-b")
            ]
        )
        let owner = LocalVoiceProfile(modelID: "fixture-speakers", embedding: [1, 0],
            enrolledAt: Date(timeIntervalSince1970: 1), sampleDuration: 12)

        let transcript = try TranscriptAssembler.assemble(
            recordingID: recordingID,
            audioVersion: 2,
            transcriptionModelID: "fixture/stt",
            chunks: [chunk],
            diarization: diarization,
            ownerVoice: owner,
            embeddingModelID: "fixture-speakers",
            duration: 3
        )

        #expect(transcript.speakers.contains(MeetingSpeaker(id: "owner", name: "Me", isOwner: true)))
        #expect(transcript.speakers.contains(MeetingSpeaker(id: "speaker-cluster-b", name: "Speaker 2", isOwner: false)))
        #expect(transcript.turns.map(\.speakerID) == ["owner", "speaker-cluster-b", nil])
        #expect(transcript.turns.map(\.text) == ["I can", "own this", "yes"])
    }

    @Test("turn IDs stay stable for unchanged recording version timing and text")
    func stableTurnIDs() throws {
        let first = try fixtureTranscript(text: "Ship tomorrow")
        let second = try fixtureTranscript(text: "Ship tomorrow")
        let changedText = try fixtureTranscript(text: "Ship Friday")

        #expect(first.turns.map(\.id) == second.turns.map(\.id))
        #expect(first.turns.map(\.id) != changedText.turns.map(\.id))
    }

    @Test("speaker span boundary contact is not treated as overlap")
    func boundaryContactIsNotOverlap() throws {
        let chunk = TimedTranscriptChunk(
            startTime: 0,
            result: DetailedTranscriptionResult(
                text: "handoff works",
                words: [
                    TimedTranscriptionWord(text: "handoff", start: 0.5, end: 1.0, speakerID: nil),
                    TimedTranscriptionWord(text: "works", start: 1.0, end: 1.5, speakerID: nil)
                ],
                segments: []
            )
        )
        let diarization = AcousticDiarization(
            speakers: [
                AcousticSpeaker(id: "a", embedding: [1, 0]),
                AcousticSpeaker(id: "b", embedding: [0, 1])
            ],
            spans: [
                AcousticSpeakerSpan(start: 0, end: 1, speakerID: "a"),
                AcousticSpeakerSpan(start: 1, end: 2, speakerID: "b")
            ]
        )

        let transcript = try TranscriptAssembler.assemble(
            recordingID: recordingID,
            audioVersion: 1,
            transcriptionModelID: "fixture/stt",
            chunks: [chunk],
            diarization: diarization,
            ownerVoice: nil,
            embeddingModelID: "fixture-speakers",
            duration: 2
        )

        #expect(transcript.turns.map(\.speakerID) == ["speaker-a", "speaker-b"])
    }


    @Test("invalid timed words are rejected instead of inventing timestamps")
    func rejectsInvalidTimestamps() {
        let chunk = TimedTranscriptChunk(
            startTime: 0,
            result: DetailedTranscriptionResult(
                text: "bad",
                words: [TimedTranscriptionWord(text: "bad", start: 5, end: 6, speakerID: nil)],
                segments: []
            )
        )

        #expect(throws: MeetingIntelligenceValidationError.self) {
            _ = try TranscriptAssembler.assemble(
                recordingID: recordingID,
                audioVersion: 1,
                transcriptionModelID: "fixture/stt",
                chunks: [chunk],
                diarization: AcousticDiarization(speakers: [], spans: []),
                ownerVoice: nil,
                embeddingModelID: "fixture-speakers",
                duration: 3
            )
        }
    }

    private func fixtureTranscript(text: String) throws -> MeetingTranscript {
        let words = text.split(separator: " ").enumerated().map { index, part in
            TimedTranscriptionWord(text: String(part), start: Double(index), end: Double(index) + 0.5, speakerID: nil)
        }
        return try TranscriptAssembler.assemble(
            recordingID: recordingID,
            audioVersion: 1,
            transcriptionModelID: "fixture/stt",
            chunks: [TimedTranscriptChunk(startTime: 0, result: DetailedTranscriptionResult(text: text, words: words, segments: []))],
            diarization: AcousticDiarization(speakers: [], spans: []),
            ownerVoice: nil,
            embeddingModelID: "fixture-speakers",
            duration: 10
        )
    }
}
