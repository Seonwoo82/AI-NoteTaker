import Foundation

nonisolated struct MeetingIntelligenceDocument: Codable, Equatable, Sendable {
    static let maximumEncodedByteCount = 4 * 1_024 * 1_024

    let schemaVersion: Int
    let recordingID: UUID
    var audioVersion: Int
    let modifiedAt: Int64
    let mutationID: UUID
    var projectName: String
    let transcript: MeetingTranscript
    let insights: MeetingInsights?
    var actionStates: [String: String]
    let analysisModelID: String

    init(schemaVersion: Int = 1, recordingID: UUID, audioVersion: Int, modifiedAt: Int64, mutationID: UUID, projectName: String, transcript: MeetingTranscript, insights: MeetingInsights?, actionStates: [String: String] = [:], analysisModelID: String) {
        self.schemaVersion = schemaVersion
        self.recordingID = recordingID
        self.audioVersion = audioVersion
        self.modifiedAt = modifiedAt
        self.mutationID = mutationID
        self.projectName = projectName
        self.transcript = transcript
        self.insights = insights
        self.actionStates = actionStates
        self.analysisModelID = analysisModelID
    }

    func validate(duration: Double) throws {
        guard schemaVersion == 1 else { throw MeetingIntelligenceValidationError(message: "Unsupported meeting intelligence schema version.") }
        guard audioVersion >= 1, transcript.recordingID == recordingID, transcript.audioVersion == audioVersion else {
            throw MeetingIntelligenceValidationError(message: "Meeting intelligence document is not linked to its transcript.")
        }
        try MeetingWorkspaceValidation.validateTimestamp(modifiedAt)
        try MeetingWorkspaceValidation.validateProfileText(projectName, label: "project name", allowEmpty: true)
        try MeetingWorkspaceValidation.validateProfileText(analysisModelID, label: "analysis model ID", allowEmpty: false)
        try transcript.validate(duration: duration)
        if let insights {
            try insights.validate(transcript: transcript)
            let actionIDs = Set(insights.actions.map(\.id))
            for id in actionStates.keys where !actionIDs.contains(id) {
                throw MeetingIntelligenceValidationError(message: "Unknown action status target.")
            }
        } else if !actionStates.isEmpty {
            throw MeetingIntelligenceValidationError(message: "Action states require meeting insights.")
        }
        for (id, state) in actionStates {
            try MeetingWorkspaceValidation.validateTargetID(id, allowEmpty: false)
            guard MeetingActionStatus(rawValue: state) != nil else {
                throw MeetingIntelligenceValidationError(message: "Invalid action status.")
            }
        }
        let size = try MeetingWorkspaceValidation.encodedSize(self)
        guard size <= Self.maximumEncodedByteCount else {
            throw MeetingIntelligenceValidationError(message: "Meeting intelligence document is too large.")
        }
    }

    func resolved(edits: [MeetingEdit]) throws -> MeetingResolvedDocument {
        try MeetingWorkspaceResolver.resolve(document: self, edits: edits)
    }
}

nonisolated enum MeetingEditKind: String, Codable, Equatable, Sendable {
    case speakerName
    case speakerOwner
    case turnSpeaker
    case actionStatus
    case projectName
}

