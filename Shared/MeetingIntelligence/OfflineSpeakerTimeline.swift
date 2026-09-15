import CoreML
import FluidAudio
import Foundation

nonisolated struct OfflineSpeakerClip: Equatable, Sendable {
    let speakerID: String
    let start: Double
    let end: Double

    func samples(in window: LocalSpeakerPCMWindow) -> ArraySlice<Float> {
        let windowStart = Int((window.startTime * window.sampleRate).rounded())
        let lower = max(0, Int((start * window.sampleRate).rounded()) - windowStart)
        let upper = min(window.samples.count, Int((end * window.sampleRate).rounded()) - windowStart)
        guard lower < upper else { return [] }
        return window.samples[lower..<upper]
    }
}

/// Converts recording-wide clusters to stable, overlap-aware app spans. Offline
/// centroids deliberately stay out of this type: owner evidence uses our enrolled model.
nonisolated struct OfflineSpeakerTimeline: Sendable {
    let speakerIDs: [String]
    let spans: [AcousticSpeakerSpan]

    init(segments: [TimedSpeakerSegment]) {
        let valid = segments.filter {
            !$0.speakerId.isEmpty && $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite
                && $0.startTimeSeconds >= 0 && $0.endTimeSeconds > $0.startTimeSeconds
        }.sorted {
            if $0.startTimeSeconds != $1.startTimeSeconds { return $0.startTimeSeconds < $1.startTimeSeconds }
            return $0.speakerId < $1.speakerId
        }
        var mappedIDs: [String: String] = [:]
        var orderedIDs: [String] = []
        let baseSpans = valid.map { segment in
            if mappedIDs[segment.speakerId] == nil {
                let id = String(orderedIDs.count + 1)
                mappedIDs[segment.speakerId] = id
                orderedIDs.append(id)
            }
            return AcousticSpeakerSpan(start: Double(segment.startTimeSeconds), end: Double(segment.endTimeSeconds),
                speakerID: mappedIDs[segment.speakerId])
        }
        speakerIDs = orderedIDs
        spans = (baseSpans + Self.overlappingSpans(baseSpans)).sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return !$0.isOverlap && $1.isOverlap
        }
    }

    /// Longest independent clips first; never use simultaneous voices or brief
    /// backchannels as owner evidence. Three clips bound extra model work per speaker.
    func representativeClips() -> [OfflineSpeakerClip] {
        let overlaps = Self.merged(spans.filter(\.isOverlap).map { $0.start..<$0.end })
        return speakerIDs.flatMap { id in
            let spoken = Self.merged(spans.filter { !$0.isOverlap && $0.speakerID == id }.map { $0.start..<$0.end })
            var candidates: [OfflineSpeakerClip] = []
            for range in spoken {
                var cursor = range.lowerBound
                var clean: [Range<Double>] = []
                for overlap in overlaps where overlap.upperBound > cursor && overlap.lowerBound < range.upperBound {
                    if overlap.lowerBound > cursor { clean.append(cursor..<min(overlap.lowerBound, range.upperBound)) }
                    cursor = max(cursor, overlap.upperBound)
                }
                if cursor < range.upperBound { clean.append(cursor..<range.upperBound) }
                for interval in clean {
                    var start = interval.lowerBound
                    while interval.upperBound - start >= 3 {
                        let end = min(start + 10, interval.upperBound)
                        candidates.append(OfflineSpeakerClip(speakerID: id, start: start, end: end))
                        start = end
                    }
                }
            }
            return Array(candidates.sorted {
                let leftDuration = $0.end - $0.start
                let rightDuration = $1.end - $1.start
                if leftDuration != rightDuration { return leftDuration > rightDuration }
                return $0.start < $1.start
            }.prefix(3))
        }
    }

    static func averageEmbeddings(_ embeddings: [[Float]], dimension: Int = 256) -> [Float] {
        var sum = [Double](repeating: 0, count: dimension)
        for embedding in embeddings where embedding.count == dimension && embedding.allSatisfy(\.isFinite) {
            let norm = sqrt(embedding.reduce(0.0) { $0 + Double($1) * Double($1) })
            guard norm > 1e-10 else { continue }
            for index in sum.indices { sum[index] += Double(embedding[index]) / norm }
        }
        let norm = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard norm > 1e-10 else { return [] }
        return sum.map { Float($0 / norm) }
    }

    private static func merged(_ ranges: [Range<Double>]) -> [Range<Double>] {
        var output: [Range<Double>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = output.last, range.lowerBound <= last.upperBound {
                output[output.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                output.append(range)
            }
        }
        return output
    }

    private static func overlappingSpans(_ spans: [AcousticSpeakerSpan]) -> [AcousticSpeakerSpan] {
        let events = spans.flatMap { span -> [(time: Double, id: String, delta: Int)] in
            guard let id = span.speakerID else { return [] }
            return [(span.start, id, 1), (span.end, id, -1)]
        }.sorted { $0.time < $1.time }
        var active: [String: Int] = [:]
        var previous: Double?
        var overlaps: [Range<Double>] = []
        var index = 0
        while index < events.count {
            let time = events[index].time
            if let previous, time > previous, active.count > 1 { overlaps.append(previous..<time) }
            while index < events.count, events[index].time == time {
                let event = events[index]
                let count = active[event.id, default: 0] + event.delta
                if count > 0 { active[event.id] = count } else { active.removeValue(forKey: event.id) }
                index += 1
            }
            previous = time
        }
        return merged(overlaps).map { AcousticSpeakerSpan(start: $0.lowerBound, end: $0.upperBound,
            speakerID: nil, isOverlap: true) }
    }
}

