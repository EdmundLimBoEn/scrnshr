// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AVFAudio
import AudioToolbox
import CoreMedia
import WebRTC
import XCTest
@testable import ScrnshrPhone

final class AppAudioDeviceTests: XCTestCase {
    private var device: AppAudioDevice!
    private var audioDelegate: TestAudioDeviceDelegate!

    override func setUp() {
        super.setUp()
        device = AppAudioDevice()
        audioDelegate = TestAudioDeviceDelegate()
        XCTAssertTrue(device.initialize(with: audioDelegate))
        XCTAssertTrue(device.initializeRecording())
        XCTAssertTrue(device.startRecording())
    }

    override func tearDown() {
        XCTAssertTrue(device.stopRecording())
        XCTAssertTrue(device.terminateDevice())
        device = nil
        audioDelegate = nil
        super.tearDown()
    }

    func testStereoUsesRenderCallbackAndPreservesBothChannels() throws {
        let delivered = expectation(description: "stereo packet")
        audioDelegate.onPacket = { packet in if packet.index == 0 { delivered.fulfill() } }
        let values = (0..<480).flatMap { _ in [Float(0.5), Float(-0.5)] }
        try assertPush(makeSample(values))
        wait(for: [delivered], timeout: 2)
        let packet = try XCTUnwrap(audioDelegate.packets.first)
        XCTAssertTrue(packet.usedRenderCallback)
        XCTAssertEqual(packet.frames, 480)
        XCTAssertEqual(packet.samples.count, 960)
        XCTAssertTrue(stride(from: 0, to: 960, by: 2).allSatisfy {
            packet.samples[$0] == 16_384 && packet.samples[$0 + 1] == -16_384
        })
        XCTAssertGreaterThan(packet.hostTime, 0)
    }

    func testMonoUpmixClipsAndReplacesNonfiniteSamplesWithSilence() throws {
        let delivered = expectation(description: "converted mono packet")
        audioDelegate.onPacket = { packet in if packet.index == 0 { delivered.fulfill() } }
        let values: [Float] = [-2, 2, .nan, .infinity] + Array(repeating: 0, count: 476)
        try assertPush(makeSample(values, channels: 1))
        wait(for: [delivered], timeout: 2)
        let packet = try XCTUnwrap(audioDelegate.packets.first)
        XCTAssertEqual(Array(packet.samples.prefix(8)), [.min, .min, .max, .max, 0, 0, 0, 0])
    }

    func testPlanarStereoIsInterleavedForWebRTC() throws {
        let delivered = expectation(description: "planar stereo packet")
        audioDelegate.onPacket = { packet in if packet.index == 0 { delivered.fulfill() } }
        let values = Array(repeating: Float(0.5), count: 480) + Array(repeating: Float(-0.5), count: 480)
        try assertPush(makeSample(values, planar: true))
        wait(for: [delivered], timeout: 2)
        let packet = try XCTUnwrap(audioDelegate.packets.first)
        XCTAssertTrue(stride(from: 0, to: 960, by: 2).allSatisfy {
            packet.samples[$0] == 16_384 && packet.samples[$0 + 1] == -16_384
        })
    }

    func testStarvationProducesSilenceAndMonotonicHostTimestamps() throws {
        let delivered = expectation(description: "three packets")
        delivered.expectedFulfillmentCount = 3
        audioDelegate.onPacket = { packet in if packet.index < 3 { delivered.fulfill() } }
        try assertPush(makeSample(Array(repeating: 0.25, count: 960)))
        wait(for: [delivered], timeout: 2)
        XCTAssertTrue(device.stopRecording())
        let packets = Array(audioDelegate.packets.prefix(3))
        XCTAssertEqual(packets.count, 3)
        guard packets.count == 3 else { return }
        XCTAssertTrue(packets[1].samples.allSatisfy { $0 == 0 })
        XCTAssertTrue(packets[2].samples.allSatisfy { $0 == 0 })
        XCTAssertLessThan(packets[0].hostTime, packets[1].hostTime)
        XCTAssertLessThan(packets[1].hostTime, packets[2].hostTime)
        XCTAssertGreaterThanOrEqual(device.silentAudioFrames, 960)
    }

