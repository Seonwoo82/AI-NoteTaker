import Foundation

nonisolated struct MeetingSpeaker: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let isOwner: Bool
    var manuallyAssigned: Bool = false

    init(id: String, name: String, isOwner: Bool, manuallyAssigned: Bool = false) {
        self.id = id
        self.name = name
        self.isOwner = isOwner
        self.manuallyAssigned = manuallyAssigned
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        isOwner = try container.decode(Bool.self, forKey: .isOwner)
        manuallyAssigned = try container.decodeIfPresent(Bool.self, forKey: .manuallyAssigned) ?? false
    }
}

nonisolated struct TranscriptTurn: Codable, Equatable, Sendable {
    let id: String
    let start: Double
    let end: Double
    let speakerID: String?
    let text: String
}

nonisolated struct MeetingTranscript: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    let recordingID: UUID
    let audioVersion: Int
    let transcriptionModelID: String
    let speakers: [MeetingSpeaker]
    let turns: [TranscriptTurn]

    init(schemaVersion: Int = 1, recordingID: UUID, audioVersion: Int, transcriptionModelID: String, speakers: [MeetingSpeaker], turns: [TranscriptTurn]) {
        self.schemaVersion = schemaVersion
        self.recordingID = recordingID
        self.audioVersion = audioVersion
        self.transcriptionModelID = transcriptionModelID
        self.speakers = speakers
        self.turns = turns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        recordingID = try container.decode(UUID.self, forKey: .recordingID)
        audioVersion = try container.decode(Int.self, forKey: .audioVersion)
        transcriptionModelID = try container.decode(String.self, forKey: .transcriptionModelID)
        speakers = try container.decode([MeetingSpeaker].self, forKey: .speakers)
        turns = try container.decode([TranscriptTurn].self, forKey: .turns)
    }
}

nonisolated enum MeetingActionKind: String, Codable, Equatable, Sendable {
    case commitment
    case request
}

nonisolated struct MeetingAction: Codable, Equatable, Sendable {
    let id: String
    let kind: MeetingActionKind
    let text: String
    let actorSpeakerID: String?
    let targetSpeakerID: String?
    let dueText: String?
    let evidenceTurnIDs: [String]
}

nonisolated enum MeetingQuestionStatus: String, Codable, Equatable, Sendable {
    case answered
    case partial
    case unanswered
    case uncertain
}

nonisolated struct MeetingQuestion: Codable, Equatable, Sendable {
    let id: String
    let question: String
    let questionTurnIDs: [String]
    let answer: String?
    let answerTurnIDs: [String]
    let status: MeetingQuestionStatus
}

nonisolated enum MeetingDecisionStepKind: String, Codable, Equatable, Sendable {
    case proposal
    case concern
    case decision
    case deferred
    case revised
}

nonisolated struct MeetingDecisionStep: Codable, Equatable, Sendable {
    let kind: MeetingDecisionStepKind
    let text: String
    let speakerID: String?
    let evidenceTurnIDs: [String]
}

nonisolated enum MeetingDecisionStatus: String, Codable, Equatable, Sendable {
    case decided
    case deferred
    case unresolved
}

nonisolated struct MeetingDecision: Codable, Equatable, Sendable {
    let id: String
    let topic: String
    let status: MeetingDecisionStatus
    let steps: [MeetingDecisionStep]
}

nonisolated struct MeetingInsights: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    let actions: [MeetingAction]
    let questions: [MeetingQuestion]
    let decisions: [MeetingDecision]

    init(schemaVersion: Int = 1, actions: [MeetingAction] = [], questions: [MeetingQuestion] = [], decisions: [MeetingDecision] = []) {
        self.schemaVersion = schemaVersion
        self.actions = actions
        self.questions = questions
        self.decisions = decisions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        actions = try container.decode([MeetingAction].self, forKey: .actions)
        questions = try container.decode([MeetingQuestion].self, forKey: .questions)
        decisions = try container.decode([MeetingDecision].self, forKey: .decisions)
    }
}