nonisolated struct MeetingEdit: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: UUID
    let recordingID: UUID
    let audioVersion: Int
    let modifiedAt: Int64
    let kind: MeetingEditKind
    let targetID: String
    let value: String

    init(schemaVersion: Int = 1, id: UUID, recordingID: UUID, audioVersion: Int, modifiedAt: Int64, kind: MeetingEditKind, targetID: String, value: String) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.recordingID = recordingID
        self.audioVersion = audioVersion
        self.modifiedAt = modifiedAt
        self.kind = kind
        self.targetID = targetID
        self.value = value
    }

    func validate(recordingID expectedRecordingID: UUID, audioVersion expectedAudioVersion: Int) throws {
        guard schemaVersion == 1 else { throw MeetingIntelligenceValidationError(message: "Unsupported meeting edit schema version.") }
        guard recordingID == expectedRecordingID, audioVersion == expectedAudioVersion, audioVersion >= 1 else {
            throw MeetingIntelligenceValidationError(message: "Meeting edit is not linked to this document.")
        }
        try MeetingWorkspaceValidation.validateTimestamp(modifiedAt)
        try MeetingWorkspaceValidation.validateTargetID(targetID, allowEmpty: kind == .projectName)
        if kind == .projectName, !targetID.isEmpty {
            throw MeetingIntelligenceValidationError(message: "Project name edits must use an empty target.")
        }
        try MeetingWorkspaceValidation.validateEditValue(value, kind: kind)
    }

    nonisolated struct Entry: Codable, Equatable, Sendable {
        let sequence: Int64
        let edit: MeetingEdit
    }

    nonisolated struct Page: Codable, Equatable, Sendable {
        let entries: [Entry]
        let nextCursor: Int64?
    }
}

typealias MeetingEditEntry = MeetingEdit.Entry
typealias MeetingEditPage = MeetingEdit.Page

nonisolated enum MeetingActionStatus: String, Codable, Equatable, Sendable {
    case open
    case done
    case dismissed
}

nonisolated struct MeetingResolvedDocument: Equatable, Sendable {
    let source: MeetingIntelligenceDocument
    let transcript: MeetingTranscript
    let insights: MeetingInsights?
    let projectName: String
    let actionStates: [String: String]
    let unresolvedEditCount: Int

    var ownerTurns: [TranscriptTurn] {
        let ownerIDs = self.ownerIDs
        guard !ownerIDs.isEmpty else { return [] }
        return transcript.turns.filter { turn in
            turn.speakerID.map { ownerIDs.contains($0) } ?? false
        }
    }

    var myCommitments: [MeetingAction] {
        guard let insights else { return [] }
        let ownerIDs = self.ownerIDs
        guard !ownerIDs.isEmpty else { return [] }
        return insights.actions.filter { action in
            guard action.kind == .commitment else { return false }
            if let actorSpeakerID = action.actorSpeakerID, ownerIDs.contains(actorSpeakerID) { return true }
            guard let actorSpeakerID = action.actorSpeakerID else { return false }
            return action.evidenceTurnIDs.contains { turnID in
                sourceTurnSpeakerID(turnID) == actorSpeakerID
                    && resolvedTurnSpeakerID(turnID).map { ownerIDs.contains($0) } == true
            }
        }
    }

    var receivedRequests: [MeetingAction] {
        guard let insights else { return [] }
        let ownerIDs = self.ownerIDs
        guard !ownerIDs.isEmpty else { return [] }
        return insights.actions.filter { action in
            action.kind == .request
                && action.targetSpeakerID.map { ownerIDs.contains($0) } == true
        }
    }

    func evidenceTurns(for ids: [String]) -> [TranscriptTurn] {
        let requested = Set(ids)
        return transcript.turns.filter { requested.contains($0.id) }
    }

    func actionStatus(for id: String) -> MeetingActionStatus {
        actionStates[id].flatMap(MeetingActionStatus.init(rawValue:)) ?? .open
    }

    private var ownerIDs: Set<String> {
        Set(transcript.speakers.filter(\.isOwner).map(\.id))
    }

    private func sourceTurnSpeakerID(_ id: String) -> String? {
        source.transcript.turns.first(where: { $0.id == id })?.speakerID
    }

    private func resolvedTurnSpeakerID(_ id: String) -> String? {
        transcript.turns.first(where: { $0.id == id })?.speakerID
    }
}

nonisolated struct MeetingBriefingSource: Equatable, Sendable {
    let recordingID: UUID
    let title: String
    let createdAt: Date
    let resolvedDocument: MeetingResolvedDocument
}

nonisolated struct MeetingBriefingItem: Identifiable, Equatable, Sendable {
    let id: String
    let recordingID: UUID
    let recordingTitle: String
    let text: String
    let turnIDs: [String]
}

