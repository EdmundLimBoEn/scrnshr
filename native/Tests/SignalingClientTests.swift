import Foundation
import XCTest
@testable import ScrnshrMac

final class SignalingClientTests: XCTestCase {
    @MainActor
    func testTerminalUpgradeRejectionsStopRetriesAndRequestPairing() async throws {
        for status in [401, 403, 404, 410] {
            let client = RejectedSocketClient(status: status)
            let recovery = expectation(description: "Fresh pairing requested for HTTP \(status)")
            client.onPairingRequired = { recovery.fulfill() }
            client.onError = { _ in XCTFail("Terminal rejection must not report reconnecting") }
            try client.connect(server: URL(string: "https://pair.example.test")!, sessionId: "test", token: "lost-approval")
            await fulfillment(of: [recovery], timeout: 1)
            try await Task.sleep(nanoseconds: 2_200_000_000)
            XCTAssertEqual(client.opened, 1)
            XCTAssertTrue(client.lastSocket?.wasResumed == true)
            XCTAssertEqual(client.lastSocket?.maximumMessageSize, 65_536)
            XCTAssertTrue(client.lastSocket?.wasCancelled == true)
            client.close()
        }
    }

    @MainActor
    func testTransientUpgradeFailureStillRetries() async throws {
        let client = RejectedSocketClient(status: 503)
        let retry = expectation(description: "Transient failure retried")
        client.onOpen = { if client.opened == 2 { retry.fulfill() } }
        client.onPairingRequired = { XCTFail("Transient failure must preserve pairing") }
        try client.connect(server: URL(string: "https://pair.example.test")!, sessionId: "test", token: "resume")
        await fulfillment(of: [retry], timeout: 4)
        client.close()
    }

    func testOversizedStreamIsCancelledBeforeEOFForSuccessAndError() async throws {
        // No EOF is sent: only client cancellation can complete these requests.
        for status in [200, 503] {
            let fixture = HTTPResponseFixture(status: status, bodySize: 65_537, finishes: false)
            try await assertTooLarge(fixture)
        }
    }

    func testUnderstatedContentLengthDoesNotBypassStreamLimit() async throws {
        let fixture = HTTPResponseFixture(status: 200, bodySize: 65_537, finishes: false,
                                          contentLength: 1)
        try await assertTooLarge(fixture)
    }

    func testOversizedContentLengthIsCancelledBeforeReadingBody() async throws {
        for status in [200, 503] {
            let fixture = HTTPResponseFixture(status: status, bodySize: 0, finishes: false,
                                              contentLength: 65_537)
            try await assertTooLarge(fixture)
            XCTAssertEqual(fixture.bytesDelivered, 0)
        }
    }

    func testExactly64KiBStillDecodesSuccessAndServerError() async throws {
        for status in [200, 503] {
            let fixture = HTTPResponseFixture(status: status, bodySize: 65_536, finishes: true,
                                              contentLength: 65_536)
            let session = makeSession(fixture)
            defer { session.invalidateAndCancel() }
            let client = await SignalingClient(session: session)
            do {
                let ice = try await client.iceConfiguration(server: fixture.server,
                                                            sessionId: "test", token: "test")
                XCTAssertEqual(status, 200)
                XCTAssertTrue(ice.iceServers.isEmpty)
                XCTAssertEqual(ice.connectivity, "direct")
            } catch {
                XCTAssertEqual(status, 503)
                XCTAssertEqual((error as NSError).domain, "scrnshr.signaling")
                XCTAssertEqual((error as NSError).code, 503)
                XCTAssertEqual(error.localizedDescription, "Unavailable")
            }
        }
    }

