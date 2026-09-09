import AVFoundation
import Foundation
#if canImport(AudioPipeline)
import AudioPipeline
#endif

/// Owns a microphone only while the user explicitly records an enrollment sample.
@MainActor
final class VoiceEnrollmentCapture {
    private var engine: AVAudioEngine?
    private var generation = UUID()
    private var isStarting = false
    private var ownsAudioSession = false
    private let requestPermission: @MainActor () async -> Bool

    init(requestPermission: @escaping @MainActor () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }) {
        self.requestPermission = requestPermission
    }
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    var onInterrupted: (() -> Void)?
    var isRunning: Bool { engine?.isRunning == true }

    func start(handler: @escaping LiveAudioSampleHandler) async throws {
        try Task.checkCancellation()
        guard engine == nil, !isStarting else { return }
        isStarting = true
        let current = generation
        defer { if current == generation { isStarting = false } }
        let permitted = await requestPermission()
        guard current == generation else { throw CancellationError() }
        guard !Task.isCancelled else { throw CancellationError() }
        guard permitted else { throw AIError(message: "목소리를 등록하려면 마이크 접근을 허용해 주세요.") }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        ownsAudioSession = true
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw AIError(message: "등록할 목소리를 받을 마이크를 찾지 못했어요.")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.makeTapHandler(handler: handler))
        do {
            engine.prepare()
            try engine.start()
            self.engine = engine
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            #if os(iOS)
            if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
            ownsAudioSession = false
            #endif
            throw AIError(message: "목소리 등록을 시작하지 못했어요. 마이크 상태를 확인해 주세요.")
        }
        #if os(iOS)
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupt() }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            guard reason == .oldDeviceUnavailable || reason == .newDeviceAvailable || reason == .routeConfigurationChange else { return }
            Task { @MainActor in self?.interrupt() }
        }
        #else
        interruptionObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.interrupt() }
        }
        #endif
    }

    // AVFAudio calls the block on its realtime worker queue. Create it outside
    // MainActor so Swift 6 does not insert a UI-executor check into that block.
    nonisolated static func makeTapHandler(handler: @escaping LiveAudioSampleHandler) -> AVAudioNodeTapBlock {
        let emitter = EnrollmentAudioEmitter(handler: handler)
        return { buffer, _ in emitter.consume(buffer) }
    }

    func stop() {
        generation = UUID()
        isStarting = false
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        interruptionObserver = nil
        routeObserver = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        #if os(iOS)
        if ownsAudioSession { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
        ownsAudioSession = false
        #endif
    }

    private func interrupt() {
        guard engine != nil else { return }
        stop()
        onInterrupted?()
    }
}

nonisolated private final class EnrollmentAudioEmitter: @unchecked Sendable {
    private let handler: LiveAudioSampleHandler
    // AVAudioEngine serializes a tap's callback. No inference/file I/O runs here.
    private var frames: Int64 = 0
    init(handler: @escaping LiveAudioSampleHandler) { self.handler = handler }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let count = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0, count <= 65_536 else { return }
        var mono = [Float](repeating: 0, count: count)
        for channel in 0..<channelCount {
            for frame in 0..<count { mono[frame] += channels[channel][frame] / Float(channelCount) }
        }
        let start = Double(frames) / buffer.format.sampleRate
        frames += Int64(count)
        handler(LiveAudioSamples(samples: mono, sampleRate: buffer.format.sampleRate, startTime: start))
    }
}
