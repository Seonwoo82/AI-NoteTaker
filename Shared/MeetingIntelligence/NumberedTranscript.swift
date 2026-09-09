import Foundation
import SwiftUI

nonisolated struct NumberedTranscript: Equatable, Sendable {
    nonisolated struct Line: Identifiable, Equatable, Sendable {
        let id: String
        let start: Double
        let text: String
        let speakerID: String?
        let participantNumber: Int?
        let speakerName: String?

        var speakerLabel: String {
            if let participantNumber {
                return String(localized: "Participant \(participantNumber)")
            }
            return String(localized: "Unidentified participant")
        }
    }

    let lines: [Line]
    private let numbersBySpeakerID: [String: Int]

    init(_ transcript: MeetingTranscript) {
        let knownSpeakers = transcript.speakers.reduce(into: [String: MeetingSpeaker]()) { speakers, speaker in
            speakers[speaker.id] = speakers[speaker.id] ?? speaker
        }
        var nextNumber = 1
        var numbersBySpeakerID: [String: Int] = [:]
        var lines: [Line] = []

        for turn in transcript.turns.sorted(by: Self.turnOrder) {
            let speaker = turn.speakerID.flatMap { knownSpeakers[$0] }
            let participantNumber: Int?
            if let speakerID = speaker?.id {
                if let existing = numbersBySpeakerID[speakerID] {
                    participantNumber = existing
                } else {
                    participantNumber = nextNumber
                    numbersBySpeakerID[speakerID] = nextNumber
                    nextNumber += 1
                }
            } else {
                participantNumber = nil
            }
            lines.append(Line(id: turn.id, start: turn.start, text: turn.text,
                speakerID: speaker?.id, participantNumber: participantNumber,
                speakerName: speaker?.name))
        }

        self.lines = lines
        self.numbersBySpeakerID = numbersBySpeakerID
    }

    func participantNumber(for speakerID: String) -> Int? {
        numbersBySpeakerID[speakerID]
    }

    static func text(_ transcript: MeetingTranscript) -> String {
        NumberedTranscript(transcript).lines.map { line in
            "[\(timestamp(line.start))] \(line.speakerLabel): \(line.text)"
        }.joined(separator: "\n")
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < Double(Int.max) else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", remainingSeconds))"
        }
        return "\(minutes):\(String(format: "%02d", remainingSeconds))"
    }

    private static func turnOrder(_ lhs: TranscriptTurn, _ rhs: TranscriptTurn) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.end != rhs.end { return lhs.end < rhs.end }
        return lhs.id < rhs.id
    }
}

struct NumberedTranscriptView: View {
    private let numberedTranscript: NumberedTranscript

    init(transcript: MeetingTranscript) {
        self.numberedTranscript = NumberedTranscript(transcript)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(numberedTranscript.lines) { line in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(NumberedTranscript.timestamp(line.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 48, alignment: .leading)
                        Text("\(line.speakerLabel):")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(line.participantNumber == nil ? .secondary : .primary)
                    }
                    Text(line.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("numbered-transcript")
    }
}
