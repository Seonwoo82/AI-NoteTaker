import SwiftUI

struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .font(.title3).foregroundStyle(.red)
                .frame(width: 36, height: 42)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(recording.title).font(.headline).lineLimit(2)
                    if recording.isFavorite {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel("Favorite")
                    }
                }
                HStack {
                    Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    Spacer(minLength: 8)
                    Text(DurationFormat.list(recording.duration)).monospacedDigit()
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }
}
