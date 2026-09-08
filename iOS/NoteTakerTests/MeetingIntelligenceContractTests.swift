import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Meeting intelligence contracts")
struct MeetingIntelligenceContractTests {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test("valid transcript and insights accept cited owner commitments answers and decisions")
    func validatesSupportedMeetingAnalysis() throws {
        let transcript = fixtureTranscript()
        let insights = MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Send the revised proposal",
                actorSpeakerID: "owner", targetSpeakerID: nil, dueText: "tomorrow", evidenceTurnIDs: ["turn-1"])
        ], questions: [
            MeetingQuestion(id: "question-1", question: "Can the deadline move?",
                questionTurnIDs: ["turn-2"], answer: "Yes, tomorrow is acceptable.",
                answerTurnIDs: ["turn-3"], status: .answered)
        ], decisions: [
            MeetingDecision(id: "decision-1", topic: "Launch timing", status: .decided, steps: [
                MeetingDecisionStep(kind: .proposal, text: "Move the launch", speakerID: "owner", evidenceTurnIDs: ["turn-1"]),
                MeetingDecisionStep(kind: .concern, text: "Schedule risk", speakerID: "guest", evidenceTurnIDs: ["turn-2"]),
                MeetingDecisionStep(kind: .decision, text: "Ship tomorrow", speakerID: "guest", evidenceTurnIDs: ["turn-3"])
            ])
        ])

        try transcript.validate(duration: 10)
        try insights.validate(transcript: transcript)
    }

    @Test("transcript validation rejects duplicate IDs bad time ranges and unknown speakers")
    func rejectsInvalidTranscriptShape() throws {
        let staleAudioVersion = MeetingTranscript(recordingID: recordingID, audioVersion: 0,
            transcriptionModelID: "openai/gpt-4o-transcribe:online", speakers: [],
            turns: [])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try staleAudioVersion.validate(duration: 10)
        }

        let duplicateTurns = MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "model", speakers: [MeetingSpeaker(id: "owner", name: "Me", isOwner: true)],
            turns: [
                TranscriptTurn(id: "turn-1", start: 0, end: 1, speakerID: "owner", text: "First"),
                TranscriptTurn(id: "turn-1", start: 1, end: 2, speakerID: "owner", text: "Second")
            ])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try duplicateTurns.validate(duration: 10)
        }

        let backwards = MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "model", speakers: [MeetingSpeaker(id: "owner", name: "Me", isOwner: true)],
            turns: [TranscriptTurn(id: "turn-2", start: 3, end: 2, speakerID: "owner", text: "Bad")])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try backwards.validate(duration: 10)
        }

        let unknownSpeaker = MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "model", speakers: [],
            turns: [TranscriptTurn(id: "turn-3", start: 0, end: 1, speakerID: "missing", text: "Bad")])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try unknownSpeaker.validate(duration: 10)
        }
    }

    @Test("insights validation rejects unsupported citations impossible answers and uncited due text")
    func rejectsInvalidInsightEvidence() throws {
        let transcript = fixtureTranscript()

        let unknownEvidence = MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .request, text: "Review the proposal",
                actorSpeakerID: "guest", targetSpeakerID: "owner", dueText: nil, evidenceTurnIDs: ["missing"])
        ])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try unknownEvidence.validate(transcript: transcript)
        }

        let answeredWithoutEvidence = MeetingInsights(questions: [
            MeetingQuestion(id: "question-1", question: "Can we ship?",
                questionTurnIDs: ["turn-2"], answer: "Yes", answerTurnIDs: [], status: .answered)
        ])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try answeredWithoutEvidence.validate(transcript: transcript)
        }

        let unsupportedDue = MeetingInsights(actions: [
            MeetingAction(id: "action-2", kind: .commitment, text: "Send the proposal",
                actorSpeakerID: "owner", targetSpeakerID: nil, dueText: "Friday", evidenceTurnIDs: ["turn-1"])
        ])
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try unsupportedDue.validate(transcript: transcript)
        }
    }

    @Test("decoder accepts fenced JSON and rejects generated content with invalid evidence")
    func decodesFencedValidatedJSON() throws {
        let transcript = fixtureTranscript()
        let response = """
        Here is the analysis:
        ```json
        {
          "schemaVersion": 1,
          "actions": [
            {
              "id": "action-1",
              "kind": "commitment",
              "text": "Send the revised proposal",
              "actorSpeakerID": "owner",
              "targetSpeakerID": null,
              "dueText": "tomorrow",
              "evidenceTurnIDs": ["turn-1"]
            }
          ],
          "questions": [],
          "decisions": []
        }
        ```
        """
        let decoded = try MeetingAnalysisPrompt.decode(response, transcript: transcript)
        #expect(decoded.actions.first?.id == "action-1")
        #expect(decoded.actions.first?.kind == .commitment)

        let hallucinated = response.replacing("turn-1", with: "missing-turn")
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try MeetingAnalysisPrompt.decode(hallucinated, transcript: transcript)
        }
    }

    @Test("decoder rejects incomplete analysis JSON instead of accepting empty defaults")
    func rejectsIncompleteAnalysisJSON() throws {
        let transcript = fixtureTranscript()

        for response in ["{}", #"{"schemaVersion":1}"#, #"{"schemaVersion":1,"actions":[],"questions":[]}"#] {
            #expect(throws: MeetingIntelligenceValidationError.self) {
                try MeetingAnalysisPrompt.decode(response, transcript: transcript)
            }
        }
    }

    @Test("analysis prompt preserves speaker IDs and profile context without identity inference rules")
    func buildsEvidenceBasedPrompts() {
        let transcript = fixtureTranscript()
        let system = MeetingAnalysisPrompt.systemPrompt
        let user = MeetingAnalysisPrompt.userPrompt(transcript: transcript,
            profileContext: "Owner display name: Seonwoo\nGlossary: D1, R2, OpenRouter")

        #expect(system.contains("Return only JSON"))
        #expect(system.contains("Do not infer the owner from text"))
        #expect(user.contains("turn-1"))
        #expect(user.contains("[owner]"))
        #expect(user.contains("Owner display name: Seonwoo"))
        #expect(user.contains("D1, R2, OpenRouter"))
    }

    private func fixtureTranscript() -> MeetingTranscript {
        MeetingTranscript(recordingID: recordingID, audioVersion: 1,
            transcriptionModelID: "fixture/transcription",
            speakers: [
                MeetingSpeaker(id: "owner", name: "Seonwoo", isOwner: true),
                MeetingSpeaker(id: "guest", name: "Guest", isOwner: false)
            ],
            turns: [
                TranscriptTurn(id: "turn-1", start: 0, end: 2, speakerID: "owner",
                    text: "I will send the revised proposal tomorrow."),
                TranscriptTurn(id: "turn-2", start: 2, end: 4, speakerID: "guest",
                    text: "Can the deadline move? I am worried about schedule risk."),
                TranscriptTurn(id: "turn-3", start: 4, end: 6, speakerID: "guest",
                    text: "Yes, tomorrow is acceptable. Let us ship tomorrow.")
            ])
    }
}
