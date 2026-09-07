public enum CaptureMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case micAndSystem
    case micOnly
    case systemOnly
}
