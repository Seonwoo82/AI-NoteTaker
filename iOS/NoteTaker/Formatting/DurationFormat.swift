import Foundation

nonisolated enum DurationFormat {
    static func list(_ seconds: TimeInterval) -> String {
        clockLabel(for: wholeSeconds(seconds))
    }

    static func timer(_ seconds: TimeInterval, total: TimeInterval) -> String {
        let centiseconds = clampedCentiseconds(seconds)
        let totalUsesHours = wholeSeconds(total) >= 3_600
        let elapsedSeconds = centiseconds / 100
        let centisecondPart = centiseconds % 100
        let label = totalUsesHours
            ? clockLabel(for: elapsedSeconds, forceHours: true)
            : timerLabelUnderHour(for: elapsedSeconds)
        return "\(label).\(twoDigits(centisecondPart))"
    }

    static func ruler(_ seconds: TimeInterval) -> String {
        clockLabel(for: wholeSeconds(seconds))
    }

    private static func wholeSeconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int(seconds.rounded(.down))
    }

    private static func clampedCentiseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int((seconds * 100).rounded(.toNearestOrAwayFromZero))
    }

    private static func clockLabel(for seconds: Int, forceHours: Bool = false) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let seconds = seconds % 60
        if hours > 0 || forceHours {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }
        return "\(minutes):\(twoDigits(seconds))"
    }

    private static func timerLabelUnderHour(for seconds: Int) -> String {
        let minutes = seconds / 60
        let seconds = seconds % 60
        return "\(twoDigits(minutes)):\(twoDigits(seconds))"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
