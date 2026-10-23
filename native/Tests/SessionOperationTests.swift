// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AppKit
import CoreVideo
import Foundation
import WebRTC
import XCTest
@testable import ScrnshrMac

final class SessionOperationTests: XCTestCase {
    @MainActor
    func testFailedICECreationClearsPartialSessionAndCanRetry() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        let previousServer = UserDefaults.standard.object(forKey: "signaling-server")
        defer {
            KeychainStore.testMemory = nil
            UserDefaults.standard.set(previousServer, forKey: "signaling-server")
        }
        let signaling = DelayedEndSignalingClient()
        signaling.failICE = true
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "creation-test.")
        defer { coordinator.presentation.close() }
        coordinator.serverAddress = "https://pair.example.com"
        coordinator.ownerToken = "test-owner-credential"
        await coordinator.createInternetSession()
        XCTAssertFalse(coordinator.hasSession)
        XCTAssertFalse(coordinator.canRestore)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertEqual(coordinator.pairingURL, "")
        XCTAssertNotNil(coordinator.error)
        XCTAssertNil(try KeychainStore.load(account: "creation-test.session-receiver"))
        signaling.failICE = false
        await coordinator.createInternetSession()
        XCTAssertTrue(coordinator.hasSession)
        XCTAssertFalse(coordinator.pairingURL.isEmpty)
        XCTAssertNil(coordinator.error)
        await coordinator.stop()
    }

    @MainActor
    func testCreationExpiresWhileICEIsStillPending() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        let previousServer = UserDefaults.standard.object(forKey: "signaling-server")
        defer {
            KeychainStore.testMemory = nil
            UserDefaults.standard.set(previousServer, forKey: "signaling-server")
        }
        let signaling = DelayedEndSignalingClient()
        signaling.lifetime = 2
        let started = expectation(description: "ICE request suspended")
        signaling.iceStarted = { started.fulfill() }
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "expiry-test.")
        defer { coordinator.presentation.close() }
        coordinator.serverAddress = "https://pair.example.com"
        coordinator.ownerToken = "test-owner-credential"
        let creation = Task { await coordinator.createInternetSession() }
        await fulfillment(of: [started], timeout: 1)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(coordinator.hasSession, "Expiry must run before ICE returns")
        XCTAssertFalse(coordinator.canRestore)
        XCTAssertEqual(coordinator.pairingURL, "")
        signaling.finishICE()
        await creation.value
        XCTAssertFalse(coordinator.hasSession, "Late ICE must not restore the expired session")
        XCTAssertEqual(coordinator.status, "Session expired. Create a new session.")
        await coordinator.stop()
    }

    @MainActor
    func testTerminalRejectionClearsSessionAndOffersFreshPairing() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        let signaling = DelayedEndSignalingClient()
        let coordinator = SessionCoordinator(role: .sender, signaling: signaling, credentialNamespace: "rejection-test.")
        defer { coordinator.presentation.close() }
        let code = try PairingCode(server: URL(string: "https://pair.example.com")!, sessionId: UUID().uuidString,
                                   joinToken: Data(repeating: 2, count: 32).base64URL,
                                   expiresAt: Date().addingTimeInterval(7200))
        await coordinator.joinInternetSession(try code.url.absoluteString)
        XCTAssertTrue(coordinator.hasSession)
        signaling.onPairingRequired?()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(coordinator.hasSession)
        XCTAssertFalse(coordinator.canRestore)
        XCTAssertFalse(coordinator.approved)
        XCTAssertEqual(coordinator.status, "Pairing required")
        XCTAssertTrue(coordinator.error?.contains("scan its new code") == true)
    }

    func testStopClosesMediaBeforeServerNotificationCompletes() async throws {
        try await assertMediaClosesBeforeServerNotification(replaceSession: false)
    }

    func testReplacementClosesMediaBeforeServerNotificationCompletes() async throws {
        try await assertMediaClosesBeforeServerNotification(replaceSession: true)
    }

    @MainActor
    private func assertMediaClosesBeforeServerNotification(replaceSession: Bool) async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        let signaling = DelayedEndSignalingClient()
        let namespace = "test-\(UUID())."
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: namespace)
        defer {
            coordinator.presentation.close()
            KeychainStore.delete(account: namespace + "owner-token")
            KeychainStore.delete(account: namespace + "session-receiver")
        }
        let previousServer = UserDefaults.standard.object(forKey: "signaling-server")
        defer { UserDefaults.standard.set(previousServer, forKey: "signaling-server") }
        coordinator.serverAddress = "https://pair.example.com"
        coordinator.ownerToken = "test-owner-credential"
        await coordinator.createInternetSession()
        XCTAssertNil(coordinator.error)
        let oldStatus = try XCTUnwrap(coordinator.media.onCaptureStatus)
        let oldTrack = try XCTUnwrap(coordinator.media.onVideoTrack)
        oldStatus(.sharing)
        XCTAssertTrue(coordinator.isSharing)
        XCTAssertNotEqual(coordinator.media.connectionState, .closed)

        let started = expectation(description: "Server notification suspended")
        signaling.endStarted = { started.fulfill() }
        let operation = Task { @MainActor in
            if replaceSession { await coordinator.startDirectSession() }
            else { await coordinator.stop() }
        }
        await fulfillment(of: [started], timeout: 5)

        // The notification is still suspended: local privacy must not depend on it.
        XCTAssertEqual(coordinator.media.connectionState, .closed)
        XCTAssertFalse(coordinator.isSharing)
        oldStatus(.sharing)
        XCTAssertFalse(coordinator.isSharing)
        XCTAssertTrue(coordinator.presentation.isMuted)
        XCTAssertEqual(coordinator.presentation.statusText, "Screen sharing stopped")

        signaling.finishEnd()
        await operation.value
        if !replaceSession { await coordinator.startDirectSession() }
        let currentStatus = try XCTUnwrap(coordinator.media.onCaptureStatus)
        currentStatus(.sharing)
        XCTAssertTrue(coordinator.isSharing, "The new session must receive fresh callbacks.")
        oldStatus(.stopped)
        XCTAssertTrue(coordinator.isSharing, "Old callbacks must remain invalid after reconfiguration.")

        // With a renderable picture, an old track callback must not discard the new picture.
        if RTCMTLNSVideoView.isMetalAvailable() {
            currentStatus(.sharing)
            coordinator.presentation.setConnectionState(.connected)
            var pixelBuffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                               nil, &pixelBuffer), kCVReturnSuccess)
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer)),
                                      rotation: ._0, timeStampNs: 1_000_000)
            coordinator.presentation.setExternalVideoFrame(frame)
            XCTAssertFalse(coordinator.presentation.isMuted)
            let factory = RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                                   decoderFactory: RTCDefaultVideoDecoderFactory())
            oldTrack(factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "stale"))
            XCTAssertFalse(coordinator.presentation.isMuted)
            XCTAssertEqual(coordinator.presentation.statusText, "Presenting iPhone screen")
        }
        await coordinator.stop()
    }

    func testStopDiscardsDelayedSessionCreation() async throws {
        let fixture = DelayedSessionCreation(started: expectation(description: "Session creation started"))
        SessionCreationURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SessionCreationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let coordinator = await MainActor.run {
            let coordinator = SessionCoordinator(
                role: .receiver, signaling: SignalingClient(session: session),
                credentialNamespace: "test-\(UUID())."
            )
            coordinator.serverAddress = "https://pair.example.com"
            coordinator.ownerToken = "test-owner-credential"
            return coordinator
        }
        let creation = Task { @MainActor in await coordinator.createInternetSession() }
        defer {
            creation.cancel()
            session.invalidateAndCancel()
            SessionCreationURLProtocol.install(nil)
        }

        await fulfillment(of: [fixture.started], timeout: 5)
        await coordinator.stop()
        try fixture.completeCreation()
        await creation.value

        await MainActor.run {
            XCTAssertFalse(coordinator.approved)
            XCTAssertFalse(coordinator.hasSession)
            XCTAssertFalse(coordinator.isSharing)
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertEqual(coordinator.pairingURL, "")
            XCTAssertEqual(coordinator.status, "Sharing stopped")
            XCTAssertNil(coordinator.error)
        }
        XCTAssertEqual(fixture.requests, ["POST /v1/sessions"])
    }
}

