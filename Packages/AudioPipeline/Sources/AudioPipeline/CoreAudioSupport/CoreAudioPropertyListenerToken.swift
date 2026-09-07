import CoreAudio
import Dispatch
import Foundation

protocol CoreAudioPropertyListenerRegistering: Sendable {
    func add(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws

    func remove(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws
}

struct SystemCoreAudioPropertyListenerRegistrar: CoreAudioPropertyListenerRegistering {
    func add(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        try CoreAudioProperty.addPropertyListenerBlock(
            objectID: objectID,
            address: address,
            queue: queue,
            listener: listener
        )
    }

    func remove(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        try CoreAudioProperty.removePropertyListenerBlock(
            objectID: objectID,
            address: address,
            queue: queue,
            listener: listener
        )
    }
}

public final class CoreAudioPropertyListenerToken: @unchecked Sendable {
    private let objectID: AudioObjectID
    private let address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private let registrar: any CoreAudioPropertyListenerRegistering
    private let lock = NSLock()
    private var removed = false
    private var registered = false

    static func register(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock,
        registrar: any CoreAudioPropertyListenerRegistering = SystemCoreAudioPropertyListenerRegistrar()
    ) throws -> CoreAudioPropertyListenerToken {
        let token = CoreAudioPropertyListenerToken(
            objectID: objectID,
            address: address,
            queue: queue,
            listener: listener,
            registrar: registrar
        )
        try registrar.add(
            objectID: objectID,
            address: address,
            queue: queue,
            listener: token.listener
        )
        token.markRegistered()
        return token
    }

    private init(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        listener: @escaping AudioObjectPropertyListenerBlock,
        registrar: any CoreAudioPropertyListenerRegistering
    ) {
        self.objectID = objectID
        self.address = address
        self.queue = queue
        self.listener = listener
        self.registrar = registrar
    }

    deinit {
        try? remove()
    }

    public func remove() throws {
        lock.lock()
        guard registered, !removed else {
            lock.unlock()
            return
        }
        lock.unlock()

        try registrar.remove(
            objectID: objectID,
            address: address,
            queue: queue,
            listener: listener
        )

        lock.lock()
        removed = true
        lock.unlock()
    }

    private func markRegistered() {
        lock.lock()
        registered = true
        lock.unlock()
    }
}