    func testRejectsUnexpectedSampleRateWithoutChangingAudioSessionCategory() throws {
        let category = AVAudioSession.sharedInstance().category
        XCTAssertFalse(device.push(sampleBuffer: try makeSample(Array(repeating: 0.25, count: 960), rate: 44_100)))
        XCTAssertEqual(device.rejectedAudioBuffers, 1)
        XCTAssertEqual(device.receivedAudioFrames, 0)
        XCTAssertEqual(AVAudioSession.sharedInstance().category, category)
        XCTAssertTrue(audioDelegate.packets.isEmpty)
    }

    func testOversizedInputIsBoundedAndResetStopsDeliveryUntilNewCapture() throws {
        let delivered = expectation(description: "bounded packet")
        audioDelegate.onPacket = { packet in if packet.index == 0 { delivered.fulfill() } }
        try assertPush(makeSample(Array(repeating: 0.25, count: 28_800)))
        wait(for: [delivered], timeout: 2)
        XCTAssertGreaterThanOrEqual(device.droppedAudioFrames, 9_600)
        device.reset()
        let afterReset = audioDelegate.packets.count
        let unexpected = expectation(description: "no delivery after reset")
        unexpected.isInverted = true
        audioDelegate.onPacket = { _ in unexpected.fulfill() }
        wait(for: [unexpected], timeout: 0.1)
        XCTAssertEqual(audioDelegate.packets.count, afterReset)
    }

    func testStaleInterruptionEndCannotResumeANewerInterruption() throws {
        audioDelegate.pauseAsyncDispatch()
        postInterruption(.ended)
        postInterruption(.began)
        audioDelegate.flushAsyncDispatch()

        let unexpected = expectation(description: "interrupted audio stays stopped")
        unexpected.isInverted = true
        audioDelegate.onPacket = { _ in unexpected.fulfill() }
        try assertPush(makeSample(Array(repeating: 0.25, count: 960)))
        wait(for: [unexpected], timeout: 0.1)
        XCTAssertTrue(audioDelegate.packets.isEmpty)

        postInterruption(.ended)
        audioDelegate.flushAsyncDispatch()
        let delivered = expectation(description: "audio resumes after current interruption ends")
        audioDelegate.onPacket = { packet in if packet.index == 0 { delivered.fulfill() } }
        try assertPush(makeSample(Array(repeating: 0.25, count: 960)))
        wait(for: [delivered], timeout: 2)
    }

    func testCallbackCanReadStateAndStopRecordingReentrantly() throws {
        let delivered = expectation(description: "reentrant state query and stop complete")
        let device = self.device!
        audioDelegate.onPacket = { [weak device] packet in
            guard packet.index == 0, let device else { return }
            XCTAssertTrue(device.isRecording)
            XCTAssertTrue(device.isInitialized)
            XCTAssertTrue(device.stopRecording())
            XCTAssertFalse(device.isRecording)
            delivered.fulfill()
        }
        try assertPush(makeSample(Array(repeating: 0.25, count: 960)))
        wait(for: [delivered], timeout: 2)
        XCTAssertFalse(device.isRecording)
        XCTAssertEqual(audioDelegate.packets.count, 1)
    }

    func testCallbackCanTerminateDeviceWithoutJoiningItself() throws {
        let delivered = expectation(description: "reentrant termination completes")
        let device = self.device!
        audioDelegate.onPacket = { [weak device] packet in
            guard packet.index == 0, let device else { return }
            XCTAssertTrue(device.terminateDevice())
            XCTAssertFalse(device.isInitialized)
            XCTAssertFalse(device.isRecording)
            delivered.fulfill()
        }
        try assertPush(makeSample(Array(repeating: 0.25, count: 960)))
        wait(for: [delivered], timeout: 2)
        XCTAssertFalse(device.isInitialized)
        XCTAssertEqual(audioDelegate.packets.count, 1)
    }

