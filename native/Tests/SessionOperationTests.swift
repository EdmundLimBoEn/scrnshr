// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import Foundation
import XCTest
@testable import ScrnshrMac

final class SessionOperationTests: XCTestCase {
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
