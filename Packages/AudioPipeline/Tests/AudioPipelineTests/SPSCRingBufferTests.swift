@testable import AudioPipeline
import Darwin
import Dispatch
import Foundation
import Testing

@Test("SPSC ring buffer preserves mono frame order through a round trip")
func spscRingBufferPreservesMonoFrameOrderThroughRoundTrip() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4, channelCount: 1)
    let source: [Float] = [1, 2, 3]

    let accepted = source.withUnsafeBufferPointer { buffer in
        ring.write(buffer, frameCount: 3)
    }

    var destination = Array<Float>(repeating: -1, count: 3)
    let read = destination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 3)
    }

    #expect(accepted == 3)
    #expect(read == 3)
    #expect(destination == [1, 2, 3])
}

@Test("SPSC ring buffer preserves stereo interleaving through a round trip")
func spscRingBufferPreservesStereoInterleavingThroughRoundTrip() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4, channelCount: 2)
    let source: [Float] = [1, 10, 2, 20, 3, 30]

    let accepted = source.withUnsafeBufferPointer { buffer in
        ring.write(buffer, frameCount: 3)
    }

    var destination = Array<Float>(repeating: -1, count: 6)
    let read = destination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 3)
    }

    #expect(accepted == 3)
    #expect(read == 3)
    #expect(destination == [1, 10, 2, 20, 3, 30])
}

@Test("SPSC ring buffer reads wrapped frames in FIFO order")
func spscRingBufferReadsWrappedFramesInFIFOOrder() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4, channelCount: 1)
    let firstWrite: [Float] = [1, 2, 3]
    let secondWrite: [Float] = [4, 5, 6]

    let firstAccepted = firstWrite.withUnsafeBufferPointer { buffer in
        ring.write(buffer, frameCount: 3)
    }

    var firstReadDestination = Array<Float>(repeating: -1, count: 2)
    let firstRead = firstReadDestination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 2)
    }

    let secondAccepted = secondWrite.withUnsafeBufferPointer { buffer in
        ring.write(buffer, frameCount: 3)
    }

    var finalDestination = Array<Float>(repeating: -1, count: 4)
    let finalRead = finalDestination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 4)
    }

    #expect(firstAccepted == 3)
    #expect(firstRead == 2)
    #expect(firstReadDestination == [1, 2])
    #expect(secondAccepted == 3)
    #expect(finalRead == 4)
    #expect(finalDestination == [3, 4, 5, 6])
}

@Test("SPSC ring buffer reports dropped frames and overflow count")
func spscRingBufferReportsDroppedFramesAndOverflowCount() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4, channelCount: 1)
    let source: [Float] = [1, 2, 3, 4, 5, 6]

    let accepted = source.withUnsafeBufferPointer { buffer in
        ring.write(buffer, frameCount: 6)
    }

    #expect(accepted == 4)
    #expect(ring.availableFrames == 4)
    #expect(ring.droppedFrames == 2)
    #expect(ring.overflowCount == 1)
}

@Test("SPSC ring buffer empty read leaves destination unchanged")
func spscRingBufferEmptyReadLeavesDestinationUnchanged() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 4, channelCount: 1)
    var destination: [Float] = [99, 98, 97]

    let read = destination.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 3)
    }

    #expect(read == 0)
    #expect(destination == [99, 98, 97])
}

@Test("SPSC ring buffer bounded read stops at captured write sequence")
func spscRingBufferBoundedReadStopsAtCapturedWriteSequence() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 8, channelCount: 1)
    let first: [Float] = [1, 2, 3]
    let second: [Float] = [4, 5, 6]

    #expect(first.withUnsafeBufferPointer { ring.write($0, frameCount: 3) } == 3)
    let boundary = ring.writeSequenceSnapshot
    #expect(second.withUnsafeBufferPointer { ring.write($0, frameCount: 3) } == 3)

    var firstRead = Array<Float>(repeating: -1, count: 6)
    let boundedRead = firstRead.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 6, upToWriteSequence: boundary)
    }

    var secondRead = Array<Float>(repeating: -1, count: 3)
    let remainingRead = secondRead.withUnsafeMutableBufferPointer { buffer in
        ring.read(into: buffer, maxFrames: 3)
    }

    #expect(boundedRead == 3)
    #expect(Array(firstRead.prefix(3)) == first)
    #expect(Array(firstRead.suffix(3)) == [-1, -1, -1])
    #expect(remainingRead == 3)
    #expect(secondRead == second)
}

@Test("SPSC ring buffer rejects invalid capacity and channel count")
func spscRingBufferRejectsInvalidCapacityAndChannelCount() {
    #expect(throws: SPSCRingBufferError.invalidCapacity(0)) {
        _ = try SPSCRingBuffer(capacityFrames: 0, channelCount: 1)
    }
    #expect(throws: SPSCRingBufferError.invalidChannelCount(0)) {
        _ = try SPSCRingBuffer(capacityFrames: 1, channelCount: 0)
    }
}

@Test("SPSC ring buffer transfers numbered frames between dispatch queues without reordering")
func spscRingBufferTransfersNumberedFramesBetweenDispatchQueuesWithoutReordering() throws {
    let ring = try SPSCRingBuffer(capacityFrames: 256, channelCount: 1)
    let totalFrames = 100_000
    let group = DispatchGroup()
    let producer = DispatchQueue(label: "SPSCRingBufferTests.producer")
    let consumer = DispatchQueue(label: "SPSCRingBufferTests.consumer")

    final class TransferState: @unchecked Sendable {
        let lock = NSLock()
        var received: [Float] = []
        var unexpected: String?

        init(capacity: Int) {
            received.reserveCapacity(capacity)
        }

        func record(_ values: ArraySlice<Float>) {
            lock.lock()
            received.append(contentsOf: values)
            lock.unlock()
        }

        func fail(_ message: String) {
            lock.lock()
            if unexpected == nil {
                unexpected = message
            }
            lock.unlock()
        }
    }

    let state = TransferState(capacity: totalFrames)

    group.enter()
    producer.async {
        var nextFrame = 0
        var source = Array<Float>(repeating: 0, count: 32)

        while nextFrame < totalFrames {
            let frameCount = min(source.count, totalFrames - nextFrame)
            for offset in 0..<frameCount {
                source[offset] = Float(nextFrame + offset)
            }

            let accepted = source.withUnsafeBufferPointer { buffer in
                ring.write(
                    UnsafeBufferPointer(rebasing: buffer[..<frameCount]),
                    frameCount: frameCount
                )
            }

            if accepted > 0 {
                nextFrame += accepted
            } else {
                sched_yield()
            }
        }

        group.leave()
    }

    group.enter()
    consumer.async {
        var expected = 0
        var destination = Array<Float>(repeating: -1, count: 37)

        while expected < totalFrames {
            let read = destination.withUnsafeMutableBufferPointer { buffer in
                ring.read(into: buffer, maxFrames: buffer.count)
            }

            if read == 0 {
                sched_yield()
                continue
            }

            for offset in 0..<read {
                let actual = destination[offset]
                if actual != Float(expected + offset) {
                    state.fail("expected \(expected + offset), got \(actual)")
                    group.leave()
                    return
                }
            }

            state.record(destination.prefix(read))
            expected += read
        }

        group.leave()
    }

    let completed = group.wait(timeout: .now() + 10)

    #expect(completed == .success)
    #expect(state.unexpected == nil)
    state.lock.lock()
    let received = state.received
    state.lock.unlock()
    #expect(received.count == totalFrames)
    #expect(received.first == 0)
    #expect(received.last == Float(totalFrames - 1))
}
