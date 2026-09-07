@testable import AudioPipeline
import CoreAudio
import Dispatch

final class FakePropertyListenerRegistrar: CoreAudioPropertyListenerRegistering, @unchecked Sendable {
    private let expectedQueue: DispatchQueue
    private var addedListener: AudioObjectPropertyListenerBlock?
    private var removedListener: AudioObjectPropertyListenerBlock?
    private var addedQueue: DispatchQueue?
    private var removedQueue: DispatchQueue?
    private var addedListeners: [AudioObjectPropertyListenerBlock] = []
    private var removeFailures: [ListenerKey: Int] = [:]
    private var addQueues: [DispatchQueue] = []
    private var removeQueues: [DispatchQueue] = []
    private(set) var addKeys: [ListenerKey] = []
    private(set) var removeKeys: [ListenerKey] = []
    private(set) var addCount = 0
    private(set) var removeCount = 0
    private var registeredKeys: Set<ListenerKey> = []
    private var removedRegisteredListener = false

    init(expectedQueue: DispatchQueue) {
        self.expectedQueue = expectedQueue
    }

    func failNextRemove(for key: ListenerKey) {
        removeFailures[key, default: 0] += 1
    }

    func add(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        addCount += 1
        addedQueue = queue
        addedListener = listener
        addedListeners.append(listener)
        addQueues.append(queue)
        let key = ListenerKey(objectID, address)
        addKeys.append(key)
        registeredKeys.insert(key)
    }

    func remove(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        removeCount += 1
        removedQueue = queue
        removedListener = listener
        removeQueues.append(queue)
        let key = ListenerKey(objectID, address)
        removeKeys.append(key)
        removedRegisteredListener = registeredKeys.contains(key)
        if let remaining = removeFailures[key], remaining > 0 {
            removeFailures[key] = remaining - 1
            throw AudioCaptureError.deviceDisconnected
        }
    }

    var addedExpectedQueue: Bool { addedQueue === expectedQueue }
    var removedExpectedQueue: Bool { removedQueue === expectedQueue }
    var allAddsUsedExpectedQueue: Bool { addQueues.allSatisfy { $0 === expectedQueue } }
    var allRemovesUsedExpectedQueue: Bool { removeQueues.allSatisfy { $0 === expectedQueue } }
    var removedListenerWasRegistered: Bool {
        addedListener != nil && removedListener != nil && removedRegisteredListener
    }

    func invokeAddedListener(at index: Int, selector: AudioObjectPropertySelector) {
        guard addedListeners.indices.contains(index) else { return }
        var address = CoreAudioProperty.address(selector)
        addedListeners[index](1, &address)
    }
}

struct ListenerKey: Equatable, Hashable, Sendable {
    let objectID: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
    let element: AudioObjectPropertyElement

    init(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.objectID = objectID
        self.selector = selector
        self.scope = scope
        self.element = element
    }

    init(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) {
        self.init(objectID, address.mSelector, address.mScope, address.mElement)
    }
}
