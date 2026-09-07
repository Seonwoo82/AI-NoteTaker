import Foundation
import Testing
@testable import NoteTaker

@Test("list duration uses locale independent clock fields")
func listDurationUsesLocaleIndependentClockFields() {
    #expect(DurationFormat.list(4.18) == "0:04")
    #expect(DurationFormat.list(1_307) == "21:47")
    #expect(DurationFormat.list(6_319) == "1:45:19")
}

@Test("timer duration uses integer centiseconds")
func timerDurationUsesIntegerCentiseconds() {
    #expect(DurationFormat.timer(4.18, total: 10) == "00:04.18")
    #expect(DurationFormat.timer(61.20, total: 120) == "01:01.20")
    #expect(DurationFormat.timer(0, total: 3_600) == "0:00:00.00")
    #expect(DurationFormat.timer(3_600, total: 3_600) == "1:00:00.00")
}

@Test("ruler duration uses compact elapsed labels")
func rulerDurationUsesCompactElapsedLabels() {
    #expect(DurationFormat.ruler(1) == "0:01")
    #expect(DurationFormat.ruler(60) == "1:00")
    #expect(DurationFormat.ruler(3_600) == "1:00:00")
}

@Test("duration formats clamp negative and non finite inputs to zero")
func durationFormatsClampNegativeAndNonFiniteInputsToZero() {
    #expect(DurationFormat.list(-1) == "0:00")
    #expect(DurationFormat.timer(.nan, total: 10) == "00:00.00")
    #expect(DurationFormat.timer(.infinity, total: 3_600) == "0:00:00.00")
    #expect(DurationFormat.ruler(-.infinity) == "0:00")
}