private final class DelayedSessionCreation: @unchecked Sendable {
    let started: XCTestExpectation
    private let lock = NSLock()
    private var pending: SessionCreationURLProtocol?
    private var recordedRequests: [String] = []

    init(started: XCTestExpectation) { self.started = started }

    var requests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func receive(_ request: SessionCreationURLProtocol) {
        let description = "\(request.request.httpMethod ?? "GET") \(request.request.url?.path ?? "")"
        lock.lock()
        recordedRequests.append(description)
        let isCreation = description == "POST /v1/sessions" && pending == nil
        if isCreation { pending = request }
        lock.unlock()
        if isCreation {
            started.fulfill()
        } else {
            request.fail()
        }
    }

    func completeCreation() throws {
        lock.lock()
        let request = pending
        pending = nil
        lock.unlock()
        let active = try XCTUnwrap(request, "The fixture must receive session creation before completing it.")
        let data = try JSONSerialization.data(withJSONObject: [
            "sessionId": UUID().uuidString,
            "receiverToken": Data(repeating: 1, count: 32).base64URL,
            "joinToken": Data(repeating: 2, count: 32).base64URL,
            "expiresAt": ISO8601DateFormatter().string(from: Date().addingTimeInterval(7200))
        ])
        try active.finish(data: data)
    }
}

