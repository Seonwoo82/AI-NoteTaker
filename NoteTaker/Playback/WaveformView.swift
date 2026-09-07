import SwiftUI

nonisolated struct WaveformTimelineMarks {
    nonisolated struct Tick: Equatable, Identifiable {
        let time: TimeInterval
        let position: Double
        let label: String

        var id: TimeInterval { time }
    }

    let duration: TimeInterval
    let currentTime: TimeInterval
    let progress: Double
    let ticks: [Tick]

    init(duration: TimeInterval, currentTime: TimeInterval, interval: TimeInterval = 15) {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        self.duration = safeDuration
        self.currentTime = currentTime.isFinite ? min(max(0, currentTime), safeDuration) : 0
        self.progress = safeDuration > 0 ? self.currentTime / safeDuration : 0

        guard safeDuration > 0, interval.isFinite, interval > 0 else {
            self.ticks = []
            return
        }

        // At most six interior intervals, including very long recordings.
        let step = max(interval, ceil(safeDuration / interval / 6) * interval)
        var times = (0..<7).map { Double($0) * step }.filter { $0 < safeDuration }
        if times.last != safeDuration {
            times.append(safeDuration)
        }

        self.ticks = times.map { time in
            Tick(
                time: time,
                position: time / safeDuration,
                label: DurationFormat.list(time)
            )
        }
    }
}

struct WaveformView: View {
    let peaks: [Double]
    let currentTime: TimeInterval
    let duration: TimeInterval
    var prominence: Prominence = .primary
    var onSeek: ((TimeInterval) -> Void)?

    enum Prominence {
        case primary
        case overview
        case live
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawWaveform(in: size, context: &context)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard let onSeek, duration > 0 else { return }
                            let ratio = min(1, max(0, value.location.x / max(1, proxy.size.width)))
                            onSeek(duration * ratio)
                        }
                )

                if prominence == .primary {
                    ForEach(timelineMarks.ticks) { tick in
                        Text(tick.label)
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .position(
                                x: proxy.size.width * tick.position,
                                y: max(0, proxy.size.height - 8)
                            )
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Waveform"))
        .accessibilityValue(DurationFormat.timer(currentTime, total: duration))
        .accessibilityAdjustableAction { direction in
            guard let onSeek else { return }
            switch direction {
            case .increment: onSeek(min(timelineMarks.duration, timelineMarks.currentTime + 15))
            case .decrement: onSeek(max(0, timelineMarks.currentTime - 15))
            @unknown default: break
            }
        }
    }

    private func drawWaveform(in size: CGSize, context: inout GraphicsContext) {
        let drawingPeaks = peaks
        let barCount = drawingPeaks.count
        guard barCount > 0 else { return }

        let labelReserve: CGFloat = prominence == .primary ? 22 : 0
        let verticalInset: CGFloat = prominence == .overview ? 5 : 0
        let waveformHeight = max(2, size.height - labelReserve - verticalInset * 2)
        let midY = verticalInset + waveformHeight / 2
        if prominence == .overview {
            let track = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.fill(
                Path(roundedRect: track, cornerRadius: 9),
                with: .color(.secondary.opacity(0.10))
            )
        }

        let stride = size.width / CGFloat(barCount)
        let barWidth = min(prominence == .primary ? 2.4 : 2, stride * 0.6)
        let fill = color.opacity(prominence == .overview ? 0.62 : 0.82)

        for (index, peak) in drawingPeaks.enumerated() {
            let normalized = peak.isFinite ? max(0, min(1, peak)) : 0
            let height = max(2, waveformHeight * CGFloat(normalized))
            let rect = CGRect(
                x: (CGFloat(index) + 0.5) * stride - barWidth / 2,
                y: midY - height / 2,
                width: barWidth,
                height: height
            )
            let path = Path(roundedRect: rect, cornerRadius: min(1.2, barWidth / 3))
            context.fill(path, with: .color(fill))
        }

        guard duration > 0, prominence != .live else { return }
        let playheadX = size.width * CGFloat(timelineMarks.progress)
        var playhead = Path()
        let lineTop: CGFloat = prominence == .overview ? 4 : 0
        let lineBottom = prominence == .primary ? size.height - labelReserve : size.height - 4
        playhead.move(to: CGPoint(x: playheadX, y: lineTop))
        playhead.addLine(to: CGPoint(x: playheadX, y: lineBottom))
        context.stroke(playhead, with: .color(.blue), lineWidth: prominence == .primary ? 2 : 1.5)

        if prominence == .primary {
            let radius: CGFloat = 4
            context.fill(Path(ellipseIn: CGRect(x: playheadX - radius, y: 0, width: radius * 2, height: radius * 2)), with: .color(.blue))
            context.fill(Path(ellipseIn: CGRect(x: playheadX - radius, y: lineBottom - radius * 2, width: radius * 2, height: radius * 2)), with: .color(.blue))
        }
    }

    private var color: Color {
        switch prominence {
        case .primary:
            .primary
        case .overview:
            .secondary
        case .live:
            .red
        }
    }

    private var timelineMarks: WaveformTimelineMarks {
        WaveformTimelineMarks(duration: duration, currentTime: currentTime)
    }
}
