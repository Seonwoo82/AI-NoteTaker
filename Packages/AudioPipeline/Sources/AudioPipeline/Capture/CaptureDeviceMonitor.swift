import CoreAudio
import Dispatch
import Synchronization

public final class CaptureDeviceMonitorState: @unchecked Sendable {
    public let aggregateAliveChanged = Atomic(false)
    public let microphoneAliveChanged = Atomic(false)
    public let ioStoppedAbnormally = Atomic(false)
    public let processorOverloadCount = Atomic<UInt64>(0)
    public let streamConfigurationChanged = Atomic(false)
    public let nominalSampleRateChanged = Atomic(false)
    public let deviceListChanged = Atomic(false)
    public let defaultInputDeviceChanged = Atomic(false)
    public let defaultOutputDeviceChanged = Atomic(false)

    public init() {}
}

enum CaptureDeviceEvent: Equatable, Sendable {
    case aggregateAliveChanged
    case microphoneAliveChanged
    case ioStoppedAbnormally
    case streamConfigurationChanged
    case nominalSampleRateChanged
    case deviceListChanged
    case defaultInputDeviceChanged
    case defaultOutputDeviceChanged
}

protocol CaptureDeviceMonitorRegistration: AnyObject, Sendable {
    func remove() throws
}

protocol CaptureDeviceMonitoring: Sendable {
    func register(
        aggregateID: AudioObjectID,
        microphoneID: AudioObjectID?,
        eventHandler: @escaping @Sendable (CaptureDeviceEvent) -> Void
    ) throws -> any CaptureDeviceMonitorRegistration
}

public final class CaptureDeviceMonitor: CaptureDeviceMonitoring, @unchecked Sendable {
    public let state: CaptureDeviceMonitorState

    private let queue: DispatchQueue
    private let registrar: any CoreAudioPropertyListenerRegistering

    public convenience init() {
        self.init(
            state: CaptureDeviceMonitorState(),
            queue: DispatchQueue(label: "NoteTaker.CaptureDeviceMonitor.listeners", qos: .userInteractive),
            registrar: SystemCoreAudioPropertyListenerRegistrar()
        )
    }

    init(
        state: CaptureDeviceMonitorState,
        queue: DispatchQueue,
        registrar: any CoreAudioPropertyListenerRegistering
    ) {
        self.state = state
        self.queue = queue
        self.registrar = registrar
    }

    func register(
        aggregateID: AudioObjectID,
        microphoneID: AudioObjectID?,
        eventHandler: @escaping @Sendable (CaptureDeviceEvent) -> Void
    ) throws -> any CaptureDeviceMonitorRegistration {
        let registration = CaptureDeviceMonitorTokenRegistration()
        try addToken(
            to: registration,
            objectID: aggregateID,
            address: CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
        ) { [state] _, _ in
            state.aggregateAliveChanged.store(true, ordering: .relaxed)
            eventHandler(.aggregateAliveChanged)
        }
        try addToken(
            to: registration,
            objectID: aggregateID,
            address: CoreAudioProperty.address(kAudioDevicePropertyIOStoppedAbnormally)
        ) { [state] _, _ in
            state.ioStoppedAbnormally.store(true, ordering: .relaxed)
            eventHandler(.ioStoppedAbnormally)
        }
        try addToken(
            to: registration,
            objectID: aggregateID,
            address: CoreAudioProperty.address(kAudioDeviceProcessorOverload)
        ) { [state] _, _ in
            state.processorOverloadCount.wrappingAdd(1, ordering: .relaxed)
        }
        try addToken(
            to: registration,
            objectID: aggregateID,
            address: CoreAudioProperty.address(
                kAudioDevicePropertyStreamConfiguration,
                scope: kAudioObjectPropertyScopeInput
            )
        ) { [state] _, _ in
            state.streamConfigurationChanged.store(true, ordering: .relaxed)
            eventHandler(.streamConfigurationChanged)
        }
        try addToken(
            to: registration,
            objectID: aggregateID,
            address: CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
        ) { [state] _, _ in
            state.nominalSampleRateChanged.store(true, ordering: .relaxed)
            eventHandler(.nominalSampleRateChanged)
        }
        if let microphoneID {
            try addToken(
                to: registration,
                objectID: microphoneID,
                address: CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
            ) { [state] _, _ in
                state.microphoneAliveChanged.store(true, ordering: .relaxed)
                eventHandler(.microphoneAliveChanged)
            }
        }

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        try addToken(
            to: registration,
            objectID: systemObject,
            address: CoreAudioProperty.address(kAudioHardwarePropertyDevices)
        ) { [state] _, _ in
            state.deviceListChanged.store(true, ordering: .relaxed)
            eventHandler(.deviceListChanged)
        }
        try addToken(
            to: registration,
            objectID: systemObject,
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultInputDevice)
        ) { [state] _, _ in
            state.defaultInputDeviceChanged.store(true, ordering: .relaxed)
            eventHandler(.defaultInputDeviceChanged)
        }
        try addToken(
            to: registration,
            objectID: systemObject,
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [state] _, _ in
            state.defaultOutputDeviceChanged.store(true, ordering: .relaxed)
            eventHandler(.defaultOutputDeviceChanged)
        }

        return registration
    }

    private func addToken(
        to registration: CaptureDeviceMonitorTokenRegistration,
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        do {
            let token = try CoreAudioPropertyListenerToken.register(
                objectID: objectID,
                address: address,
                queue: queue,
                listener: listener,
                registrar: registrar
            )
            registration.append(token)
        } catch {
            try? registration.remove()
            throw error
        }
    }
}

private final class CaptureDeviceMonitorTokenRegistration: CaptureDeviceMonitorRegistration, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [CoreAudioPropertyListenerToken] = []

    func append(_ token: CoreAudioPropertyListenerToken) {
        lock.lock()
        tokens.append(token)
        lock.unlock()
    }

    func remove() throws {
        let tokensToRemove: [CoreAudioPropertyListenerToken]
        lock.lock()
        tokensToRemove = tokens.reversed()
        lock.unlock()

        var failedTokens: [CoreAudioPropertyListenerToken] = []
        var firstError: Error?
        for token in tokensToRemove {
            do {
                try token.remove()
            } catch {
                failedTokens.append(token)
                firstError = firstError ?? error
            }
        }

        lock.lock()
        tokens = failedTokens.reversed()
        lock.unlock()

        if let firstError {
            throw firstError
        }
    }
}