    private func postInterruption(_ type: AVAudioSession.InterruptionType) {
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue]
        )
    }

    private func assertPush(_ sample: CMSampleBuffer, file: StaticString = #filePath, line: UInt = #line) {
        guard !device.push(sampleBuffer: sample) else { return }
        let metadata: String
        if let description = CMSampleBufferGetFormatDescription(sample),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            let format = asbd.pointee
            metadata = "rate=\(format.mSampleRate) channels=\(format.mChannelsPerFrame) flags=\(format.mFormatFlags) " +
                "bits=\(format.mBitsPerChannel) bytesPerFrame=\(format.mBytesPerFrame) " +
                "bytesPerPacket=\(format.mBytesPerPacket) framesPerPacket=\(format.mFramesPerPacket)"
        } else {
            metadata = "missing audio format"
        }
        XCTFail("App audio rejected: \(device.lastAudioRejectionReason); OSStatus \(device.lastRejectedAudioStatus); " +
                "frames=\(CMSampleBufferGetNumSamples(sample)) \(metadata)", file: file, line: line)
    }

    private func makeSample(_ values: [Float], channels: Int = 2, rate: Double = 48_000, planar: Bool = false) throws -> CMSampleBuffer {
        let bytesPerFrame = UInt32((planar ? 1 : channels) * MemoryLayout<Float>.size)
        var format = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        try requireSuccess(CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        ))
        var block: CMBlockBuffer?
        let byteCount = values.count * MemoryLayout<Float>.size
        try requireSuccess(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: 0, blockBufferOut: &block
        ))
        try values.withUnsafeBytes { bytes in
            try requireSuccess(CMBlockBufferReplaceDataBytes(
                with: try XCTUnwrap(bytes.baseAddress), blockBuffer: try XCTUnwrap(block),
                offsetIntoDestination: 0, dataLength: byteCount
            ))
        }
        var sample: CMSampleBuffer?
        try requireSuccess(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: try XCTUnwrap(block), formatDescription: try XCTUnwrap(description),
            sampleCount: values.count / channels, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            packetDescriptions: nil, sampleBufferOut: &sample
        ))
        return try XCTUnwrap(sample)
    }

    private func requireSuccess(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

private final class TestAudioDeviceDelegate: NSObject, RTCAudioDeviceDelegate {
    struct Packet {
        let index: Int
        let samples: [Int16]
        let frames: UInt32
        let hostTime: UInt64
        let usedRenderCallback: Bool
    }

    private let lock = NSLock()
    private let admQueue = DispatchQueue(label: "scrnshr.tests.audio-adm")
    private var recorded: [Packet] = []
    private var handler: ((Packet) -> Void)?
    private var holdDispatch = false
    private var pendingDispatch: [() -> Void] = []

    var packets: [Packet] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var onPacket: ((Packet) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return handler
        }
        set {
            lock.lock()
            handler = newValue
            lock.unlock()
        }
    }

    let preferredInputSampleRate = 48_000.0
    let preferredInputIOBufferDuration = 0.01
    let preferredOutputSampleRate = 48_000.0
    let preferredOutputIOBufferDuration = 0.01

    lazy var deliverRecordedData: RTCAudioDeviceDeliverRecordedDataBlock = { [weak self] flags, timestamp, bus, frames, input, context, render in
        guard let self, let render, input == nil else { return kAudio_ParamError }
        var samples = Array(repeating: Int16(0), count: Int(frames) * 2)
        let byteCount = UInt32(samples.count * MemoryLayout<Int16>.size)
        let status = samples.withUnsafeMutableBytes { bytes -> OSStatus in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: byteCount, mData: bytes.baseAddress
            ))
            return withUnsafeMutablePointer(to: &buffers) {
                render(flags, timestamp, bus, frames, $0, context)
            }
        }
        guard status == noErr else { return status }
        lock.lock()
        let packet = Packet(index: recorded.count, samples: samples, frames: frames,
                            hostTime: timestamp.pointee.mHostTime, usedRenderCallback: true)
        recorded.append(packet)
        let callback = handler
        lock.unlock()
        callback?(packet)
        return noErr
    }

    let getPlayoutData: RTCAudioDeviceGetPlayoutDataBlock = { _, _, _, _, _ in noErr }

    func notifyAudioInputParametersChange() {}
    func notifyAudioOutputParametersChange() {}
    func notifyAudioInputInterrupted() {}
    func notifyAudioOutputInterrupted() {}
    func pauseAsyncDispatch() {
        lock.lock()
        holdDispatch = true
        lock.unlock()
    }

    func flushAsyncDispatch() {
        lock.lock()
        let blocks = pendingDispatch
        pendingDispatch.removeAll()
        lock.unlock()
        admQueue.sync { blocks.forEach { $0() } }
    }

    func dispatchAsync(_ block: @escaping () -> Void) {
        lock.lock()
        if holdDispatch {
            pendingDispatch.append(block)
            lock.unlock()
        } else {
            lock.unlock()
            admQueue.async(execute: block)
        }
    }
    func dispatchSync(_ block: @escaping () -> Void) { block() }
}
