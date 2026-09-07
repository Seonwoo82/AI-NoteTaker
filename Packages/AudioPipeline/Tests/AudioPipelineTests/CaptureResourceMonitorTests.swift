@testable import AudioPipeline
import CoreAudio
import Dispatch
import Foundation
import Testing

@Test("CaptureDeviceMonitor registers exact listener set on one serial queue and removes in reverse")
func captureDeviceMonitorRegistersExactListenerSetAndRemovesInReverse() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor")
    let state = CaptureDeviceMonitorState()
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(state: state, queue: queue, registrar: registrar)

    let recorder = CaptureDeviceEventRecorder()
    let registration = try monitor.register(
        aggregateID: 90,
        microphoneID: 11,
        eventHandler: recorder.append
    )
    try registration.remove()
    try registration.remove()

    let expectedAdds = [
        ListenerKey(90, kAudioDevicePropertyDeviceIsAlive),
        ListenerKey(90, kAudioDevicePropertyIOStoppedAbnormally),
        ListenerKey(90, kAudioDeviceProcessorOverload),
        ListenerKey(90, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ListenerKey(90, kAudioDevicePropertyNominalSampleRate),
        ListenerKey(11, kAudioDevicePropertyDeviceIsAlive),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    ]

    #expect(registrar.addKeys == expectedAdds)
    #expect(registrar.removeKeys == expectedAdds.reversed())
    #expect(registrar.allAddsUsedExpectedQueue)
    #expect(registrar.allRemovesUsedExpectedQueue)
    #expect(registrar.addCount == expectedAdds.count)
    #expect(registrar.removeCount == expectedAdds.count)
}

@Test("CaptureDeviceMonitor omits the microphone-alive listener for system-only capture")
func captureDeviceMonitorOmitsMicrophoneAliveListenerForSystemOnlyCapture() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor.system-only")
    let state = CaptureDeviceMonitorState()
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(state: state, queue: queue, registrar: registrar)

    let registration = try monitor.register(
        aggregateID: 90,
        microphoneID: nil,
        eventHandler: CaptureDeviceEventRecorder().append
    )
    try registration.remove()

    let expectedAdds = [
        ListenerKey(90, kAudioDevicePropertyDeviceIsAlive),
        ListenerKey(90, kAudioDevicePropertyIOStoppedAbnormally),
        ListenerKey(90, kAudioDeviceProcessorOverload),
        ListenerKey(90, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
        ListenerKey(90, kAudioDevicePropertyNominalSampleRate),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
        ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    ]

    #expect(registrar.addKeys == expectedAdds)
    #expect(registrar.removeKeys == expectedAdds.reversed())
    #expect(!registrar.addKeys.contains(ListenerKey(11, kAudioDevicePropertyDeviceIsAlive)))
    #expect(registrar.addCount == 8)
    #expect(registrar.removeCount == 8)
}

