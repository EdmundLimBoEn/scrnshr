// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AppKit
import CoreVideo
import Foundation
import WebRTC
import XCTest
@testable import ScrnshrMac

final class SessionOperationTests: XCTestCase {
    @MainActor
    func testOwnerCredentialsFollowNormalizedOriginAndPort() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        let previous = UserDefaults.standard.object(forKey: "signaling-server")
        defer {
            KeychainStore.testMemory = nil
            UserDefaults.standard.set(previous, forKey: "signaling-server")
        }
        UserDefaults.standard.set("https://PAIR.example.com:443/", forKey: "signaling-server")
        try KeychainStore.save(Data("legacy-fixture".utf8), account: "origins.owner-token")
        let signaling = DelayedEndSignalingClient()
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "origins.")
        defer { coordinator.presentation.close() }
        XCTAssertEqual(coordinator.ownerToken, "legacy-fixture")
        XCTAssertNil(try KeychainStore.load(account: "origins.owner-token"))
        coordinator.serverAddress = "HTTPS://pair.example.com"
        XCTAssertEqual(coordinator.ownerToken, "legacy-fixture")
        coordinator.serverAddress = "https://pair.example.com:8443"
        XCTAssertEqual(coordinator.ownerToken, "")
        coordinator.ownerToken = "port-fixture"
        await coordinator.createInternetSession()
        XCTAssertNil(coordinator.error)
        coordinator.serverAddress = "https://other.example.com"
        XCTAssertEqual(coordinator.ownerToken, "")
        let count = signaling.creations.count
        await coordinator.createInternetSession()
        XCTAssertEqual(signaling.creations.count, count, "A different origin must not receive the saved credential")
        coordinator.serverAddress = "https://PAIR.example.com/"
        XCTAssertEqual(coordinator.ownerToken, "legacy-fixture")
        coordinator.serverAddress = "https://pair.example.com:8443/"
        XCTAssertEqual(coordinator.ownerToken, "port-fixture")
        coordinator.serverAddress = "http://pair.example.com:8443"
        XCTAssertEqual(coordinator.ownerToken, "")
        await coordinator.stop()
    }

    @MainActor
    func testLegacyOwnerCredentialRequiresPreviouslySavedValidServer() throws {
        _ = NSApplication.shared
        let previous = UserDefaults.standard.object(forKey: "signaling-server")
        defer {
            KeychainStore.testMemory = nil
            UserDefaults.standard.set(previous, forKey: "signaling-server")
        }
        for savedServer in ["", "http://pair.example.com", "https://pair.example.com/path"] {
            KeychainStore.testMemory = ["migration.owner-token": Data("legacy-fixture".utf8)]
            UserDefaults.standard.set(savedServer, forKey: "signaling-server")
            let coordinator = SessionCoordinator(role: .receiver, credentialNamespace: "migration.")
            defer { coordinator.presentation.close() }
            XCTAssertEqual(coordinator.ownerToken, "")
            coordinator.serverAddress = "https://other.example.com"
            XCTAssertEqual(coordinator.ownerToken, "")
            XCTAssertNil(try KeychainStore.load(account: "migration.owner-token"))
        }
        KeychainStore.testMemory = [
            "migration.owner-token": Data("legacy-fixture".utf8),
            "migration.owner-token:https://pair.example.com": Data("new-fixture".utf8)
        ]
        UserDefaults.standard.set("https://pair.example.com/", forKey: "signaling-server")
        let coordinator = SessionCoordinator(role: .receiver, credentialNamespace: "migration.")
        defer { coordinator.presentation.close() }
        XCTAssertEqual(coordinator.ownerToken, "new-fixture", "Migration must not overwrite an origin's credential")
    }

    @MainActor
    func testCreationSnapshotsOwnerCredentialBeforeTeardownAndResponse() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        let previous = UserDefaults.standard.object(forKey: "signaling-server")
        defer {
            KeychainStore.testMemory = nil
            UserDefaults.standard.set(previous, forKey: "signaling-server")
        }
        let signaling = DelayedEndSignalingClient()
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "snapshot.")
        defer { coordinator.presentation.close() }
        coordinator.serverAddress = "https://pair.example.com"
        coordinator.ownerToken = "initial-fixture"
        await coordinator.createInternetSession()
        coordinator.ownerToken = "snapshot-fixture"
        let ending = expectation(description: "Teardown suspended")
        let creating = expectation(description: "Creation suspended")
        signaling.endStarted = { ending.fulfill() }
        signaling.createStarted = { creating.fulfill() }
        let creation = Task { await coordinator.createInternetSession() }
        await fulfillment(of: [ending], timeout: 5)
        coordinator.serverAddress = "https://other.example.com"
        coordinator.ownerToken = "other-fixture"
        signaling.finishEnd()
        await fulfillment(of: [creating], timeout: 5)
        XCTAssertEqual(signaling.creations.last?.0, URL(string: "https://pair.example.com"))
        XCTAssertEqual(signaling.creations.last?.1, "snapshot-fixture")
        coordinator.ownerToken = "edited-during-response-fixture"
        signaling.finishCreation()
        await creation.value
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(coordinator.ownerToken, "edited-during-response-fixture")
        coordinator.serverAddress = "https://pair.example.com/"
        XCTAssertEqual(coordinator.ownerToken, "snapshot-fixture")
        coordinator.serverAddress = "https://other.example.com"
        XCTAssertEqual(coordinator.ownerToken, "")
        await coordinator.stop()
    }

    @MainActor
    func testStopDiscardsUSBStartWaitingForSessionStop() async {
        let usb = USBScreenSource()
        let suspended = expectation(description: "Session stop suspended")
        var resume: CheckedContinuation<Void, Never>?
        var presentations = 0
        let start = usb.scheduleStart(deviceID: "nonexistent-test-device", stopSession: {
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.fulfill()
            }
        }, showPresentation: { presentations += 1 })
        await fulfillment(of: [suspended], timeout: 5)

        // Both Stop controls and every wireless source switch call usb.stop().
        usb.stop()
        var lateCaptureUpdates = 0
        usb.onStatus = { _ in lateCaptureUpdates += 1 }
        resume?.resume()
        await start.value

        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(lateCaptureUpdates, 0, "Stale startup must not even enter USB discovery/capture.")
        XCTAssertFalse(usb.isRunning)
    }

    @MainActor
    func testNewUSBStartSupersedesPendingStart() async {
        let usb = USBScreenSource()
        let suspended = expectation(description: "Old session stop suspended")
        var resume: CheckedContinuation<Void, Never>?
        var oldPresentations = 0
        var newPresentations = 0
        let oldStart = usb.scheduleStart(deviceID: "old-nonexistent-test-device", stopSession: {
            await withCheckedContinuation { continuation in
                resume = continuation
                suspended.fulfill()
            }
        }, showPresentation: { oldPresentations += 1 })
        await fulfillment(of: [suspended], timeout: 5)

        let newStart = usb.scheduleStart(deviceID: "new-nonexistent-test-device", stopSession: {},
                                         showPresentation: { newPresentations += 1 })
        await newStart.value
        XCTAssertEqual(newPresentations, 1, "A current startup must still proceed.")
        var lateCaptureUpdates = 0
        usb.onStatus = { _ in lateCaptureUpdates += 1 }
        resume?.resume()
        await oldStart.value

        XCTAssertEqual(oldPresentations, 0)
        XCTAssertEqual(lateCaptureUpdates, 0, "The old start must not replace the new capture operation.")
        usb.stop()
    }

    @MainActor
    func testStopBeforeUSBStartupTaskRuns() async {
        let usb = USBScreenSource()
        var sessionStops = 0
        var presentations = 0
        let start = usb.scheduleStart(deviceID: "nonexistent-test-device",
                                      stopSession: { sessionStops += 1 },
                                      showPresentation: { presentations += 1 })
        usb.stop()
        await start.value

        XCTAssertEqual(sessionStops, 0, "A superseded task must not stop a newer wireless session.")
        XCTAssertEqual(presentations, 0)
    }

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

    @MainActor
    func testRestoreTerminalHTTPFailuresRequireFreshPairing() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        for role in [PeerRole.receiver, .sender] {
            for status in [401, 410] {
                let namespace = "restore-\(role.rawValue)-\(status)."
                let account = namespace + "session-\(role.rawValue)"
                try saveRestoreFixture(account: account)
                let signaling = DelayedEndSignalingClient()
                signaling.iceError = NSError(domain: "scrnshr.signaling", code: status)
                let coordinator = SessionCoordinator(role: role, signaling: signaling, credentialNamespace: namespace)
                defer { coordinator.presentation.close() }
                XCTAssertTrue(coordinator.canRestore)

                await coordinator.restoreSession()

                XCTAssertFalse(coordinator.hasSession)
                XCTAssertFalse(coordinator.approved)
                XCTAssertFalse(coordinator.canRestore)
                XCTAssertFalse(coordinator.isBusy)
                XCTAssertNil(try KeychainStore.load(account: account))
                XCTAssertEqual(coordinator.status, "Pairing required")
                XCTAssertTrue(coordinator.error?.contains("scan its new code") == true)
                XCTAssertEqual(signaling.connections, 0)
            }
        }
    }

    @MainActor
    func testLocallyExpiredRestoreClearsCredentialsWithoutResettingActiveSession() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        for role in [PeerRole.receiver, .sender] {
            for active in [false, true] {
                let namespace = "local-expiry-\(role.rawValue)-\(active)."
                let account = namespace + "session-\(role.rawValue)"
                try saveRestoreFixture(account: account, lifetime: 2)
                let signaling = DelayedEndSignalingClient()
                let coordinator = SessionCoordinator(role: role, signaling: signaling, credentialNamespace: namespace)
                defer { coordinator.presentation.close() }
                if active {
                    await coordinator.startDirectSession()
                    coordinator.media.onCaptureStatus?(.sharing)
                }
                XCTAssertTrue(coordinator.canRestore)
                let status = coordinator.status
                let sharing = coordinator.isSharing
                let mediaState = coordinator.media.connectionState
                let presentationMuted = coordinator.presentation.isMuted
                try await Task.sleep(nanoseconds: 3_000_000_000)

                await coordinator.restoreSession()

                XCTAssertNil(try KeychainStore.load(account: account))
                XCTAssertFalse(coordinator.canRestore)
                XCTAssertFalse(coordinator.isBusy)
                XCTAssertEqual(coordinator.hasSession, active)
                XCTAssertEqual(coordinator.approved, active)
                XCTAssertEqual(coordinator.mode, .direct)
                XCTAssertEqual(coordinator.isSharing, sharing)
                XCTAssertEqual(coordinator.media.connectionState, mediaState)
                XCTAssertEqual(coordinator.presentation.isMuted, presentationMuted)
                XCTAssertEqual(coordinator.status, active ? status : "Pairing required")
                XCTAssertTrue(coordinator.error?.contains("scan its new code") == true)
                XCTAssertEqual(signaling.connections, 0)
                await coordinator.stop()
            }
        }
    }

    @MainActor
    func testRestoreTransientFailurePreservesCredentialsForRetry() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        let account = "restore-retry.session-receiver"
        try saveRestoreFixture(account: account)
        let saved = try KeychainStore.load(account: account)
        let signaling = DelayedEndSignalingClient()
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "restore-retry.")
        defer { coordinator.presentation.close() }
        for failure in [URLError(.cannotConnectToHost) as Error,
                        NSError(domain: "scrnshr.signaling", code: 503)] {
            signaling.iceError = failure
            await coordinator.restoreSession()
            XCTAssertFalse(coordinator.approved)
            XCTAssertFalse(coordinator.isBusy)
            XCTAssertTrue(coordinator.canRestore)
            XCTAssertNotNil(coordinator.error)
            XCTAssertEqual(try KeychainStore.load(account: account), saved)
            XCTAssertEqual(signaling.connections, 0)
        }
        signaling.iceError = nil
        await coordinator.restoreSession()
        XCTAssertTrue(coordinator.approved)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(signaling.connections, 1)
        await coordinator.stop()
    }

    @MainActor
    func testRestoreExpiresWhileICEIsPending() async throws {
        _ = NSApplication.shared
        KeychainStore.testMemory = [:]
        defer { KeychainStore.testMemory = nil }
        let account = "restore-expiry.session-receiver"
        try saveRestoreFixture(account: account, lifetime: 2)
        let signaling = DelayedEndSignalingClient()
        let started = expectation(description: "Restore ICE suspended")
        signaling.iceStarted = { started.fulfill() }
        let coordinator = SessionCoordinator(role: .receiver, signaling: signaling, credentialNamespace: "restore-expiry.")
        defer { coordinator.presentation.close() }
        let restore = Task { await coordinator.restoreSession() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertFalse(coordinator.approved)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(coordinator.hasSession, "Restore must expire before ICE returns")
        XCTAssertFalse(coordinator.canRestore)
        XCTAssertNil(try KeychainStore.load(account: account))
        signaling.finishICE()
        await restore.value
        XCTAssertFalse(coordinator.hasSession, "Late ICE must not revive the expired session")
        XCTAssertFalse(coordinator.approved)
        XCTAssertEqual(signaling.connections, 0)
        XCTAssertEqual(coordinator.status, "Session expired. Create a new session.")
        await coordinator.stop()
    }

    @MainActor
    private func saveRestoreFixture(account: String, lifetime: TimeInterval = 7200) throws {
        struct Saved: Encodable {
            let code: PairingCode
            let token: String
            let expiresAt: Date
        }
        let expiration = Date().addingTimeInterval(lifetime)
        let code = try PairingCode(server: URL(string: "https://pair.example.com")!, sessionId: UUID().uuidString,
                                   joinToken: Data(repeating: 2, count: 32).base64URL, expiresAt: expiration)
        try KeychainStore.save(JSONEncoder().encode(Saved(code: code,
                                                         token: Data(repeating: 1, count: 32).base64URL,
                                                         expiresAt: expiration)), account: account)
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
    var iceError: Error?
    var connections = 0
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

    var creations: [(URL, String)] = []
    var createStarted: (() -> Void)?
    private var pendingCreation: CheckedContinuation<Void, Never>?

    func finishCreation() {
        createStarted = nil
        pendingCreation?.resume()
        pendingCreation = nil
    }

    override func createSession(server: URL, ownerToken: String) async throws -> CreatedSession {
        creations.append((server, ownerToken))
        if let createStarted {
            await withCheckedContinuation { continuation in
                pendingCreation = continuation
                createStarted()
            }
        }
        return CreatedSession(sessionId: UUID().uuidString,
                       receiverToken: Data(repeating: 1, count: 32).base64URL,
                       joinToken: Data(repeating: 2, count: 32).base64URL,
                       expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(lifetime)))
    }

    override func iceConfiguration(server: URL, sessionId: String, token: String) async throws -> ICEConfiguration {
        if let iceError { throw iceError }
        if failICE { throw URLError(.cannotConnectToHost) }
        if let iceStarted {
            await withCheckedContinuation { continuation in
                pendingICE = continuation
                iceStarted()
            }
        }
        return ICEConfiguration(iceServers: [], connectivity: "Direct")
    }

    override func connect(server: URL, sessionId: String, token: String) throws { connections += 1 }

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
