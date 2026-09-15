import CryptoKit
import Foundation

nonisolated struct OwnerAttributionSidecar: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let recordingID: UUID
    let audioVersion: Int
    let documentRevision: String
    let embeddingModelID: String
    let profileFingerprint: String
    let speakers: [CachedAcousticSpeaker]
    let turnRawSpeakerIDs: [String: String]
}

nonisolated struct CachedAcousticSpeaker: Codable, Equatable, Sendable {
    let id: String
    let embedding: [Float]

    init(_ speaker: AcousticSpeaker) {
        id = speaker.id
        embedding = speaker.embedding
    }

    var acousticSpeaker: AcousticSpeaker {
        AcousticSpeaker(id: id, embedding: embedding)
    }
}

nonisolated struct OwnerAttributionResult: Equatable, Sendable {
    let document: MeetingIntelligenceDocument
    let sidecar: OwnerAttributionSidecar
    let changed: Bool
}

nonisolated enum OwnerAttribution {
    static func reapply(
        document: MeetingIntelligenceDocument,
        documentData: Data,
        diarization: AcousticDiarization,
        profile: MeetingUserProfile,
        localVoice: LocalVoiceProfile?,
        embeddingModelID: String,
        policy: OwnerVoicePolicy = OwnerVoicePolicy()
    ) throws -> OwnerAttributionResult {
        try reapply(document: document, documentRevision: sha256Hex(documentData),
            speakers: diarization.speakers, rawSpeakerIDByTurnID: rawSpeakerIDsByTurn(in: document.transcript, diarization: diarization),
            profile: profile, localVoice: localVoice, embeddingModelID: embeddingModelID, policy: policy)
    }

    static func reapply(
        document: MeetingIntelligenceDocument,
        sidecar: OwnerAttributionSidecar,
        profile: MeetingUserProfile,
        localVoice: LocalVoiceProfile?,
        policy: OwnerVoicePolicy = OwnerVoicePolicy()
    ) throws -> OwnerAttributionResult {
        try reapply(document: document, documentRevision: sidecar.documentRevision,
            speakers: sidecar.speakers.map(\.acousticSpeaker), rawSpeakerIDByTurnID: sidecar.turnRawSpeakerIDs,
            profile: profile, localVoice: localVoice, embeddingModelID: sidecar.embeddingModelID, policy: policy)
    }

    static func sidecarIsReusable(_ sidecar: OwnerAttributionSidecar, for document: MeetingIntelligenceDocument, documentData: Data, embeddingModelID: String) -> Bool {
        sidecar.schemaVersion == 1
            && sidecar.recordingID == document.recordingID
            && sidecar.audioVersion == document.audioVersion
            && sidecar.documentRevision == sha256Hex(documentData)
            && sidecar.embeddingModelID == embeddingModelID
            && sidecarHasValidContent(sidecar, document: document)
    }

    static func profileFingerprint(_ voice: LocalVoiceProfile?) -> String {
        guard let voice else { return "none" }
        var hasher = SHA256()
        hasher.update(data: Data(voice.modelID.utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data("\(voice.enrolledAt.timeIntervalSince1970)".utf8))
        hasher.update(data: Data("|".utf8))
        hasher.update(data: Data("\(voice.sampleDuration)".utf8))
        for value in voice.embedding {
            var bits = value.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { hasher.update(bufferPointer: $0) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func reapply(
        document: MeetingIntelligenceDocument,
        documentRevision: String,
        speakers acousticSpeakers: [AcousticSpeaker],
        rawSpeakerIDByTurnID: [String: String],
        profile: MeetingUserProfile,
        localVoice: LocalVoiceProfile?,
        embeddingModelID: String,
        policy: OwnerVoicePolicy
    ) throws -> OwnerAttributionResult {
        let ownerName = displayOwnerName(profile.displayName)
        let previousSpeakersByID = Dictionary(uniqueKeysWithValues: document.transcript.speakers.map { ($0.id, $0) })
        let newSpeakerByRawID = mappedSpeakers(acousticSpeakers: acousticSpeakers,
            localVoice: localVoice, embeddingModelID: embeddingModelID,
            ownerName: ownerName, previousSpeakersByID: previousSpeakersByID,
            policy: policy)
        var usedSpeakerIDs = Set<String>()
        var newTurns: [TranscriptTurn] = []
        var oldToNewCandidates: [String: Set<String>] = [:]
        for turn in document.transcript.turns {
            let newSpeakerID = rawSpeakerIDByTurnID[turn.id].flatMap { newSpeakerByRawID[$0]?.id }
            if let newSpeakerID { usedSpeakerIDs.insert(newSpeakerID) }
            if let oldSpeakerID = turn.speakerID, let newSpeakerID {
                oldToNewCandidates[oldSpeakerID, default: []].insert(newSpeakerID)
            }
            newTurns.append(TranscriptTurn(id: turn.id, start: turn.start, end: turn.end,
                speakerID: newSpeakerID, text: turn.text))
        }

        let speakerIDsToPublish = usedSpeakerIDs
        var newSpeakers = orderedPublishedSpeakers(from: newSpeakerByRawID.values,
            speakerIDsToPublish: speakerIDsToPublish,
            previousOrder: document.transcript.speakers.map(\.id))
        ensureSpeakerNames(previousSpeakersByID: previousSpeakersByID, speakers: &newSpeakers)

        let newTranscript = MeetingTranscript(schemaVersion: document.transcript.schemaVersion,
            recordingID: document.transcript.recordingID,
            audioVersion: document.transcript.audioVersion,
            transcriptionModelID: document.transcript.transcriptionModelID,
            speakers: newSpeakers,
            turns: newTurns)
        let knownSpeakerIDs = Set(newSpeakers.map(\.id))
        let oldToNew = oldToNewCandidates.compactMapValues { candidates -> String? in
            candidates.count == 1 ? candidates.first : nil
        }
        let newInsights = document.insights.map {
            remap($0, oldToNew: oldToNew, knownSpeakerIDs: knownSpeakerIDs)
        }
        let newDocument = MeetingIntelligenceDocument(schemaVersion: document.schemaVersion,
            recordingID: document.recordingID,
            audioVersion: document.audioVersion,
            modifiedAt: document.modifiedAt,
            mutationID: document.mutationID,
            projectName: document.projectName,
            transcript: newTranscript,
            insights: newInsights,
            actionStates: document.actionStates,
            analysisModelID: document.analysisModelID)
        let sidecar = OwnerAttributionSidecar(recordingID: document.recordingID,
            audioVersion: document.audioVersion,
            documentRevision: documentRevision,
            embeddingModelID: embeddingModelID,
            profileFingerprint: profileFingerprint(localVoice),
            speakers: acousticSpeakers.map(CachedAcousticSpeaker.init),
            turnRawSpeakerIDs: rawSpeakerIDByTurnID)
        return OwnerAttributionResult(document: newDocument, sidecar: sidecar,
            changed: newDocument != document)
    }

    private static func rawSpeakerIDsByTurn(in transcript: MeetingTranscript, diarization: AcousticDiarization) -> [String: String] {
        var result: [String: String] = [:]
        for turn in transcript.turns {
            if let rawID = rawSpeakerID(start: turn.start, end: turn.end, diarization: diarization) {
                result[turn.id] = rawID
            }
        }
        return result
    }

    private static func rawSpeakerID(start: Double, end: Double, diarization: AcousticDiarization) -> String? {
        guard !diarization.spans.contains(where: { $0.isOverlap && overlap(start, end, $0.start, $0.end) > 0 }) else {
            return nil
        }
        let candidates = Set(diarization.spans.compactMap { span -> String? in
            guard let speakerID = span.speakerID,
                  diarization.speakers.contains(where: { $0.id == speakerID }),
                  overlap(start, end, span.start, span.end) > 0 else { return nil }
            return speakerID
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func mappedSpeakers(
        acousticSpeakers: [AcousticSpeaker],
        localVoice: LocalVoiceProfile?,
        embeddingModelID: String,
        ownerName: String,
        previousSpeakersByID: [String: MeetingSpeaker],
        policy: OwnerVoicePolicy
    ) -> [String: MeetingSpeaker] {
        var usedIDs = Set<String>()
        var result: [String: MeetingSpeaker] = [:]
        for (index, speaker) in acousticSpeakers.enumerated() {
            let isOwner = localVoice.map {
                policy.classify(embedding: speaker.embedding, profile: $0, modelID: embeddingModelID) == .owner
            } ?? false
            let id = uniqueSpeakerID(for: speaker.id, usedIDs: &usedIDs)
            let previous = previousSpeakersByID[id]
            let fallbackName = isOwner ? (ownerName.isEmpty ? "Me" : ownerName) : "Speaker \(index + 1)"
            result[speaker.id] = MeetingSpeaker(id: id,
                name: isOwner ? (ownerName.isEmpty ? (previous?.name ?? "Me") : ownerName) : (previous?.name ?? fallbackName),
                isOwner: isOwner,
                manuallyAssigned: previous?.manuallyAssigned ?? false)
        }
        return result
    }

    private static func orderedPublishedSpeakers(
        from mappedSpeakers: Dictionary<String, MeetingSpeaker>.Values,
        speakerIDsToPublish: Set<String>,
        previousOrder: [String]
    ) -> [MeetingSpeaker] {
        var byID = Dictionary(grouping: mappedSpeakers, by: \.id).compactMapValues(\.first)
        var result: [MeetingSpeaker] = []
        for id in previousOrder where speakerIDsToPublish.contains(id) {
            guard let speaker = byID[id] else { continue }
            result.append(speaker)
            byID[id] = nil
        }
        for id in speakerIDsToPublish.sorted() where !result.contains(where: { $0.id == id }) {
            if let speaker = byID[id] { result.append(speaker) }
        }
        return result
    }

    private static func sidecarHasValidContent(_ sidecar: OwnerAttributionSidecar, document: MeetingIntelligenceDocument) -> Bool {
        let rawIDs = sidecar.speakers.map(\.id)
        guard Set(rawIDs).count == rawIDs.count else { return false }
        guard sidecar.speakers.allSatisfy({ speaker in
            speaker.embedding.count <= 4_096
                && speaker.embedding.allSatisfy(\.isFinite)
        }) else { return false }
        let turnIDs = Set(document.transcript.turns.map(\.id))
        guard Set(sidecar.turnRawSpeakerIDs.keys).isSubset(of: turnIDs) else { return false }
        guard Set(sidecar.turnRawSpeakerIDs.values).isSubset(of: Set(rawIDs)) else { return false }
        return true
    }

    private static func ensureSpeakerNames(previousSpeakersByID: [String: MeetingSpeaker], speakers: inout [MeetingSpeaker]) {
        for index in speakers.indices {
            let speaker = speakers[index]
            guard speaker.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let previous = previousSpeakersByID[speaker.id] else { continue }
            speakers[index] = MeetingSpeaker(id: speaker.id, name: previous.name,
                isOwner: speaker.isOwner, manuallyAssigned: speaker.manuallyAssigned)
        }
    }

    private static func remap(_ insights: MeetingInsights, oldToNew: [String: String], knownSpeakerIDs: Set<String>) -> MeetingInsights {
        MeetingInsights(schemaVersion: insights.schemaVersion,
            actions: insights.actions.map { action in
                MeetingAction(id: action.id, kind: action.kind, text: action.text,
                    actorSpeakerID: remapSpeakerID(action.actorSpeakerID, oldToNew: oldToNew, knownSpeakerIDs: knownSpeakerIDs),
                    targetSpeakerID: remapSpeakerID(action.targetSpeakerID, oldToNew: oldToNew, knownSpeakerIDs: knownSpeakerIDs),
                    dueText: action.dueText, evidenceTurnIDs: action.evidenceTurnIDs)
            },
            questions: insights.questions,
            decisions: insights.decisions.map { decision in
                MeetingDecision(id: decision.id, topic: decision.topic, status: decision.status,
                    steps: decision.steps.map { step in
                        MeetingDecisionStep(kind: step.kind, text: step.text,
                            speakerID: remapSpeakerID(step.speakerID, oldToNew: oldToNew, knownSpeakerIDs: knownSpeakerIDs),
                            evidenceTurnIDs: step.evidenceTurnIDs)
                    })
            })
    }

    private static func remapSpeakerID(_ id: String?, oldToNew: [String: String], knownSpeakerIDs: Set<String>) -> String? {
        guard let id else { return nil }
        if let mapped = oldToNew[id], knownSpeakerIDs.contains(mapped) { return mapped }
        return knownSpeakerIDs.contains(id) ? id : nil
    }

    private static func displayOwnerName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueSpeakerID(for rawID: String, usedIDs: inout Set<String>) -> String {
        let base = uniqueSpeakerID(for: rawID)
        var candidate = base
        var suffix = 2
        while usedIDs.contains(candidate) || candidate == "owner" {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }

    private static func uniqueSpeakerID(for rawID: String) -> String {
        let safe = rawID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? String(scalar) : "-"
        }.joined()
        let base = "speaker-\(safe.isEmpty ? "unknown" : safe)"
        return base == "owner" ? "speaker-owner" : base
    }

    private static func overlap(_ lhsStart: Double, _ lhsEnd: Double, _ rhsStart: Double, _ rhsEnd: Double) -> Double {
        max(0, min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
