import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Numbered transcript")
struct NumberedTranscriptTests {
    private let recordingID = UUID(uuidString: "ABCDEFAB-1234-5678-9ABC-ABCDEFABCDEF")!

    @Test("speaker numbers follow first chronological known speaker appearance")
    func speakerNumbersFollowFirstKnownAppearance() {
        let transcript = MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "fixture/stt",
            speakers: [
                MeetingSpeaker(id: "owner", name: "Me", isOwner: true),
                MeetingSpeaker(id: "speaker-b", name: "Bailey", isOwner: false),
                MeetingSpeaker(id: "speaker-a", name: "Avery", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-3", start: 2, end: 3, speakerID: "speaker-a", text: "Third known."),
                TranscriptTurn(id: "turn-1", start: 0, end: 1, speakerID: "speaker-b", text: "First known."),
                TranscriptTurn(id: "turn-2", start: 1, end: 2, speakerID: "speaker-a", text: "Second known."),
                TranscriptTurn(id: "turn-4", start: 3, end: 4, speakerID: "speaker-b", text: "Fourth known.")
            ])

        #expect(NumberedTranscript.text(transcript) == """
        [0:00] \(String(localized: "Participant \(1)")): First known.
        [0:01] \(String(localized: "Participant \(2)")): Second known.
        [0:02] \(String(localized: "Participant \(2)")): Third known.
        [0:03] \(String(localized: "Participant \(1)")): Fourth known.
        """)
    }

    @Test("notes use matching corrected participants without adopting another STT model's transcript")
    func notesUseOnlyCompatibleResolvedTranscript() {
        let embedded = MeetingTranscript(recordingID: recordingID, audioVersion: 1, transcriptionModelID: "new/stt",
            speakers: [], turns: [])
        let old = MeetingTranscript(recordingID: recordingID, audioVersion: 1, transcriptionModelID: "old/stt",
            speakers: [], turns: [])
        let corrected = MeetingTranscript(recordingID: recordingID, audioVersion: 1, transcriptionModelID: "new/stt",
            speakers: [MeetingSpeaker(id: "p1", name: "Corrected", isOwner: false)], turns: [])
        let document = MeetingNotesDocument(recordingID: recordingID, audioVersion: 1, generatedAt: .now,
            modelID: "summary", transcriptionModelID: "new/stt", markdown: "notes", transcript: "text",
            speakerTranscript: embedded)
        #expect(document.participantTranscript(resolvingWith: old) == embedded)
        #expect(document.participantTranscript(resolvingWith: corrected) == corrected)
    }

    @Test("unknown turns and unused owner target do not consume participant numbers")
    func unknownTurnsAndUnusedOwnerDoNotConsumeNumbers() {
        let transcript = MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "fixture/stt",
            speakers: [
                MeetingSpeaker(id: "owner", name: "Me", isOwner: true),
                MeetingSpeaker(id: "speaker-a", name: "Avery", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-1", start: 0, end: 1, speakerID: nil, text: "Unclear opener."),
                TranscriptTurn(id: "turn-2", start: 1, end: 2, speakerID: "speaker-a", text: "Known speaker."),
                TranscriptTurn(id: "turn-3", start: 2, end: 3, speakerID: "missing", text: "Bad speaker ID.")
            ])

        #expect(NumberedTranscript.text(transcript) == """
        [0:00] \(String(localized: "Unidentified participant")): Unclear opener.
        [0:01] \(String(localized: "Participant \(1)")): Known speaker.
        [0:02] \(String(localized: "Unidentified participant")): Bad speaker ID.
        """)
    }
}
