// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

import CoreMedia
import XCTest
@testable import ScrnshrMac

final class WebRTCModelsTests: XCTestCase {
    func testTaggedSignalsRoundTrip() throws {
        let signals: [RTCSignal] = [
            .offer("v=0\r\na=sendonly\r\n"), .answer("v=0\r\na=recvonly\r\n"),
            .ice(candidate: "candidate:1 1 udp 2122260223 192.0.2.1 5000 typ host", sdpMid: "0", sdpMLineIndex: 0),
            .ice(candidate: "candidate:2 1 tcp 1 192.0.2.2 443 typ relay", sdpMid: nil, sdpMLineIndex: 1),
            .restart
        ]
        for signal in signals {
            let data = try JSONEncoder().encode(signal)
            XCTAssertEqual(try JSONDecoder().decode(RTCSignal.self, from: data), signal)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil(object["type"])
            XCTAssertNil(object["offer"])
        }
    }

    func testWireFormatMatchesBrowserSignaling() throws {
        let data = Data(#"{"type":"ice","candidate":"candidate:1","sdpMid":null,"sdpMLineIndex":2}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(RTCSignal.self, from: data),
            .ice(candidate: "candidate:1", sdpMid: nil, sdpMLineIndex: 2)
        )
        let offer = Data(#"{"type":"offer","sdp":"v=0\r\n"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RTCSignal.self, from: offer), .offer("v=0\r\n"))
    }

    func testMalformedSignalsAreRejected() {
        for json in [
            #"{"type":"offer"}"#,
            #"{"type":"unexpected","sdp":"v=0"}"#,
            #"{"type":"ice","candidate":"candidate:1","sdpMLineIndex":-1}"#,
            #"{"type":"ice","candidate":"candidate:1","sdpMLineIndex":2147483648}"#
        ] {
            XCTAssertThrowsError(try JSONDecoder().decode(RTCSignal.self, from: Data(json.utf8)))
        }
    }

    func testICECredentialsAndSTUNRoundTrip() throws {
        let servers = [
            ICEServer(urls: ["stun:stun.example.com:3478"]),
            ICEServer(urls: ["turn:turn.example.com:3478", "turns:turn.example.com:443?transport=tcp"], username: "expiring-user", credential: "credential")
        ]
        XCTAssertEqual(try JSONDecoder().decode([ICEServer].self, from: JSONEncoder().encode(servers)), servers)
    }

    func testCaptureControlMessagesHaveASeparateType() throws {
        for status in [CaptureStatus.ready, .sharing, .stopped] {
            let message = CaptureStatusMessage(status: status)
            let decoded = try JSONDecoder().decode(CaptureStatusMessage.self, from: JSONEncoder().encode(message))
            XCTAssertEqual(decoded, message)
            XCTAssertTrue(decoded.isValid)
        }
        let wrongType = Data(#"{"type":"offer","status":"sharing"}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(CaptureStatusMessage.self, from: wrongType).isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(CaptureStatusMessage.self, from: Data(#"{"type":"capture-status","status":"microphone"}"#.utf8)))
    }

    func testAllEXIFOrientationsMapOnce() {
        let expected: [(UInt32, Int, Bool)] = [
            (1, 0, false), (2, 0, true), (3, 180, false), (4, 180, true),
            (5, 270, true), (6, 90, false), (7, 90, true), (8, 270, false)
        ]
        for (raw, rotation, mirrored) in expected {
            let orientation = ScreenFrameOrientation(exifValue: raw)
            XCTAssertEqual(orientation.rotationDegrees, rotation)
            XCTAssertEqual(orientation.mirrorBeforeRotation, mirrored)
        }
        XCTAssertEqual(ScreenFrameOrientation(exifValue: 999), ScreenFrameOrientation(exifValue: 1))
    }

    func testEXIFTransformsPreserveAnAsymmetricGrid() {
        // Clockwise corners of a labeled image: A B on top, D C underneath.
        let corners: [(Double, Double)] = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
        let expectedDestinations = [
            [0, 1, 2, 3], [1, 0, 3, 2], [2, 3, 0, 1], [3, 2, 1, 0],
            [0, 3, 2, 1], [1, 2, 3, 0], [2, 1, 0, 3], [3, 0, 1, 2]
        ]
        for raw in 1...8 {
            let orientation = ScreenFrameOrientation(exifValue: UInt32(raw))
            let angle = Double(orientation.rotationDegrees) * .pi / 180
            let destinations = corners.map { point -> Int in
                let (x, y) = point
                let reflectedX = orientation.mirrorBeforeRotation ? -x : x
                let rotatedX = reflectedX * cos(angle) - y * sin(angle)
                let rotatedY = reflectedX * sin(angle) + y * cos(angle)
                return corners.firstIndex { abs($0.0 - rotatedX) < 0.0001 && abs($0.1 - rotatedY) < 0.0001 }!
            }
            XCTAssertEqual(destinations, expectedDestinations[raw - 1], "EXIF orientation \(raw)")
        }
    }

    func testCaptureClockRetainsPresentationTiming() {
        let fallback = CMTime(value: 99, timescale: 1)
        XCTAssertEqual(CaptureFrameClock.timestampNanoseconds(presentationTime: CMTime(value: 480, timescale: 48_000), fallbackHostTime: fallback), 10_000_000)
        XCTAssertEqual(CaptureFrameClock.timestampNanoseconds(presentationTime: CMTime(value: 2_400, timescale: 48_000), fallbackHostTime: fallback), 50_000_000)
        XCTAssertEqual(CaptureFrameClock.timestampNanoseconds(presentationTime: .invalid, fallbackHostTime: fallback), 99_000_000_000)
        XCTAssertNil(CaptureFrameClock.timestampNanoseconds(presentationTime: .invalid, fallbackHostTime: .invalid))
        XCTAssertNil(CaptureFrameClock.timestampNanoseconds(presentationTime: CMTime(value: -1, timescale: 1), fallbackHostTime: fallback))
    }

    func testStaticPictureDoesNotExpireWhileCaptureHeartbeatsArrive() {
        var watchdog = CaptureHeartbeatWatchdog(startedAt: 100)
        for time in stride(from: 102.0, through: 160.0, by: 2) {
            watchdog.received(at: time)
            XCTAssertFalse(watchdog.isExpired(at: time + 1))
        }
        XCTAssertFalse(watchdog.isExpired(at: 167.999))
        XCTAssertTrue(watchdog.isExpired(at: 168))
    }

    func testCaptureRestartAcceptsAResetPresentationClock() {
        var clock = CaptureFrameClock()
        let fallback = CMTime(value: 100, timescale: 1)
        XCTAssertNotNil(clock.accept(presentationTime: CMTime(value: 10, timescale: 1), fallbackHostTime: fallback))
        XCTAssertNil(clock.accept(presentationTime: CMTime(value: 9, timescale: 1), fallbackHostTime: fallback))
        XCTAssertNil(clock.accept(presentationTime: CMTime(value: 10, timescale: 1), fallbackHostTime: fallback))
        clock.reset()
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: 1, timescale: 1), fallbackHostTime: fallback), 1_000_000_000)
    }

    func testCaptureHeartbeatUsesMonotonicReceiptTime() {
        var watchdog = CaptureHeartbeatWatchdog(startedAt: 100)
        watchdog.received(at: 104)
        watchdog.received(at: 102)
        XCTAssertEqual(watchdog.lastReceivedAt, 104)
        XCTAssertTrue(watchdog.isExpired(at: 112))
    }

    func testStaticRefreshUsesFreshMonotonicHostTimeWithoutChangingCapturedFrameTiming() {
        var clock = CaptureFrameClock()
        let captured = CMTime(value: 10, timescale: 1)
        XCTAssertEqual(clock.accept(presentationTime: captured, fallbackHostTime: .invalid), 10_000_000_000)
        XCTAssertEqual(clock.refreshTimestamp(hostTime: CMTime(value: 12, timescale: 1)), 12_000_000_000)
        XCTAssertEqual(clock.refreshTimestamp(hostTime: CMTime(value: 11, timescale: 1)), 12_001_000_000)
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: 13, timescale: 1), fallbackHostTime: .invalid), 13_000_000_000)
        XCTAssertNil(clock.refreshTimestamp(hostTime: .invalid))
        clock.reset()
        XCTAssertEqual(clock.accept(presentationTime: captured, fallbackHostTime: .invalid), 10_000_000_000)
    }

    func testRefreshCannotDiscardANewerRealCaptureWithAnEarlierPresentationTimestamp() {
        var clock = CaptureFrameClock()
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: 10, timescale: 1), fallbackHostTime: .invalid), 10_000_000_000)
        XCTAssertEqual(clock.refreshTimestamp(hostTime: CMTime(value: 12, timescale: 1)), 12_000_000_000)
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: 11, timescale: 1), fallbackHostTime: .invalid), 12_001_000_000)
        XCTAssertNil(clock.accept(presentationTime: CMTime(value: 10_500, timescale: 1_000), fallbackHostTime: .invalid))
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: 13, timescale: 1), fallbackHostTime: .invalid), 13_000_000_000)

        clock.reset()
        XCTAssertEqual(clock.accept(presentationTime: CMTime(value: Int64.max, timescale: 1_000_000_000), fallbackHostTime: .invalid), Int64.max)
        XCTAssertNil(clock.refreshTimestamp(hostTime: CMTime(value: Int64.max, timescale: 1_000_000_000)))
    }
}
