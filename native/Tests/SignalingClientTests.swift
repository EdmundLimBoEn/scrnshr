import Foundation
import XCTest
@testable import ScrnshrMac

final class SignalingClientTests: XCTestCase {
    func testOversizedStreamIsCancelledBeforeEOFForSuccessAndError() async throws {
        for status in [200, 503] {
            let fixture = HTTPResponseFixture(status: status, bodySize: 65_537, finishes: false)
            try await assertTooLarge(fixture)
            // The producer offers 8 MiB in paced chunks. Cancellation must stop
            // delivery near the cap, rather than buffering the entire response.
            // Allow a few in-flight chunks for URLSession scheduling.
            XCTAssertLessThanOrEqual(fixture.bytesDelivered, 4 * 65_536)
        }
    }

    func testUnderstatedContentLengthDoesNotBypassStreamLimit() async throws {
        let fixture = HTTPResponseFixture(status: 200, bodySize: 65_537, finishes: false,
                                          contentLength: 1)
        try await assertTooLarge(fixture)
        XCTAssertLessThanOrEqual(fixture.bytesDelivered, 4 * 65_536)
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
                let ice = try await client.iceConfiguration(server: URL(string: "https://pair.example.com")!,
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

    private func assertTooLarge(_ fixture: HTTPResponseFixture) async throws {
        let session = makeSession(fixture)
        defer { session.invalidateAndCancel() }
        let client = await SignalingClient(session: session)
        do {
            _ = try await client.iceConfiguration(server: URL(string: "https://pair.example.com")!,
                                                  sessionId: "test", token: "test")
            XCTFail("Expected response size rejection")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .dataLengthExceedsMaximum)
        }
        // Check before session cleanup, so invalidateAndCancel cannot satisfy this.
        await fulfillment(of: [fixture.cancelled], timeout: 2)
    }

    private func makeSession(_ fixture: HTTPResponseFixture) -> URLSession {
        BoundedResponseURLProtocol.install(fixture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        // Bound failure time for the old implementation when only headers arrive.
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        return URLSession(configuration: configuration)
    }
}

private final class HTTPResponseFixture: @unchecked Sendable {
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
    private static var fixture: HTTPResponseFixture?
    private let callbackLock = NSRecursiveLock()
    private var active: HTTPResponseFixture?
    private var stopped = false

    static func install(_ fixture: HTTPResponseFixture) {
        lock.lock()
        Self.fixture = fixture
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        Self.lock.lock()
        let fixture = Self.fixture!
        active = fixture
        Self.lock.unlock()
        var headers = ["Content-Type": "application/json"]
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
        } else if fixture.bodySize > 0 {
            scheduleMoreBody()
        }
    }

    private func scheduleMoreBody() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.callbackLock.lock()
            defer { self.callbackLock.unlock() }
            guard !self.stopped, let fixture = self.active else { return }
            let chunk = Data(repeating: 32, count: 65_536)
            fixture.recordDelivery(chunk.count)
            self.client?.urlProtocol(self, didLoad: chunk)
            if fixture.bytesDelivered >= 8 * 1024 * 1024 {
                self.client?.urlProtocolDidFinishLoading(self)
            } else {
                self.scheduleMoreBody()
            }
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