/// A separate repository root prevents offline download recovery from removing
/// the streaming bundles used by existing voice profiles.
nonisolated struct OfflineSpeakerModelCache {
    let directory: URL

    func loadCached() throws -> OfflineDiarizerModels? {
        let repo = directory.appending(path: Repo.diarizer.folderName)
        let names = ModelNames.OfflineDiarizer.requiredModels
        guard names.allSatisfy({ FileManager.default.fileExists(atPath: repo.appending(path: $0).path) }) else {
            return nil
        }
        let started = Date()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let fbankConfiguration = MLModelConfiguration()
        fbankConfiguration.computeUnits = .cpuOnly
        return try OfflineDiarizerModels(
            segmentationModel: MLModel(contentsOf: repo.appending(path: ModelNames.OfflineDiarizer.segmentationFile),
                configuration: configuration),
            fbankModel: MLModel(contentsOf: repo.appending(path: ModelNames.OfflineDiarizer.fbankFile),
                configuration: fbankConfiguration),
            embeddingModel: MLModel(contentsOf: repo.appending(path: ModelNames.OfflineDiarizer.embeddingFile),
                configuration: configuration),
            pldaRhoModel: MLModel(contentsOf: repo.appending(path: ModelNames.OfflineDiarizer.pldaRhoFile),
                configuration: configuration),
            pldaPsi: Self.decodePLDAPsi(Data(contentsOf: repo.appending(path: ModelNames.OfflineDiarizer.pldaParameters))),
            compilationDuration: Date().timeIntervalSince(started))
    }

    static func decodePLDAPsi(_ data: Data) throws -> [Double] {
        let invalid = AIError(message: String(localized: "Cached speaker models are incomplete. Prepare voice models again."))
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any], let psi = tensors["psi"] as? [String: Any],
              let encoded = psi["data_base64"] as? String,
              let decoded = Data(base64Encoded: encoded, options: [.ignoreUnknownCharacters]),
              !decoded.isEmpty, decoded.count.isMultiple(of: MemoryLayout<Float>.size) else { throw invalid }
        var values = [Float](repeating: 0, count: decoded.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { decoded.copyBytes(to: $0) }
        guard values.allSatisfy(\.isFinite) else { throw invalid }
        return values.map(Double.init)
    }
}