nonisolated struct MeetingBriefing: Equatable, Sendable {
    let decisions: [MeetingBriefingItem]
    let openActions: [MeetingBriefingItem]
    let unansweredQuestions: [MeetingBriefingItem]
}

nonisolated enum MeetingBriefingBuilder {
    static let maximumItemsPerSection = 12

    static func build(projectName: String, sources: [MeetingBriefingSource], excluding excludedID: UUID? = nil) -> MeetingBriefing {
        let normalizedProject = MeetingWorkspaceValidation.normalized(projectName)
        let filtered = sources
            .filter { source in
                source.recordingID != excludedID
                    && MeetingWorkspaceValidation.normalized(source.resolvedDocument.projectName) == normalizedProject
            }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.recordingID.uuidString > $1.recordingID.uuidString
            }

        var decisions: [MeetingBriefingItem] = []
        var openActions: [MeetingBriefingItem] = []
        var unansweredQuestions: [MeetingBriefingItem] = []

        for source in filtered {
            guard let insights = source.resolvedDocument.insights else { continue }
            for decision in insights.decisions where decisions.count < maximumItemsPerSection {
                let turnIDs = decision.steps.flatMap(\.evidenceTurnIDs)
                decisions.append(MeetingBriefingItem(id: "\(source.recordingID.uuidString):decision:\(decision.id)",
                    recordingID: source.recordingID, recordingTitle: source.title,
                    text: "\(decision.topic): \(decision.steps.last?.text ?? decision.status.rawValue)",
                    turnIDs: Array(dictOrderedUnique: turnIDs)))
            }
            for action in insights.actions where openActions.count < maximumItemsPerSection {
                guard source.resolvedDocument.actionStatus(for: action.id) == .open else { continue }
                openActions.append(MeetingBriefingItem(id: "\(source.recordingID.uuidString):action:\(action.id)",
                    recordingID: source.recordingID, recordingTitle: source.title,
                    text: action.text, turnIDs: action.evidenceTurnIDs))
            }
            for question in insights.questions where unansweredQuestions.count < maximumItemsPerSection {
                guard question.status == .unanswered || question.status == .uncertain else { continue }
                unansweredQuestions.append(MeetingBriefingItem(id: "\(source.recordingID.uuidString):question:\(question.id)",
                    recordingID: source.recordingID, recordingTitle: source.title,
                    text: question.question, turnIDs: question.questionTurnIDs))
            }
        }

        return MeetingBriefing(decisions: decisions, openActions: openActions, unansweredQuestions: unansweredQuestions)
    }
}

