import Testing
#if os(iOS)
@testable import NoteTakerIOS
#else
@testable import NoteTaker
#endif

@Suite("Voice enrollment guide")
struct VoiceEnrollmentGuideTests {
    @Test("guide keeps saving disabled until the enrollment minimum")
    func finishGateUsesMinimumDuration() {
        let policy = VoiceEnrollmentGuidePolicy(minimumDuration: 10, maximumDuration: 30)

        #expect(!policy.canFinish(elapsed: 9.99))
        #expect(policy.canFinish(elapsed: 10))
        #expect(policy.remainingMinimumSeconds(elapsed: 8.2) == 2)
    }

    @Test("guide progress is bounded to the enrollment window")
    func progressIsBounded() {
        let policy = VoiceEnrollmentGuidePolicy(minimumDuration: 10, maximumDuration: 30)

        #expect(policy.progress(elapsed: -1) == 0)
        #expect(policy.progress(elapsed: 15) == 0.5)
        #expect(policy.progress(elapsed: 31) == 1)
    }
}
