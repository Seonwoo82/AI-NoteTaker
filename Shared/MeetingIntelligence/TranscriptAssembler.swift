import CryptoKit
import Foundation

nonisolated struct TimedTranscriptChunk: Equatable, Sendable {
    let startTime: Double
    let result: DetailedTranscriptionResult
}

nonisolated enum TranscriptAssembler {
    static func assemble(
        recordingID: UUID,
        audioVersion: Int,
        transcriptionModelID: String,
        chunks: [TimedTranscriptChunk],
        diarization: AcousticDiarization,
        ownerVoice: LocalVoiceProfile?,
        embeddingModelID: String,
        duration: Double,
        ownerName: String = "Me",
        policy: OwnerVoicePolicy = OwnerVoicePolicy()
    ) throws -> MeetingTranscript {
        let speakerMapper = SpeakerMapper(diarization: diarization, ownerVoice: ownerVoice,
            embeddingModelID: embeddingModelID, ownerName: ownerName, policy: policy)
        let turns = try makeTurns(
            recordingID: recordingID,
            audioVersion: audioVersion,
            chunks: chunks,
            mapper: speakerMapper,
            duration: duration
        )
        let usedSpeakers = Set(turns.compactMap(\.speakerID))
        var speakers = speakerMapper.speakers.filter { usedSpeakers.contains($0.id) || $0.id == "owner" }
        // A manual assignment target is available even before voice enrollment.
        // No turn is attributed to this speaker without acoustic evidence or an edit.
        if !speakers.contains(where: { $0.id == "owner" }) {
            let name = ownerName.trimmingCharacters(in: .whitespacesAndNewlines)
            speakers.append(MeetingSpeaker(id: "owner", name: name.isEmpty ? "Me" : name, isOwner: true))
        }
        let transcript = MeetingTranscript(recordingID: recordingID, audioVersion: audioVersion,
            transcriptionModelID: transcriptionModelID, speakers: speakers, turns: turns)
        try transcript.validate(duration: duration)
        return transcript
    }

    private static func makeTurns(
        recordingID: UUID,
        audioVersion: Int,
        chunks: [TimedTranscriptChunk],
        mapper: SpeakerMapper,
        duration: Double
    ) throws -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        for chunk in chunks.sorted(by: { $0.startTime < $1.startTime }) {
            let pieces = !chunk.result.words.isEmpty
                ? turnsFromWords(chunk.result.words, chunkStart: chunk.startTime, mapper: mapper)
                : chunk.result.segments.map { segment in
                    TurnPiece(start: chunk.startTime + segment.start, end: chunk.startTime + segment.end,
                        speakerID: mapper.speakerID(start: chunk.startTime + segment.start,
                            end: chunk.startTime + segment.end,
                            fallback: segment.speakerID),
                        text: normalizedText(segment.text))
                }
            for piece in pieces where !piece.text.isEmpty {
                try validateTime(start: piece.start, end: piece.end, duration: duration)
                let text = truncate(piece.text, maxCharacters: 4_000)
                turns.append(TranscriptTurn(id: stableTurnID(recordingID: recordingID,
                    audioVersion: audioVersion, start: piece.start, end: piece.end, text: text),
                    start: piece.start, end: piece.end, speakerID: piece.speakerID, text: text))
            }
        }
        return turns.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.id < $1.id
        }
    }

    private static func turnsFromWords(
        _ words: [TimedTranscriptionWord],
        chunkStart: Double,
        mapper: SpeakerMapper
    ) -> [TurnPiece] {
        var pieces: [TurnPiece] = []
        var currentWords: [String] = []
        var currentStart: Double?
        var currentEnd: Double?
        var currentSpeakerID: String?

        func flush() {
            guard let start = currentStart, let end = currentEnd else { return }
            let text = normalizedText(currentWords.joined(separator: " "))
            if !text.isEmpty {
                pieces.append(TurnPiece(start: start, end: end, speakerID: currentSpeakerID, text: text))
            }
            currentWords.removeAll(keepingCapacity: true)
            currentStart = nil
            currentEnd = nil
            currentSpeakerID = nil
        }

        for word in words.sorted(by: { $0.start < $1.start }) {
            let start = chunkStart + word.start
            let end = chunkStart + word.end
            let speakerID = mapper.speakerID(start: start, end: end, fallback: word.speakerID)
            if currentStart != nil, speakerID != currentSpeakerID {
                flush()
            }
            if currentStart == nil {
                currentStart = start
                currentSpeakerID = speakerID
            }
            currentEnd = end
            currentWords.append(word.text)
        }
        flush()
        return pieces
    }

    private static func validateTime(start: Double, end: Double, duration: Double) throws {
        guard start.isFinite, end.isFinite, duration.isFinite,
              start >= 0, start < end, end <= duration else {
            throw MeetingIntelligenceValidationError(message: "Transcript timestamps are outside the recording duration.")
        }
    }

    private static func normalizedText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func truncate(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stableTurnID(recordingID: UUID, audioVersion: Int, start: Double, end: Double, text: String) -> String {
        let source = "\(recordingID.uuidString)|\(audioVersion)|\(String(format: "%.3f", start))|\(String(format: "%.3f", end))|\(text)"
        let digest = SHA256.hash(data: Data(source.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "turn-\(digest)"
    }
}

private nonisolated struct TurnPiece {
    let start: Double
    let end: Double
    let speakerID: String?
    let text: String
}

private nonisolated struct SpeakerMapper {
    let speakers: [MeetingSpeaker]
    private let mappedIDs: [String: String]
    private let spans: [AcousticSpeakerSpan]

    init(
        diarization: AcousticDiarization,
        ownerVoice: LocalVoiceProfile?,
        embeddingModelID: String,
        ownerName: String,
        policy: OwnerVoicePolicy
    ) {
        var mappedIDs: [String: String] = [:]
        var speakers: [MeetingSpeaker] = []
        var usedIDs = Set<String>()

        for (index, speaker) in diarization.speakers.enumerated() {
            let isOwner = ownerVoice.map {
                policy.classify(embedding: speaker.embedding, profile: $0, modelID: embeddingModelID) == .owner
            } ?? false
            let mappedID = isOwner ? "owner" : Self.uniqueSpeakerID(for: speaker.id, usedIDs: &usedIDs)
            mappedIDs[speaker.id] = mappedID
            if !speakers.contains(where: { $0.id == mappedID }) {
                speakers.append(MeetingSpeaker(id: mappedID,
                    name: isOwner ? (ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Me" : ownerName) : "Speaker \(index + 1)",
                    isOwner: isOwner))
            }
        }

        self.speakers = speakers
        self.mappedIDs = mappedIDs
        self.spans = diarization.spans
    }

    func speakerID(start: Double, end: Double, fallback: String?) -> String? {
        guard !hasAmbiguousAcousticOverlap(start: start, end: end) else { return nil }
        let candidates = spans.filter { span in
            guard !span.isOverlap, let speakerID = span.speakerID, mappedIDs[speakerID] != nil else { return false }
            return Self.overlap(start, end, span.start, span.end) > 0
        }
        let mapped = Set(candidates.compactMap { $0.speakerID.flatMap { mappedIDs[$0] } })
        guard mapped.count == 1 else {
            if let fallback, mappedIDs[fallback] != nil, mapped.isEmpty {
                return mappedIDs[fallback]
            }
            return nil
        }
        return mapped.first
    }

    private func hasAmbiguousAcousticOverlap(start: Double, end: Double) -> Bool {
        if spans.contains(where: { $0.isOverlap && Self.overlap(start, end, $0.start, $0.end) > 0 }) {
            return true
        }
        let rawSpeakers = Set(spans.compactMap { span -> String? in
            guard let speakerID = span.speakerID,
                  mappedIDs[speakerID] != nil,
                  Self.overlap(start, end, span.start, span.end) > 0 else {
                return nil
            }
            return speakerID
        })
        return rawSpeakers.count > 1
    }

    private static func overlap(_ lhsStart: Double, _ lhsEnd: Double, _ rhsStart: Double, _ rhsEnd: Double) -> Double {
        max(0, min(lhsEnd, rhsEnd) - max(lhsStart, rhsStart))
    }

    private static func uniqueSpeakerID(for rawID: String, usedIDs: inout Set<String>) -> String {
        let safe = rawID.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? String(scalar) : "-"
        }.joined()
        let base = "speaker-\(safe.isEmpty ? "unknown" : safe)"
        var candidate = base == "owner" ? "speaker-owner" : base
        var suffix = 2
        while usedIDs.contains(candidate) || candidate == "owner" {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        usedIDs.insert(candidate)
        return candidate
    }
}