@Test("CaptureDeviceMonitor emits a typed event after each non-overload atomic update")
func captureDeviceMonitorEmitsTypedEventAfterEachNonOverloadAtomicUpdate() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor.events")
    let state = CaptureDeviceMonitorState()
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(state: state, queue: queue, registrar: registrar)
    let recorder = CaptureDeviceEventRecorder()

    _ = try monitor.register(
        aggregateID: 90,
        microphoneID: 11,
        eventHandler: { event in
            recorder.append(event, observing: state)
        }
    )
    let expectedAdds = registrar.addKeys

    let eventCases: [(ListenerKey, AudioObjectPropertySelector, CaptureDeviceEvent, () -> Bool)] = [
        (
            ListenerKey(90, kAudioDevicePropertyDeviceIsAlive),
            kAudioDevicePropertyDeviceIsAlive,
            .aggregateAliveChanged,
            { state.aggregateAliveChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(90, kAudioDevicePropertyIOStoppedAbnormally),
            kAudioDevicePropertyIOStoppedAbnormally,
            .ioStoppedAbnormally,
            { state.ioStoppedAbnormally.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(90, kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput),
            kAudioDevicePropertyStreamConfiguration,
            .streamConfigurationChanged,
            { state.streamConfigurationChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(90, kAudioDevicePropertyNominalSampleRate),
            kAudioDevicePropertyNominalSampleRate,
            .nominalSampleRateChanged,
            { state.nominalSampleRateChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(11, kAudioDevicePropertyDeviceIsAlive),
            kAudioDevicePropertyDeviceIsAlive,
            .microphoneAliveChanged,
            { state.microphoneAliveChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices),
            kAudioHardwarePropertyDevices,
            .deviceListChanged,
            { state.deviceListChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice),
            kAudioHardwarePropertyDefaultInputDevice,
            .defaultInputDeviceChanged,
            { state.defaultInputDeviceChanged.load(ordering: .relaxed) }
        ),
        (
            ListenerKey(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
            kAudioHardwarePropertyDefaultOutputDevice,
            .defaultOutputDeviceChanged,
            { state.defaultOutputDeviceChanged.load(ordering: .relaxed) }
        )
    ]

    for (key, selector, _, atomicWasUpdated) in eventCases {
        let index = try #require(expectedAdds.firstIndex(of: key))
        registrar.invokeAddedListener(at: index, selector: selector)
        #expect(atomicWasUpdated())
    }

    #expect(recorder.events() == eventCases.map { $0.2 })
    #expect(recorder.observedAtomicUpdates() == Array(repeating: true, count: eventCases.count))
}

@Test("CaptureDeviceMonitor overload listener only updates the counter")
func captureDeviceMonitorOverloadListenerOnlyUpdatesCounter() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor.overload")
    let state = CaptureDeviceMonitorState()
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(state: state, queue: queue, registrar: registrar)
    let recorder = CaptureDeviceEventRecorder()

    _ = try monitor.register(
        aggregateID: 90,
        microphoneID: 11,
        eventHandler: recorder.append
    )
    let expectedAdds = registrar.addKeys
    let overloadIndex = try #require(expectedAdds.firstIndex(of: ListenerKey(90, kAudioDeviceProcessorOverload)))
    registrar.invokeAddedListener(at: overloadIndex, selector: kAudioDeviceProcessorOverload)
    #expect(state.processorOverloadCount.load(ordering: .relaxed) == 1)
    #expect(recorder.events() == [])
}

@Test("CaptureDeviceMonitor creates a fresh removable registration for each restart")
func captureDeviceMonitorCreatesFreshRegistrationForEachRestart() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor.restart")
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(
        state: CaptureDeviceMonitorState(),
        queue: queue,
        registrar: registrar
    )

    let first = try monitor.register(
        aggregateID: 90,
        microphoneID: 11,
        eventHandler: CaptureDeviceEventRecorder().append
    )
    try first.remove()
    let second = try monitor.register(
        aggregateID: 91,
        microphoneID: 12,
        eventHandler: CaptureDeviceEventRecorder().append
    )
    try second.remove()

    #expect(registrar.addCount == 18)
    #expect(registrar.removeCount == 18)
    #expect(registrar.removeKeys.contains(ListenerKey(91, kAudioDevicePropertyDeviceIsAlive)))
    #expect(registrar.removeKeys.contains(ListenerKey(12, kAudioDevicePropertyDeviceIsAlive)))
}

@Test("CaptureDeviceMonitor retries listener tokens whose removal previously failed")
func captureDeviceMonitorRetriesOnlyFailedListenerRemovals() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.capture-monitor.retry")
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let monitor = CaptureDeviceMonitor(
        state: CaptureDeviceMonitorState(),
        queue: queue,
        registrar: registrar
    )
    let failedKey = ListenerKey(
        AudioObjectID(kAudioObjectSystemObject),
        kAudioHardwarePropertyDefaultOutputDevice
    )

    let registration = try monitor.register(
        aggregateID: 90,
        microphoneID: 11,
        eventHandler: CaptureDeviceEventRecorder().append
    )
    registrar.failNextRemove(for: failedKey)

    do {
        try registration.remove()
        Issue.record("remove unexpectedly succeeded")
    } catch AudioCaptureError.deviceDisconnected {
        #expect(registrar.removeCount == 9)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    try registration.remove()

    #expect(registrar.removeCount == 10)
    #expect(registrar.removeKeys.last == failedKey)
}

private final class CaptureDeviceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedEvents: [CaptureDeviceEvent] = []

    func append(_ event: CaptureDeviceEvent) {
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }

    func append(_ event: CaptureDeviceEvent, observing state: CaptureDeviceMonitorState) {
        let atomicWasUpdated: Bool
        switch event {
        case .aggregateAliveChanged:
            atomicWasUpdated = state.aggregateAliveChanged.load(ordering: .relaxed)
        case .microphoneAliveChanged:
            atomicWasUpdated = state.microphoneAliveChanged.load(ordering: .relaxed)
        case .ioStoppedAbnormally:
            atomicWasUpdated = state.ioStoppedAbnormally.load(ordering: .relaxed)
        case .streamConfigurationChanged:
            atomicWasUpdated = state.streamConfigurationChanged.load(ordering: .relaxed)
        case .nominalSampleRateChanged:
            atomicWasUpdated = state.nominalSampleRateChanged.load(ordering: .relaxed)
        case .deviceListChanged:
            atomicWasUpdated = state.deviceListChanged.load(ordering: .relaxed)
        case .defaultInputDeviceChanged:
            atomicWasUpdated = state.defaultInputDeviceChanged.load(ordering: .relaxed)
        case .defaultOutputDeviceChanged:
            atomicWasUpdated = state.defaultOutputDeviceChanged.load(ordering: .relaxed)
        }

        lock.lock()
        recordedEvents.append(event)
        observedAtomicUpdateValues.append(atomicWasUpdated)
        lock.unlock()
    }

    func events() -> [CaptureDeviceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func observedAtomicUpdates() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return observedAtomicUpdateValues
    }

    private var observedAtomicUpdateValues: [Bool] = []
}

@Test("CoreAudioPropertyListenerToken removes the registered listener on the same queue only once")
func coreAudioPropertyListenerTokenRemovesRegisteredListenerOnSameQueueOnlyOnce() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.listener-token")
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let address = CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in }

    let token = try CoreAudioPropertyListenerToken.register(
        objectID: 42,
        address: address,
        queue: queue,
        listener: listener,
        registrar: registrar
    )

    try token.remove()
    try token.remove()

    #expect(registrar.addCount == 1)
    #expect(registrar.removeCount == 1)
    #expect(registrar.addedExpectedQueue)
    #expect(registrar.removedExpectedQueue)
    #expect(registrar.removedListenerWasRegistered)
}

@Test("CoreAudioPropertyListenerToken retries removal after registrar failure")
func coreAudioPropertyListenerTokenRetriesRemovalAfterFailure() throws {
    let queue = DispatchQueue(label: "NoteTaker.Tests.listener-token.retry")
    let registrar = FakePropertyListenerRegistrar(expectedQueue: queue)
    let address = CoreAudioProperty.address(kAudioDevicePropertyDeviceIsAlive)
    let listener: AudioObjectPropertyListenerBlock = { _, _ in }
    let key = ListenerKey(42, kAudioDevicePropertyDeviceIsAlive)
    let token = try CoreAudioPropertyListenerToken.register(
        objectID: 42,
        address: address,
        queue: queue,
        listener: listener,
        registrar: registrar
    )

    registrar.failNextRemove(for: key)

    do {
        try token.remove()
        Issue.record("remove unexpectedly succeeded")
    } catch AudioCaptureError.deviceDisconnected {
        #expect(registrar.removeCount == 1)
    } catch {
        Issue.record("unexpected error: \(error)")
    }

    try token.remove()

    #expect(registrar.removeCount == 2)
    #expect(registrar.removedListenerWasRegistered)
}
