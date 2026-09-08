import Foundation

nonisolated enum DateFormat {
    static let recordingList: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