private final class SessionCreationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let fixtureLock = NSLock()
    private static var fixture: DelayedSessionCreation?
    private let callbackLock = NSRecursiveLock()
    private var stopped = false

    static func install(_ fixture: DelayedSessionCreation?) {
        fixtureLock.lock()
        Self.fixture = fixture
        fixtureLock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.fixtureLock.lock()
        let fixture = Self.fixture
        Self.fixtureLock.unlock()
        if let fixture { fixture.receive(self) } else { fail() }
    }

    override func stopLoading() {
        callbackLock.lock()
        stopped = true
        callbackLock.unlock()
    }

    func finish(data: Data) throws {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil,
                                                   headerFields: ["Content-Type": "application/json"]))
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        stopped = true
    }

    func fail() {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !stopped else { return }
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        stopped = true
    }
}

@MainActor
private final class DelayedEndSignalingClient: SignalingClient {
    var failICE = false
    var lifetime: TimeInterval = 7200
    var iceStarted: (() -> Void)?
    private var pendingICE: CheckedContinuation<Void, Never>?

    func finishICE() {
        pendingICE?.resume()
        pendingICE = nil
        iceStarted = nil
    }

    var endStarted: (() -> Void)?
    private var pendingEnd: CheckedContinuation<Void, Never>?

    override func createSession(server: URL, ownerToken: String) async throws -> CreatedSession {
        CreatedSession(sessionId: UUID().uuidString,
                       receiverToken: Data(repeating: 1, count: 32).base64URL,
                       joinToken: Data(repeating: 2, count: 32).base64URL,
                       expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(lifetime)))
    }

    override func iceConfiguration(server: URL, sessionId: String, token: String) async throws -> ICEConfiguration {
        if failICE { throw URLError(.cannotConnectToHost) }
        if let iceStarted {
            await withCheckedContinuation { continuation in
                pendingICE = continuation
                iceStarted()
            }
        }
        return ICEConfiguration(iceServers: [], connectivity: "Direct")
    }

    override func connect(server: URL, sessionId: String, token: String) throws {}

    override func endSession() async {
        guard let endStarted else { return }
        await withCheckedContinuation { continuation in
            pendingEnd = continuation
            endStarted()
        }
    }

    func finishEnd() {
        endStarted = nil
        pendingEnd?.resume()
        pendingEnd = nil
    }
}
