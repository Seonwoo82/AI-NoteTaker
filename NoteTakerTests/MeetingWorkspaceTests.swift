import Foundation
import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Meeting workspace")
struct MeetingWorkspaceTests {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let mutationA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let mutationB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test("resolved document applies speaker and turn corrections without mutating the source transcript")
    func resolvesCorrectionsPreservingSource() throws {
        let document = try fixtureDocument()
        let edits = [
            edit(kind: .speakerName, targetID: "speaker-a", value: "Seonwoo", modifiedAt: 10),
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "true", modifiedAt: 11),
            edit(kind: .turnSpeaker, targetID: "turn-2", value: "speaker-a", modifiedAt: 12),
            edit(kind: .actionStatus, targetID: "action-1", value: "done", modifiedAt: 13),
            edit(kind: .projectName, targetID: "", value: "Design Review", modifiedAt: 14)
        ]

        let resolved = try document.resolved(edits: edits)

        #expect(document.transcript.speakers.first?.name == "Speaker A")
        #expect(document.transcript.speakers.first?.isOwner == false)
        #expect(document.transcript.turns[1].speakerID == "speaker-b")
        #expect(resolved.transcript.speakers.first?.name == "Seonwoo")
        #expect(resolved.transcript.speakers.first?.isOwner == true)
        #expect(resolved.transcript.speakers.first?.manuallyAssigned == true)
        #expect(resolved.transcript.turns[1].speakerID == "speaker-a")
        #expect(resolved.projectName == "Design Review")
        #expect(resolved.actionStates["action-1"] == "done")
        #expect(resolved.unresolvedEditCount == 0)
    }

    @Test("last writer wins per editable field by modifiedAt then edit id")
    func lastWriterWinsPerField() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let document = try fixtureDocument()
        let edits = [
            MeetingEdit(id: secondID, recordingID: recordingID, audioVersion: 2, modifiedAt: 10,
                kind: .speakerName, targetID: "speaker-a", value: "Winning tie"),
            MeetingEdit(id: firstID, recordingID: recordingID, audioVersion: 2, modifiedAt: 10,
                kind: .speakerName, targetID: "speaker-a", value: "Losing tie"),
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "false", modifiedAt: 11),
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "true", modifiedAt: 12)
        ]

        let resolved = try document.resolved(edits: edits)

        #expect(resolved.transcript.speakers.first?.name == "Winning tie")
        #expect(resolved.transcript.speakers.first?.isOwner == true)
    }

    @Test("helpers filter owner turns commitments received requests evidence and statuses")
    func filtersResolvedMeetingFields() throws {
        let document = try fixtureDocument()
        let edits = [
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "true", modifiedAt: 10),
            edit(kind: .actionStatus, targetID: "action-1", value: "done", modifiedAt: 12)
        ]

        let resolved = try document.resolved(edits: edits)

        #expect(resolved.ownerTurns.map(\.id) == ["turn-1"])
        #expect(resolved.myCommitments.map(\.id) == ["action-1"])
        #expect(resolved.receivedRequests.map(\.id) == ["action-2"])
        #expect(resolved.evidenceTurns(for: ["turn-1", "turn-2"]).map(\.id) == ["turn-1", "turn-2"])
        #expect(resolved.actionStatus(for: "action-1") == .done)
    }

    @Test("commitments can follow a cited turn speaker correction but requests require explicit target owner")
    func resolvesCommitmentActorsThroughCitedTurnsOnly() throws {
        let document = try fixtureDocument()
        let edits = [
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "true", modifiedAt: 10),
            edit(kind: .turnSpeaker, targetID: "turn-3", value: "speaker-a", modifiedAt: 11)
        ]

        let resolved = try document.resolved(edits: edits)

        #expect(resolved.myCommitments.map(\.id) == ["action-1", "action-3"])
        #expect(resolved.receivedRequests.map(\.id) == ["action-2"])
    }

    @Test("multiple owner speaker clusters are valid and owner edits do not clear existing owner groups")
    func supportsMultipleOwnerClusters() throws {
        let document = try fixtureDocument(ownerSpeakerIDs: ["speaker-a"])
        try document.transcript.validate(duration: 12)

        let resolved = try document.resolved(edits: [
            edit(kind: .speakerOwner, targetID: "speaker-b", value: "true", modifiedAt: 10)
        ])

        let ownerIDs = resolved.transcript.speakers.filter(\.isOwner).map(\.id)
        #expect(ownerIDs == ["speaker-a", "speaker-b"])
        #expect(resolved.ownerTurns.map(\.id) == ["turn-1", "turn-2", "turn-3", "turn-4"])
        #expect(resolved.myCommitments.map(\.id) == ["action-1", "action-3"])
        #expect(resolved.receivedRequests.map(\.id) == ["action-2"])
    }

    @Test("virtual owner targets resolve legacy corrections without changing source data")
    func materializesOwnerOnlyForValidTurnCorrections() throws {
        let document = try fixtureDocument()
        let edits = [
            edit(kind: .speakerName, targetID: "owner", value: "My name", modifiedAt: 9),
            edit(kind: .turnSpeaker, targetID: "turn-2", value: "owner", modifiedAt: 10)
        ]
        let resolved = try document.resolved(edits: edits)
        #expect(resolved.unresolvedEditCount == 0)
        #expect(resolved.ownerTurns.map(\.id) == ["turn-2"])
        #expect(resolved.transcript.speakers.last?.name == "My name")
        #expect(resolved.transcript.speakers.last?.manuallyAssigned == true)
        #expect(resolved.source == document)
        try resolved.transcript.validate(duration: 12)

        let missing = try document.resolved(edits: [
            edit(kind: .turnSpeaker, targetID: "missing-turn", value: "owner", modifiedAt: 10)
        ])
        #expect(!missing.transcript.speakers.contains { $0.id == "owner" })
        #expect(missing.unresolvedEditCount == 1)
        let overwritten = try document.resolved(edits: edits + [
            edit(kind: .turnSpeaker, targetID: "turn-2", value: "speaker-a", modifiedAt: 11)
        ])
        #expect(!overwritten.transcript.speakers.contains { $0.id == "owner" })
        #expect(overwritten.transcript.turns[1].speakerID == "speaker-a")
    }

    @Test("one displayed owner identity aggregates acoustic and manual turns without merging raw records")
    func groupsOwnerIdentityAndPreservesEditTargets() throws {
        let document = try fixtureDocument()
        let corrections = [
            edit(kind: .turnSpeaker, targetID: "turn-2", value: "owner", modifiedAt: 10),
            edit(kind: .speakerOwner, targetID: "speaker-a", value: "true", modifiedAt: 11)
        ]
        let resolved = try document.resolved(edits: corrections)
        let owner = try #require(resolved.speakerIdentities.first { $0.isOwner })
        #expect(resolved.speakerIdentities.count == 2)
        #expect(owner.speakerIDs == ["speaker-a", "owner"])
        #expect(resolved.turns(for: owner).map(\.id) == ["turn-1", "turn-2"])
        #expect(resolved.speakerIdentity(for: "speaker-a") == resolved.speakerIdentity(for: "owner"))
        #expect(resolved.transcript.speakers.count == 3)
        #expect(resolved.insights?.actions.first?.actorSpeakerID == "speaker-a")
        #expect(resolved.speakerAssignmentChoices.filter { $0.isOwner }.count == 1)
        #expect(owner.contains(speakerID: "speaker-a"))
        #expect(owner.contains(speakerID: "owner"))

        let renamed = try document.resolved(edits: corrections + owner.speakerIDs.map {
            edit(kind: .speakerName, targetID: $0, value: "My name", modifiedAt: 12)
        })
        #expect(renamed.transcript.speakers.filter(\.isOwner).allSatisfy { $0.name == "My name" })
        let unmarked = try document.resolved(edits: corrections + owner.speakerIDs.map {
            edit(kind: .speakerOwner, targetID: $0, value: "false", modifiedAt: 12)
        })
        #expect(unmarked.ownerTurns.isEmpty)
        #expect(unmarked.unresolvedEditCount == 0)
        #expect(unmarked.transcript.turns.map(\.speakerID) == ["speaker-a", "owner", "speaker-b", "speaker-b"])
    }

    @Test("unused legacy owner rows are absent from the speaker list but remain assignment targets")
    func excludesUnusedRowsWithoutHidingActualSpeakers() throws {
        let document = try fixtureDocument(extraSpeakers: [
            MeetingSpeaker(id: "owner", name: "My name", isOwner: true),
            MeetingSpeaker(id: "unused", name: "Unused group", isOwner: false)
        ])
        let resolved = try document.resolved(edits: [])
        #expect(resolved.speakerIdentities.flatMap(\.speakerIDs) == ["speaker-a", "speaker-b"])
        #expect(resolved.speakerAssignmentChoices.filter { $0.isOwner }.first?.assignmentSpeakerID == "owner")
        #expect(resolved.transcript.speakers.count == 4)

        let noOwner = try fixtureDocument().resolved(edits: [])
        #expect(noOwner.speakerIdentities.count == 2)
        let virtual = try #require(noOwner.speakerAssignmentChoices.first { $0.isOwner })
        #expect(virtual.speakerIDs.isEmpty)
        #expect(virtual.assignmentSpeakerID == "owner")
    }

    @Test("unmarked canonical owner and a recognized owner have distinct display and assignment identities")
    func unmarkedCanonicalOwnerDoesNotCollideWithOwnerIdentity() throws {
        let document = try fixtureDocument(ownerSpeakerIDs: ["speaker-a"], extraSpeakers: [
            MeetingSpeaker(id: "owner", name: "Different person", isOwner: false)
        ])
        let resolved = try document.resolved(edits: [
            edit(kind: .turnSpeaker, targetID: "turn-2", value: "owner", modifiedAt: 10)
        ])
        #expect(resolved.speakerIdentities.count == 3)
        #expect(Set(resolved.speakerIdentities.map(\.id)).count == 3)
        let owner = try #require(resolved.speakerIdentity(for: "speaker-a"))
        #expect(owner.assignmentSpeakerID == "speaker-a")
        #expect(!owner.contains(speakerID: "owner"))
        #expect(resolved.speakerIdentity(for: "owner")?.isOwner == false)
    }

    @Test("document and edit validation enforce linkage backend values and encoded cap")
    func validatesDocumentAndEdits() throws {
        var document = try fixtureDocument()
        try document.validate(duration: 12)

        document.audioVersion = 3
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try document.validate(duration: 12)
        }

        let invalidStatus = edit(kind: .actionStatus, targetID: "action-1", value: "maybe", modifiedAt: 10)
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try invalidStatus.validate(recordingID: recordingID, audioVersion: 2)
        }

        let badTarget = edit(kind: .speakerName, targetID: "speaker-한", value: "Name", modifiedAt: 10)
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try badTarget.validate(recordingID: recordingID, audioVersion: 2)
        }

        let oversizedText = String(repeating: "A", count: 2_500)
        let oversizedTurns = (0..<1_900).map { index in
            TranscriptTurn(id: "large-\(index)", start: Double(index), end: Double(index) + 0.5,
                speakerID: nil, text: oversizedText)
        }
        let oversizedTranscript = MeetingTranscript(recordingID: recordingID, audioVersion: 2,
            transcriptionModelID: "openai/gpt-4o-transcribe:online", speakers: [], turns: oversizedTurns)
        let oversizedDocument = MeetingIntelligenceDocument(recordingID: recordingID, audioVersion: 2,
            modifiedAt: 20, mutationID: mutationA, projectName: "Project Apollo",
            transcript: oversizedTranscript, insights: nil, analysisModelID: "openrouter/analysis:model")
        #expect(throws: MeetingIntelligenceValidationError.self) {
            try oversizedDocument.validate(duration: 2_000)
        }
    }

    @Test("briefing builder filters project and current recording with cited latest first items")
    func buildsProjectBriefing() throws {
        let older = MeetingBriefingSource(recordingID: recordingID, title: "Older meeting", createdAt: Date(timeIntervalSince1970: 10),
            resolvedDocument: try fixtureDocument(projectName: "Design Review").resolved(edits: []))
        let otherProject = MeetingBriefingSource(recordingID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            title: "Other project", createdAt: Date(timeIntervalSince1970: 30),
            resolvedDocument: try fixtureDocument(projectName: "Sales").resolved(edits: []))
        let latestID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let latest = MeetingBriefingSource(recordingID: latestID, title: "Latest meeting", createdAt: Date(timeIntervalSince1970: 20),
            resolvedDocument: try fixtureDocument(recordingID: latestID, projectName: "Design Review").resolved(edits: []))

        let briefing = MeetingBriefingBuilder.build(projectName: "Design Review",
            sources: [older, otherProject, latest], excluding: nil)

        #expect(briefing.openActions.map(\.recordingTitle) == ["Latest meeting", "Older meeting"])
        #expect(briefing.unansweredQuestions.map(\.recordingID) == [latestID, recordingID])
        #expect(briefing.decisions.allSatisfy { !$0.turnIDs.isEmpty })

        let excludingLatest = MeetingBriefingBuilder.build(projectName: "Design Review",
            sources: [older, latest], excluding: latestID)
        #expect(excludingLatest.openActions.map(\.recordingID) == [recordingID])
    }

    private func fixtureDocument(recordingID: UUID? = nil, projectName: String = "Project Apollo", ownerSpeakerIDs: Set<String> = [], extraSpeakers: [MeetingSpeaker] = []) throws -> MeetingIntelligenceDocument {
        let id = recordingID ?? self.recordingID
        let transcript = MeetingTranscript(recordingID: id, audioVersion: 2,
            transcriptionModelID: "openai/gpt-4o-transcribe:online",
            speakers: [
                MeetingSpeaker(id: "speaker-a", name: "Speaker A", isOwner: ownerSpeakerIDs.contains("speaker-a")),
                MeetingSpeaker(id: "speaker-b", name: "Speaker B", isOwner: ownerSpeakerIDs.contains("speaker-b"))
            ] + extraSpeakers,
            turns: [
                TranscriptTurn(id: "turn-1", start: 0, end: 2, speakerID: "speaker-a", text: "I will send the draft tomorrow."),
                TranscriptTurn(id: "turn-2", start: 2, end: 4, speakerID: "speaker-b", text: "Can you review the budget?"),
                TranscriptTurn(id: "turn-3", start: 4, end: 6, speakerID: "speaker-b", text: "I will book the room."),
                TranscriptTurn(id: "turn-4", start: 6, end: 8, speakerID: "speaker-b", text: "Will we invite design?")
            ])
        let insights = MeetingInsights(actions: [
            MeetingAction(id: "action-1", kind: .commitment, text: "Send the draft", actorSpeakerID: "speaker-a",
                targetSpeakerID: nil, dueText: "tomorrow", evidenceTurnIDs: ["turn-1"]),
            MeetingAction(id: "action-2", kind: .request, text: "Review the budget", actorSpeakerID: "speaker-b",
                targetSpeakerID: "speaker-a", dueText: nil, evidenceTurnIDs: ["turn-2"]),
            MeetingAction(id: "action-3", kind: .commitment, text: "Book the room", actorSpeakerID: "speaker-b",
                targetSpeakerID: nil, dueText: nil, evidenceTurnIDs: ["turn-3"])
        ], questions: [
            MeetingQuestion(id: "question-1", question: "Will we invite design?", questionTurnIDs: ["turn-4"],
                answer: nil, answerTurnIDs: [], status: .unanswered)
        ], decisions: [
            MeetingDecision(id: "decision-1", topic: "Budget", status: .decided, steps: [
                MeetingDecisionStep(kind: .decision, text: "Review budget before launch", speakerID: "speaker-b",
                    evidenceTurnIDs: ["turn-2"])
            ])
        ])
        let document = MeetingIntelligenceDocument(recordingID: id, audioVersion: 2, modifiedAt: 20,
            mutationID: mutationA, projectName: projectName, transcript: transcript, insights: insights,
            actionStates: ["action-1": "open", "action-2": "done", "action-3": "done"],
            analysisModelID: "openrouter/analysis:model")
        try document.validate(duration: 12)
        return document
    }

    private func edit(kind: MeetingEditKind, targetID: String, value: String, modifiedAt: Int64) -> MeetingEdit {
        MeetingEdit(id: mutationB, recordingID: recordingID, audioVersion: 2, modifiedAt: modifiedAt,
            kind: kind, targetID: targetID, value: value)
    }
}