    func testDelegateCancelsAtFirstChunkOverLimitAndIgnoresQueuedData() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://unused.example.test")!)
        let collector = BoundedHTTPResponse()
        let chunk = Data(repeating: 32, count: 16 * 1024)
        for _ in 0..<4 {
            collector.urlSession(session, dataTask: task, didReceive: chunk)
            XCTAssertEqual(task.state, .suspended)
        }
        XCTAssertEqual(collector.data.count, 65_536)
        collector.urlSession(session, dataTask: task, didReceive: Data([32]))
        XCTAssertTrue(task.state == .canceling || task.state == .completed)
        // Foundation may already have queued callbacks when cancel() is called.
        collector.urlSession(session, dataTask: task, didReceive: chunk)
        XCTAssertEqual(collector.data.count, 65_536)
        // Completion may race continuation installation when the caller cancels.
        // The size failure must also survive Foundation's cancellation error.
        collector.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                collector.install(continuation)
            }
            XCTFail("Expected response size rejection")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
    }

    private func assertTooLarge(_ fixture: HTTPResponseFixture) async throws {
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let client = await SignalingClient(session: session)
        do {
            _ = try await client.iceConfiguration(server: fixture.server,
                                                  sessionId: "test", token: "test")
            XCTFail("Expected response size rejection")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
        // Check before session cleanup, so invalidateAndCancel cannot satisfy this.
        await fulfillment(of: [fixture.cancelled], timeout: 5)
    }

    private func makeSession(_ fixture: HTTPResponseFixture) -> URLSession {
        BoundedResponseURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        // Bound failure time for the old implementation when only headers arrive.
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }
}

private final class HTTPResponseFixture: @unchecked Sendable {
    let server = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
    let status: Int
    let bodySize: Int
    let finishes: Bool
    let contentLength: Int?
    let cancelled = XCTestExpectation(description: "Response task cancelled")
    private let lock = NSLock()
    private var delivered = 0

    init(status: Int, bodySize: Int, finishes: Bool, contentLength: Int? = nil) {
        self.status = status
        self.bodySize = bodySize
        self.finishes = finishes
        self.contentLength = contentLength
    }

    var bytesDelivered: Int {
        lock.lock()
        defer { lock.unlock() }
        return delivered
    }

    func recordDelivery(_ count: Int) {
        lock.lock()
        delivered += count
        lock.unlock()
    }
}

private final class BoundedResponseURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: HTTPResponseFixture] = [:]
    private let callbackLock = NSRecursiveLock()
    private var active: HTTPResponseFixture?
    private var stopped = false

    static func install(_ fixture: HTTPResponseFixture) {
        lock.lock()
        Self.fixtures[fixture.server.host!] = fixture
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".example.test") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        Self.lock.lock()
        let fixture = Self.fixtures.removeValue(forKey: request.url!.host!)
        Self.lock.unlock()
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        active = fixture
        var headers = ["Content-Type": "application/json", "Connection": "close"]
        if let length = fixture.contentLength { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if fixture.bodySize > 0 {
            let json = fixture.status == 200
                ? "{\"iceServers\":[],\"connectivity\":\"direct\"}"
                : "{\"error\":\"Unavailable\"}"
            var body = Data(json.utf8)
            body.append(Data(repeating: 32, count: fixture.bodySize - body.count))
            fixture.recordDelivery(body.count)
            client?.urlProtocol(self, didLoad: body)
        }
        if fixture.finishes {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !stopped else { return }
        stopped = true
        active?.cancelled.fulfill()
    }
}

@MainActor
private final class RejectedSocketClient: SignalingClient {
    let status: Int
    var opened = 0
    var onOpen: (() -> Void)?
    var lastSocket: RejectedWebSocket?

    init(status: Int) { self.status = status; super.init() }

    override func makeSocket(with request: URLRequest) -> any WebSocketTasking {
        opened += 1
        let socket = RejectedWebSocket(status: status)
        lastSocket = socket
        onOpen?()
        return socket
    }
}

private final class RejectedWebSocket: WebSocketTasking {
    let status: Int
    var maximumMessageSize = 0
    var wasResumed = false
    var wasCancelled = false
    init(status: Int) { self.status = status }
    var response: URLResponse? {
        HTTPURLResponse(url: URL(string: "https://pair.example.test")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: nil)
    }
    func resume() { wasResumed = true }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        throw URLError(.badServerResponse)
    }
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        throw URLError(.badServerResponse)
    }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        wasCancelled = true
    }
}
