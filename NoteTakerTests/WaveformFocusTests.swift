import Testing
@testable import NoteTaker

@Suite struct WaveformFocusTests {
    @Test("five minute focus centers on the playhead and clamps at recording edges")
    func focusedRange() {
        let middle = WaveformViewport(duration: 3_600, currentTime: 1_800)
        #expect(middle.start == 1_650)
        #expect(middle.end == 1_950)
        #expect(middle.duration == 300)
        #expect(middle.position(of: 1_800) == 0.5)
        let start = WaveformViewport(duration: 3_600, currentTime: 20)
        #expect(start.start == 0)
        #expect(start.end == 300)
        let end = WaveformViewport(duration: 3_259, currentTime: 3_122)
        #expect(end.start == 2_959)
        #expect(end.end == 3_259)
    }

    @Test("short and invalid recordings have safe finite ranges")
    func shortAndInvalid() {
        #expect(WaveformViewport(duration: 80, currentTime: 70).duration == 80)
        #expect(WaveformViewport(duration: .infinity, currentTime: .nan).duration == 0)
        #expect(WaveformViewport(duration: -1, currentTime: 50).duration == 0)
        #expect(WaveformViewport(duration: 600, currentTime: .nan).start == 0)
    }

    @Test("frozen drag range maps absolute seek times without feedback drift")
    func absoluteSeekMapping() {
        let frozen = WaveformViewport(duration: 3_600, currentTime: 1_800)
        #expect(frozen.time(at: 0) == 1_650)
        #expect(frozen.time(at: 0.5) == 1_800)
        #expect(frozen.time(at: 1) == 1_950)
        #expect(frozen.time(at: -1) == 1_650)
        #expect(frozen.time(at: 2) == 1_950)
        #expect(frozen.time(at: .nan) == 1_650)
        let sought = frozen.time(at: 0.75)
        #expect(sought == 1_875)
        #expect(WaveformViewport(duration: 3_600, currentTime: sought).start == 1_725)
        #expect(WaveformViewport(duration: 3_600, currentTime: sought).position(of: sought) == 0.5)
    }

    @Test("focused bars use only nearby samples and the full view stays bounded")
    func focusedPeaks() {
        var peaks = [Double](repeating: 0.1, count: 3_600)
        peaks[1_700] = 0.8
        peaks[100] = 1
        let focus = WaveformViewport(duration: 3_600, currentTime: 1_800)
        let drawing = focus.peaks(from: peaks)
        #expect(drawing.count == 96)
        #expect(drawing.max() == 0.8)
        #expect(WaveformViewport.overviewPeaks(peaks).count == 96)
        #expect(WaveformViewport.overviewPeaks(peaks).max() == 1)
        #expect(focus.peaks(from: []).isEmpty)
        #expect(WaveformViewport.overviewPeaks([.nan, .infinity, -1]) == [0, 0, 0])
    }
}
