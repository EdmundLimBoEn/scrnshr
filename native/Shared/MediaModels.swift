// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

import Foundation

public enum PeerRole: String, Codable, Sendable {
    case sender, receiver
}

public struct ICEServer: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public enum RTCSignal: Codable, Equatable, Sendable {
    case offer(String)
    case answer(String)
    case ice(candidate: String, sdpMid: String?, sdpMLineIndex: Int32)
    case restart

    private enum CodingKeys: String, CodingKey {
        case type, sdp, candidate, sdpMid, sdpMLineIndex
    }

    private enum Kind: String, Codable {
        case offer, answer, ice, restart
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .offer:
            self = .offer(try values.decode(String.self, forKey: .sdp))
        case .answer:
            self = .answer(try values.decode(String.self, forKey: .sdp))
        case .ice:
            let index = try values.decode(Int32.self, forKey: .sdpMLineIndex)
            guard index >= 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sdpMLineIndex, in: values,
                    debugDescription: "An ICE media line index cannot be negative."
                )
            }
            self = .ice(
                candidate: try values.decode(String.self, forKey: .candidate),
                sdpMid: try values.decodeIfPresent(String.self, forKey: .sdpMid),
                sdpMLineIndex: index
            )
        case .restart:
            self = .restart
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .offer(let sdp):
            try values.encode(Kind.offer, forKey: .type)
            try values.encode(sdp, forKey: .sdp)
        case .answer(let sdp):
            try values.encode(Kind.answer, forKey: .type)
            try values.encode(sdp, forKey: .sdp)
        case .ice(let candidate, let mid, let index):
            try values.encode(Kind.ice, forKey: .type)
            try values.encode(candidate, forKey: .candidate)
            try values.encodeIfPresent(mid, forKey: .sdpMid)
            try values.encode(index, forKey: .sdpMLineIndex)
        case .restart:
            try values.encode(Kind.restart, forKey: .type)
        }
    }
}

public enum CaptureStatus: String, Codable, Equatable, Sendable {
    case ready, sharing, stopped
}

public enum MediaConnectionState: String, Codable, Equatable, Sendable {
    case idle, connecting, connected, reconnecting, failed, closed
}

struct CaptureStatusMessage: Codable, Equatable {
    let type: String
    let status: CaptureStatus

    init(status: CaptureStatus) {
        type = "capture-status"
        self.status = status
    }

    var isValid: Bool { type == "capture-status" }
}

struct CaptureHeartbeatWatchdog {
    private(set) var lastReceivedAt: TimeInterval
    static let timeout: TimeInterval = 8

    init(startedAt: TimeInterval) { lastReceivedAt = startedAt }

    mutating func received(at time: TimeInterval) {
        lastReceivedAt = max(lastReceivedAt, time)
    }

    func isExpired(at time: TimeInterval) -> Bool {
        time - lastReceivedAt >= Self.timeout
    }
}

/// EXIF orientation is applied at the frame boundary, before native rendering.
struct ScreenFrameOrientation: Equatable {
    let rotationDegrees: Int
    let mirrorBeforeRotation: Bool

    init(exifValue: UInt32) {
        switch exifValue {
        case 2: self.init(rotationDegrees: 0, mirrorBeforeRotation: true)
        case 3: self.init(rotationDegrees: 180, mirrorBeforeRotation: false)
        case 4: self.init(rotationDegrees: 180, mirrorBeforeRotation: true)
        case 5: self.init(rotationDegrees: 270, mirrorBeforeRotation: true)
        case 6: self.init(rotationDegrees: 90, mirrorBeforeRotation: false)
        case 7: self.init(rotationDegrees: 90, mirrorBeforeRotation: true)
        case 8: self.init(rotationDegrees: 270, mirrorBeforeRotation: false)
        default: self.init(rotationDegrees: 0, mirrorBeforeRotation: false)
        }
    }

    private init(rotationDegrees: Int, mirrorBeforeRotation: Bool) {
        self.rotationDegrees = rotationDegrees
        self.mirrorBeforeRotation = mirrorBeforeRotation
    }
}