nonisolated struct MeetingIntelligenceValidationError: LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated extension MeetingTranscript {
    func validate(duration: Double) throws {
        try MeetingIntelligenceValidator.validate(self, duration: duration)
    }
}

nonisolated extension MeetingInsights {
    func validate(transcript: MeetingTranscript) throws {
        try MeetingIntelligenceValidator.validate(self, transcript: transcript)
    }
}

private nonisolated enum MeetingIntelligenceValidator {
    static let maxIDLength = 128
    static let maxModelIDLength = 256
    static let maxSpeakerCount = 64
    static let maxTurnCount = 20_000
    static let maxActionCount = 200
    static let maxQuestionCount = 200
    static let maxDecisionCount = 200
    static let maxDecisionStepCount = 30
    static let maxTextLength = 4_000

    static func validate(_ transcript: MeetingTranscript, duration: Double) throws {
        guard transcript.schemaVersion == 1 else { throw error("Unsupported transcript schema version.") }
        guard transcript.audioVersion >= 1 else { throw error("Invalid audio version.") }
        guard duration.isFinite, duration >= 0 else { throw error("Invalid recording duration.") }
        try validateModelID(transcript.transcriptionModelID)
        guard transcript.speakers.count <= maxSpeakerCount else { throw error("Too many speakers.") }
        guard transcript.turns.count <= maxTurnCount else { throw error("Too many transcript turns.") }

        var speakerIDs = Set<String>()
        for speaker in transcript.speakers {
            try validateID(speaker.id, label: "speaker ID")
            try validateText(speaker.name, label: "speaker name")
            guard speakerIDs.insert(speaker.id).inserted else { throw error("Duplicate speaker ID: \(speaker.id).") }
        }

        var turnIDs = Set<String>()
        var previousStart = -Double.infinity
        for turn in transcript.turns {
            try validateID(turn.id, label: "turn ID")
            try validateText(turn.text, label: "turn text")
            guard turnIDs.insert(turn.id).inserted else { throw error("Duplicate turn ID: \(turn.id).") }
            guard turn.start.isFinite, turn.end.isFinite else { throw error("Transcript turn has a nonfinite time.") }
            guard turn.start >= 0, turn.end <= duration, turn.start < turn.end else {
                throw error("Transcript turn has an out-of-range time.")
            }
            guard turn.start >= previousStart else { throw error("Transcript turns must be chronological.") }
            previousStart = turn.start
            if let speakerID = turn.speakerID, !speakerIDs.contains(speakerID) {
                throw error("Unknown speaker ID: \(speakerID).")
            }
        }
    }

    static func validate(_ insights: MeetingInsights, transcript: MeetingTranscript) throws {
        guard insights.schemaVersion == 1 else { throw error("Unsupported insights schema version.") }
        guard insights.actions.count <= maxActionCount else { throw error("Too many actions.") }
        guard insights.questions.count <= maxQuestionCount else { throw error("Too many questions.") }
        guard insights.decisions.count <= maxDecisionCount else { throw error("Too many decisions.") }

        let speakerIDs = Set(transcript.speakers.map(\.id))
        let turnsByID = Dictionary(uniqueKeysWithValues: transcript.turns.map { ($0.id, $0) })
        var usedIDs = Set<String>()

        for action in insights.actions {
            try validateUniqueArtifactID(action.id, usedIDs: &usedIDs)
            try validateText(action.text, label: "action text")
            try validateKnownSpeaker(action.actorSpeakerID, speakerIDs: speakerIDs)
            try validateKnownSpeaker(action.targetSpeakerID, speakerIDs: speakerIDs)
            try validateEvidence(action.evidenceTurnIDs, turnsByID: turnsByID, label: "action evidence")
            if let dueText = action.dueText {
                try validateText(dueText, label: "due text")
                guard evidence(action.evidenceTurnIDs, in: turnsByID, contains: dueText) else {
                    throw error("Due text must appear in a cited transcript turn.")
                }
            }
        }

        for question in insights.questions {
            try validateUniqueArtifactID(question.id, usedIDs: &usedIDs)
            try validateText(question.question, label: "question text")
            try validateEvidence(question.questionTurnIDs, turnsByID: turnsByID, label: "question evidence")
            if let answer = question.answer {
                try validateText(answer, label: "answer text")
            }
            try validateQuestionAnswerState(question)
            try validateEvidence(question.answerTurnIDs, turnsByID: turnsByID, allowEmpty: question.answerTurnIDs.isEmpty, label: "answer evidence")
        }

        for decision in insights.decisions {
            try validateUniqueArtifactID(decision.id, usedIDs: &usedIDs)
            try validateText(decision.topic, label: "decision topic")
            guard !decision.steps.isEmpty else { throw error("Decision requires at least one evidence-backed step.") }
            guard decision.steps.count <= maxDecisionStepCount else { throw error("Too many decision steps.") }
            for step in decision.steps {
                try validateText(step.text, label: "decision step text")
                try validateKnownSpeaker(step.speakerID, speakerIDs: speakerIDs)
                try validateEvidence(step.evidenceTurnIDs, turnsByID: turnsByID, label: "decision evidence")
            }
        }
    }

    private static func validateQuestionAnswerState(_ question: MeetingQuestion) throws {
        switch question.status {
        case .answered, .partial:
            guard question.answer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  !question.answerTurnIDs.isEmpty else {
                throw error("Answered questions require answer text and evidence.")
            }
        case .unanswered:
            guard question.answer == nil, question.answerTurnIDs.isEmpty else {
                throw error("Unanswered questions cannot include answer evidence.")
            }
        case .uncertain:
            if question.answer != nil {
                guard !question.answerTurnIDs.isEmpty else {
                    throw error("Uncertain answered questions require evidence.")
                }
            }
        }
    }

    private static func validateUniqueArtifactID(_ id: String, usedIDs: inout Set<String>) throws {
        try validateID(id, label: "artifact ID")
        guard usedIDs.insert(id).inserted else { throw error("Duplicate insight ID: \(id).") }
    }

    private static func validateEvidence(_ ids: [String], turnsByID: [String: TranscriptTurn], allowEmpty: Bool = false, label: String) throws {
        if allowEmpty, ids.isEmpty { return }
        guard !ids.isEmpty else { throw error("\(label) is required.") }
        var seen = Set<String>()
        for id in ids {
            try validateID(id, label: label)
            guard seen.insert(id).inserted else { throw error("Duplicate evidence turn ID: \(id).") }
            guard turnsByID[id] != nil else { throw error("Unknown evidence turn ID: \(id).") }
        }
    }

    private static func validateKnownSpeaker(_ id: String?, speakerIDs: Set<String>) throws {
        guard let id else { return }
        try validateID(id, label: "speaker ID")
        guard speakerIDs.contains(id) else { throw error("Unknown speaker ID: \(id).") }
    }

    private static func validateID(_ id: String, label: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == id, id.count <= maxIDLength else {
            throw error("Invalid \(label).")
        }
    }

    private static func validateModelID(_ id: String) throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == id, id.count <= maxModelIDLength else {
            throw error("Invalid transcription model ID.")
        }
    }

    private static func validateText(_ text: String, label: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTextLength else { throw error("Invalid \(label).") }
    }

    private static func evidence(_ ids: [String], in turnsByID: [String: TranscriptTurn], contains needle: String) -> Bool {
        let normalizedNeedle = normalizeForEvidenceMatch(needle)
        guard !normalizedNeedle.isEmpty else { return false }
        return ids.contains { id in
            guard let text = turnsByID[id]?.text else { return false }
            return normalizeForEvidenceMatch(text).contains(normalizedNeedle)
        }
    }

    private static func normalizeForEvidenceMatch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func error(_ message: String) -> MeetingIntelligenceValidationError {
        MeetingIntelligenceValidationError(message: message)
    }
}
