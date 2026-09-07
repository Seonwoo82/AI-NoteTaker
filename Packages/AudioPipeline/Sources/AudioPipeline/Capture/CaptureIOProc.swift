import CoreAudio

public enum CaptureIOProc {
    public static nonisolated func makeBlock(context: CaptureContext) -> AudioDeviceIOBlock {
        { _, inputData, inputTime, _, _ in
            let accepted = CaptureBufferCopier.copy(
                inputData: inputData,
                inputTime: inputTime,
                context: context
            )
            if accepted > 0 {
                context.wake.signal()
            }
        }
    }
}
