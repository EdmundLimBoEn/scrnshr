// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import CryptoKit
import Foundation

enum PairingError: LocalizedError {
    case invalidServer, invalidCode, expired, authenticationFailed, replayedSignal

    var errorDescription: String? {
        switch self {
        case .invalidServer: return "Enter an HTTPS signaling server address."
        case .invalidCode: return "This pairing code is invalid. Create a new session on the Mac."
        case .expired: return "This session has expired. Create a new session on the Mac."
        case .authenticationFailed: return "The peer's signaling message could not be authenticated."
        case .replayedSignal: return "An old signaling message was ignored."
        }
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        guard base64URL.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
        }) else { return nil }
        let padding = String(repeating: "=", count: (4 - base64URL.count % 4) % 4)
        self.init(base64Encoded: base64URL.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding)
    }
}

struct PairingCode: Codable, Equatable {
    // Match JOIN_DURATION_MS and SESSION_DURATION_MS in signaling/src/protocol.ts.
    private static let joinDuration: TimeInterval = 5 * 60
    private static let clockSkew: TimeInterval = 2 * 60
    static let maximumSessionDelay: TimeInterval = 2 * 60 * 60 + clockSkew

    let version: Int
    let server: URL
    let sessionId: String
    let joinToken: String
    let pairingKey: String
    let expiresAt: Date
    let joinExpiresAt: Date

    init(server: URL, sessionId: String, joinToken: String, expiresAt: Date) throws {
        self.version = 1
        self.server = try Self.validateServer(server)
        self.sessionId = sessionId
        self.joinToken = joinToken
        self.pairingKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64URL }
        self.expiresAt = expiresAt
        self.joinExpiresAt = min(expiresAt, .now.addingTimeInterval(Self.joinDuration))
        try validate(now: .now)
    }

    var url: URL {
        get throws {
            let data = try JSONEncoder().encode(self)
            var components = URLComponents()
            components.scheme = "scrnshr"
            components.host = "join"
            components.queryItems = [URLQueryItem(name: "data", value: data.base64URL)]
            guard let url = components.url else { throw PairingError.invalidCode }
            return url
        }
    }

    static func parse(_ text: String, now: Date = .now) throws -> PairingCode {
        guard text.utf8.count <= 8192,
              let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "scrnshr", components.host == "join",
              components.queryItems?.count == 1,
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value,
              let data = Data(base64URL: encoded) else { throw PairingError.invalidCode }
        let code = try JSONDecoder().decode(PairingCode.self, from: data)
        try code.validate(now: now)
        return code
    }

    func validate(now: Date) throws {
        guard version == 1, UUID(uuidString: sessionId) != nil,
              Data(base64URL: joinToken)?.count == 32,
              Data(base64URL: pairingKey)?.count == 32 else { throw PairingError.invalidCode }
        _ = try Self.validateServer(server)
        guard expiresAt > now, joinExpiresAt > now else { throw PairingError.expired }
        guard joinExpiresAt <= expiresAt,
              joinExpiresAt <= now.addingTimeInterval(Self.joinDuration + Self.clockSkew),
              expiresAt <= now.addingTimeInterval(Self.maximumSessionDelay) else {
            throw PairingError.invalidCode
        }
    }

    static func validateServer(_ url: URL) throws -> URL {
        guard url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else {
            throw PairingError.invalidServer
        }
        return url
    }
}

struct AuthenticatedSignal: Codable {
    let sessionId: String
    let role: PeerRole
    let generation: String
    let sequence: UInt64
    let signal: RTCSignal
}

struct SignalAuthenticationState: Codable {
    let generation: String?
    let sentSequence: UInt64
    let receivedSequence: UInt64?
    let retiredGenerations: Set<String>
    let localOfferIdentity: String?
}

struct SignalAuthenticator {
    private let sessionId: String
    private let role: PeerRole
    private let key: SymmetricKey
    private(set) var generation: String?
    private var sentSequence: UInt64 = 0
    private var receivedSequence: UInt64?
    private var retiredGenerations: Set<String> = []
    private var localOfferIdentity: String?

    var checkpoint: SignalAuthenticationState {
        SignalAuthenticationState(generation: generation, sentSequence: sentSequence,
                                  receivedSequence: receivedSequence, retiredGenerations: retiredGenerations,
                                  localOfferIdentity: localOfferIdentity)
    }

    init(sessionId: String, pairingKey: String, role: PeerRole,
         checkpoint: SignalAuthenticationState? = nil) throws {
        guard let bytes = Data(base64URL: pairingKey), bytes.count == 32 else { throw PairingError.invalidCode }
        self.sessionId = sessionId
        self.role = role
        self.key = SymmetricKey(data: bytes)
        if let checkpoint {
            generation = checkpoint.generation
            sentSequence = checkpoint.sentSequence
            receivedSequence = checkpoint.receivedSequence
            retiredGenerations = checkpoint.retiredGenerations
            localOfferIdentity = checkpoint.localOfferIdentity
        }
    }

    mutating func sign(_ signal: RTCSignal) throws -> (payload: String, mac: String) {
        if case .offer(let sdp) = signal {
            let identity = SDPNegotiationIdentity.make(sdp)
            if generation == nil || localOfferIdentity != identity {
                if let generation { retiredGenerations.insert(generation) }
                generation = UUID().uuidString
                sentSequence = 0
                receivedSequence = nil
            }
            localOfferIdentity = identity
        }
        guard let generation else { throw PairingError.authenticationFailed }
        let envelope = AuthenticatedSignal(sessionId: sessionId, role: role, generation: generation,
                                           sequence: sentSequence, signal: signal)
        sentSequence += 1
        let data = try JSONEncoder().encode(envelope)
        guard let payload = String(data: data, encoding: .utf8) else { throw PairingError.invalidCode }
        return (payload, Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64URL)
    }

    mutating func verify(payload: String, mac: String) throws -> RTCSignal {
        let data = Data(payload.utf8)
        guard data.count <= 65536, let signature = Data(base64URL: mac),
              HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: data, using: key) else {
            throw PairingError.authenticationFailed
        }
        let envelope = try JSONDecoder().decode(AuthenticatedSignal.self, from: data)
        guard envelope.sessionId == sessionId, envelope.role != role,
              UUID(uuidString: envelope.generation) != nil else {
            throw PairingError.authenticationFailed
        }
        if envelope.generation != generation {
            guard case .offer = envelope.signal, !retiredGenerations.contains(envelope.generation) else {
                throw PairingError.replayedSignal
            }
            if let generation { retiredGenerations.insert(generation) }
            generation = envelope.generation
            receivedSequence = nil
            sentSequence = 0
        }
        if let receivedSequence, envelope.sequence <= receivedSequence { throw PairingError.replayedSignal }
        receivedSequence = envelope.sequence
        return envelope.signal
    }
}