private nonisolated enum MeetingWorkspaceResolver {
    private struct FieldKey: Hashable {
        let kind: MeetingEditKind
        let targetID: String
    }

    static func resolve(document: MeetingIntelligenceDocument, edits: [MeetingEdit]) throws -> MeetingResolvedDocument {
        try document.validate(duration: document.transcript.turns.last?.end ?? 0)
        var latest: [FieldKey: MeetingEdit] = [:]
        var unresolved = 0
        for edit in edits {
            do {
                try edit.validate(recordingID: document.recordingID, audioVersion: document.audioVersion)
            } catch {
                unresolved += 1
                continue
            }
            let key = FieldKey(kind: edit.kind, targetID: edit.targetID)
            if let existing = latest[key], !edit.wins(over: existing) {
                continue
            }
            latest[key] = edit
        }

        var speakers = document.transcript.speakers
        let speakerIndexByID = Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($0.element.id, $0.offset) })
        var turns = document.transcript.turns
        let speakerIDs = Set(speakers.map(\.id))
        let actionIDs = Set(document.insights?.actions.map(\.id) ?? [])
        var states = document.actionStates
        var projectName = document.projectName

        for edit in latest.values.sorted(by: MeetingWorkspaceValidation.editSort) {
            switch edit.kind {
            case .speakerName:
                guard let index = speakerIndexByID[edit.targetID] else {
                    unresolved += 1
                    continue
                }
                let speaker = speakers[index]
                speakers[index] = MeetingSpeaker(id: speaker.id, name: edit.value, isOwner: speaker.isOwner, manuallyAssigned: true)
            case .speakerOwner:
                guard let index = speakerIndexByID[edit.targetID], let isOwner = Bool(edit.value) else {
                    unresolved += 1
                    continue
                }
                let speaker = speakers[index]
                speakers[index] = MeetingSpeaker(id: speaker.id, name: speaker.name,
                    isOwner: isOwner, manuallyAssigned: true)
            case .turnSpeaker:
                guard let turnIndex = turns.firstIndex(where: { $0.id == edit.targetID }) else {
                    unresolved += 1
                    continue
                }
                let speakerID = edit.value.isEmpty ? nil : edit.value
                guard speakerID == nil || speakerIDs.contains(speakerID!) else {
                    unresolved += 1
                    continue
                }
                let turn = turns[turnIndex]
                turns[turnIndex] = TranscriptTurn(id: turn.id, start: turn.start, end: turn.end,
                    speakerID: speakerID, text: turn.text)
            case .actionStatus:
                guard actionIDs.contains(edit.targetID), MeetingActionStatus(rawValue: edit.value) != nil else {
                    unresolved += 1
                    continue
                }
                states[edit.targetID] = edit.value
            case .projectName:
                projectName = edit.value
            }
        }

        let transcript = MeetingTranscript(schemaVersion: document.transcript.schemaVersion,
            recordingID: document.transcript.recordingID, audioVersion: document.transcript.audioVersion,
            transcriptionModelID: document.transcript.transcriptionModelID, speakers: speakers, turns: turns)
        return MeetingResolvedDocument(source: document, transcript: transcript, insights: document.insights,
            projectName: projectName, actionStates: states, unresolvedEditCount: unresolved)
    }
}

private nonisolated extension MeetingEdit {
    func wins(over other: MeetingEdit) -> Bool {
        modifiedAt > other.modifiedAt || (modifiedAt == other.modifiedAt && id.uuidString > other.id.uuidString)
    }
}

private nonisolated enum MeetingWorkspaceValidation {
    static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    static func validateTimestamp(_ value: Int64) throws {
        guard value >= 0, value <= maxSafeInteger else {
            throw MeetingIntelligenceValidationError(message: "Invalid meeting intelligence timestamp.")
        }
    }

    static func validateProfileText(_ value: String, label: String, allowEmpty: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (allowEmpty || !trimmed.isEmpty), value.utf8.count <= 256 else {
            throw MeetingIntelligenceValidationError(message: "Invalid \(label).")
        }
    }

    static func validateTargetID(_ value: String, allowEmpty: Bool) throws {
        guard (allowEmpty || !value.isEmpty), value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else {
            throw MeetingIntelligenceValidationError(message: "Invalid meeting edit target.")
        }
    }

    static func validateEditValue(_ value: String, kind: MeetingEditKind) throws {
        guard value.utf8.count <= 256 else { throw MeetingIntelligenceValidationError(message: "Meeting edit value is too large.") }
        switch kind {
        case .speakerOwner:
            guard value == "true" || value == "false" else {
                throw MeetingIntelligenceValidationError(message: "Invalid speaker owner value.")
            }
        case .actionStatus:
            guard MeetingActionStatus(rawValue: value) != nil else {
                throw MeetingIntelligenceValidationError(message: "Invalid action status.")
            }
        case .speakerName:
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingIntelligenceValidationError(message: "Meeting edit value cannot be empty.")
            }
        case .projectName:
            break
        case .turnSpeaker:
            try validateTargetID(value, allowEmpty: true)
        }
    }

    static func encodedSize<Value: Encodable>(_ value: Value) throws -> Int {
        try JSONEncoder().encode(value).count
    }

    static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    static func editSort(_ lhs: MeetingEdit, _ rhs: MeetingEdit) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

nonisolated private extension Array where Element: Hashable {
    init(dictOrderedUnique values: [Element]) {
        var seen = Set<Element>()
        self = values.filter { seen.insert($0).inserted }
    }
}
