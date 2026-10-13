// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AVFAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
@preconcurrency import WebRTC
import XCTest
@testable import ScrnshrPhone

final class PeerConnectionTests: XCTestCase {
    @MainActor
    func testNativePeersDecodeInjectedVideoAndStopCaptureThroughTheDataChannel() async throws {
        let originalAudioCategory = AVAudioSession.sharedInstance().category
        let senderAudio = AppAudioDevice()
        let receiverAudio = AppAudioDevice()
        let sender = WebRTCSession(role: .sender, audioDevice: senderAudio)
        let receiver = WebRTCSession(role: .receiver, audioDevice: receiverAudio)
        let renderer = DecodedFrameRecorder()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        var failures: [String] = []
        var remoteStatus: CaptureStatus = .ready
        var firstOffer: RTCSignal?
        var offerCount = 0
        var answerCount = 0
        var frameTask: Task<Void, Never>?

        defer {
            frameTask?.cancel()
            receiver.remoteVideoTrack?.remove(renderer)
            sender.onSignal = nil
            receiver.onSignal = nil
            sender.onError = nil
            receiver.onError = nil
            sender.close()
            receiver.close()
            XCTAssertTrue(senderAudio.terminateDevice())
            XCTAssertTrue(receiverAudio.terminateDevice())
        }

        sender.onError = { message in failures.append(message); XCTFail("Sender: \(message)") }
        receiver.onError = { message in failures.append(message); XCTFail("Receiver: \(message)") }
        sender.onSignal = { [weak receiver] signal in
            if case .offer = signal {
                offerCount += 1
                if firstOffer == nil { firstOffer = signal }
                receiver?.accept(signal)
                // A retry can arrive while the first remote description is still being applied.
                if offerCount == 1 { receiver?.accept(signal) }
            } else {
                receiver?.accept(signal)
            }
        }
        receiver.onSignal = { [weak sender] signal in
            if case .answer = signal { answerCount += 1 }
            sender?.accept(signal)
        }
        receiver.onVideoTrack = { track in track.add(renderer) }
        receiver.onCaptureStatus = { remoteStatus = $0 }
        receiver.setRemoteAudioMuted(true)
        receiver.configure(iceServers: [])
        sender.configure(iceServers: [])
        sender.sendCaptureStatus(.sharing)

        frameTask = Task { @MainActor in
            while !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
                do {
                    sender.sendVideo(try Self.makeVideoSample())
                    try await Task.sleep(nanoseconds: 50_000_000)
                } catch is CancellationError {
                    return
                } catch {
                    failures.append(error.localizedDescription)
                    XCTFail("Synthetic frame: \(error)")
                    return
                }
            }
        }
        sender.startOffer()

        let connectedAndDecoded = await waitUntil(deadline: deadline) {
            !failures.isEmpty || (
                sender.connectionState == .connected && receiver.connectionState == .connected &&
                remoteStatus == .sharing && renderer.snapshot != nil
            )
        }
        XCTAssertTrue(connectedAndDecoded, "Native ICE, capture-status, and decoded video must arrive within 20 seconds.")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertEqual(sender.connectionState, .connected)
        XCTAssertEqual(receiver.connectionState, .connected)
        XCTAssertEqual(remoteStatus, .sharing)
        XCTAssertTrue(senderAudio.isRecording, "The sender must use the custom app-audio device.")
        XCTAssertEqual(AVAudioSession.sharedInstance().category, originalAudioCategory)
        let decoded = try XCTUnwrap(renderer.snapshot, "The remote RTCVideoTrack must deliver a decoded frame.")
        XCTAssertEqual(decoded.width, 160)
        XCTAssertEqual(decoded.height, 120)
        XCTAssertGreaterThan(decoded.lumaContrast, 100, "The injected black/white marker must survive native encoding and decoding.")
        XCTAssertEqual(offerCount, 1)
        XCTAssertEqual(answerCount, 1, "An in-flight duplicate offer must not create a second answer.")

        receiver.accept(try XCTUnwrap(firstOffer))
        let retried = await waitUntil(deadline: deadline) { answerCount == 2 || !failures.isEmpty }
        XCTAssertTrue(retried, "An offer retry must receive the cached answer.")
        XCTAssertEqual(answerCount, 2)
        XCTAssertEqual(sender.connectionState, .connected)
        XCTAssertEqual(receiver.connectionState, .connected)

        frameTask?.cancel()
        sender.sendCaptureStatus(.stopped)
        let stopped = await waitUntil(deadline: deadline) { remoteStatus == .stopped || !failures.isEmpty }
        XCTAssertTrue(stopped, "Stopping capture must reach the receiver through the native data channel.")
        XCTAssertEqual(remoteStatus, .stopped)
        sender.startOffer()
        sender.accept(.restart)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(offerCount, 1, "Stopped capture must not authorize a new offer or ICE restart.")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    @MainActor
    private func waitUntil(deadline: TimeInterval, condition: () -> Bool) async -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private static func makeVideoSample() throws -> CMSampleBuffer {
        let width = 160
        let height = 120
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
        var allocated: CVPixelBuffer?
        try requireSuccess(CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &allocated
        ))
        let buffer = try XCTUnwrap(allocated)
        try requireSuccess(CVPixelBufferLockBaseAddress(buffer, []))
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * stride + x * 4
                    let value: UInt8 = x < width / 2 ? 0 : 255
                    base[offset] = value
                    base[offset + 1] = value
                    base[offset + 2] = value
                    base[offset + 3] = 255
                }
            }
        }
        var format: CMVideoFormatDescription?
        try requireSuccess(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format
        ))
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 20),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        try requireSuccess(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample
        ))
        return try XCTUnwrap(sample)
    }

    private static func requireSuccess(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

private final class DecodedFrameRecorder: NSObject, RTCVideoRenderer {
    struct Snapshot {
        let width: Int
        let height: Int
        let lumaContrast: Int
    }

    private let lock = NSLock()
    private var recorded: Snapshot?

    var snapshot: Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let pixels = frame.buffer.toI420()
        let width = Int(pixels.width)
        let height = Int(pixels.height)
        guard width > 3, height > 0 else { return }
        let middle = (height / 2) * Int(pixels.strideY)
        let left = Int(pixels.dataY[middle + width / 4])
        let right = Int(pixels.dataY[middle + width * 3 / 4])
        let captured = Snapshot(width: width, height: height, lumaContrast: abs(right - left))
        lock.lock()
        recorded = captured
        lock.unlock()
    }
}
