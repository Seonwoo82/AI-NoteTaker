import SwiftUI

struct RecordingRow: View {
    let recording: Recording
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(recording.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if recording.isFavorite && recording.deletedAt == nil {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(isSelected ? .white.opacity(0.9) : .yellow)
                        .accessibilityLabel(String(localized: "Favorite"))
                }
            }

            HStack(spacing: 6) {
                Text(DateFormat.recordingList.string(from: recording.createdAt))
                Text(DurationFormat.list(recording.duration))
                if let deletedAt = recording.deletedAt {
                    Text(retentionText(deletedAt: deletedAt))
                } else {
                    Text(recording.mode.localizedLabel)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(isSelected ? .white.opacity(0.84) : .secondary)
            .lineLimit(1)
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func retentionText(deletedAt: Date) -> String {
        let elapsedDays = Calendar.current.dateComponents([.day], from: deletedAt, to: .now).day ?? 0
        let days = max(0, 30 - elapsedDays)
        return String(localized: "\(days) days left")
    }
}
