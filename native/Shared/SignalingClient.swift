// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import Foundation

struct CreatedSession: Decodable {
    let sessionId: String
    let receiverToken: String
    let joinToken: String
    let expiresAt: String

    var expiration: Date {
        get throws {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: expiresAt) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            guard let value = formatter.date(from: expiresAt) else { throw PairingError.invalidCode }
            return value
        }
    }
}

struct ICEConfiguration: Decodable {
    let iceServers: [ICEServer]
    let connectivity: String
}

struct ServerMessage: Decodable {
    let type: String
    let role: PeerRole?
    let resumeToken: String?
    let payload: String?
    let mac: String?
    let reason: String?
    let message: String?
}

private struct ClientMessage: Encodable {
    let type: String
    var accepted: Bool?
    var payload: String?
    var mac: String?
}

private struct ServerErrorBody: Decodable { let error: String? }

// Class identity lets the client ignore results from a replaced connection.
protocol WebSocketTasking: AnyObject {
    var maximumMessageSize: Int { get set }
    var response: URLResponse? { get }
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: WebSocketTasking {}

@MainActor
class SignalingClient {
    var onMessage: ((ServerMessage) -> Void)?
    var onAvailability: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onPairingRequired: (() -> Void)?

    private var socket: (any WebSocketTasking)?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var endpoint: URL?
    private var token: String?
    private var intentionallyClosed = true
    private var reconnectAttempts = 0
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
    }

    func createSession(server: URL, ownerToken: String) async throws -> CreatedSession {
        var request = URLRequest(url: server.appendingPathComponent("v1/sessions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        return try await fetch(request)
    }

    func iceConfiguration(server: URL, sessionId: String, token: String) async throws -> ICEConfiguration {
        var request = URLRequest(url: server.appendingPathComponent("v1/sessions/\(sessionId)/ice"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await fetch(request)
    }

    func connect(server: URL, sessionId: String, token: String) throws {
        close()
        guard var components = URLComponents(url: server.appendingPathComponent("v1/sessions/\(sessionId)/ws"),
                                             resolvingAgainstBaseURL: false) else { throw PairingError.invalidServer }
        components.scheme = "wss"
        guard let endpoint = components.url else { throw PairingError.invalidServer }
        self.endpoint = endpoint
        self.token = token
        intentionallyClosed = false
        openSocket()
    }

    func updateToken(_ token: String) { self.token = token }

    func approve(_ accepted: Bool) {
        send(ClientMessage(type: "approve", accepted: accepted))
    }

    func sendSignal(payload: String, mac: String) {
        send(ClientMessage(type: "signal", payload: payload, mac: mac))
    }

    func endSession() async {
        guard let socket else { return }
        try? await socket.send(.string("{\"type\":\"stop\"}"))
    }

    func close() {
        intentionallyClosed = true
        reconnectTask?.cancel()
        receiveTask?.cancel()
        sendTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        onAvailability?(false)
        reconnectAttempts = 0
    }

    func makeSocket(with request: URLRequest) -> any WebSocketTasking {
        session.webSocketTask(with: request)
    }

    private func openSocket() {
        guard !intentionallyClosed, let endpoint, let token else { return }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let activeSocket = makeSocket(with: request)
        socket = activeSocket
        activeSocket.maximumMessageSize = 65536
        activeSocket.resume()
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let response = try await activeSocket.receive()
                    guard let self, self.socket === activeSocket else { return }
                    let data: Data
                    switch response {
                    case .string(let text): data = Data(text.utf8)
                    case .data(let bytes): data = bytes
                    @unknown default: throw PairingError.invalidCode
                    }
                    guard data.count <= 65536 else { throw PairingError.invalidCode }
                    let message = try JSONDecoder().decode(ServerMessage.self, from: data)
                    self.reconnectAttempts = 0
                    self.onAvailability?(true)
                    self.onMessage?(message)
                    if message.type == "error", message.message == "Connection replaced by an authenticated reconnect" {
                        self.close()
                        return
                    }
                    if message.type == "ended" || message.type == "rejected" {
                        self.close()
                        return
                    }
                }
            } catch {
                guard let self, !self.intentionallyClosed, self.socket === activeSocket else { return }
                // Failed upgrades retain their HTTP response on the task. These
                // capabilities cannot recover by retrying the same pairing code.
                if let status = (activeSocket.response as? HTTPURLResponse)?.statusCode,
                   [401, 403, 404, 410].contains(status) {
                    self.close()
                    self.token = nil
                    self.endpoint = nil
                    self.onPairingRequired?()
                    return
                }
                self.onAvailability?(false)
                self.onError?("Signaling disconnected. The current picture can continue while reconnecting.")
                self.reconnectAttempts += 1
                let delay = min(30, 1 << min(self.reconnectAttempts, 4))
                self.reconnectTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.openSocket()
                }
            }
        }
    }

    private func send(_ message: ClientMessage) {
        guard let socket else { return }
        let previous = sendTask
        sendTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                let data = try JSONEncoder().encode(message)
                guard let text = String(data: data, encoding: .utf8) else { throw PairingError.invalidCode }
                try await socket.send(.string(text))
            } catch {
                guard let self, self.socket === socket, !self.intentionallyClosed else { return }
                self.onError?(error.localizedDescription)
            }
        }
    }

    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let task = session.dataTask(with: request)
        let collector = BoundedHTTPResponse()
        task.delegate = collector
        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                collector.install(continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        guard (200..<300).contains(response.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerErrorBody.self, from: data).error) ?? "Server returned HTTP \(response.statusCode)."
            throw NSError(domain: "scrnshr.signaling", code: response.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// A task delegate checks chunks on URLSession's serial delegate queue, without
// hopping to the main actor for every byte. Only the accepted body is retained.
final class BoundedHTTPResponse: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let limit = 64 * 1024
    // Cancellation can complete a task before the continuation is installed.
    private let completionLock = NSLock()
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var result: Result<(Data, HTTPURLResponse), Error>?

    func install(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        completionLock.lock()
        let result = self.result
        if result == nil { self.continuation = continuation }
        completionLock.unlock()
        if let result { continuation.resume(with: result) }
    }

    // Body and response state are accessed only on the serial delegate queue.
    private(set) var data = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else {
            failure = PairingError.invalidServer
            completionHandler(.cancel)
            return
        }
        self.response = response
        guard response.expectedContentLength <= Int64(Self.limit) else {
            failure = URLError(.dataLengthExceedsMaximum)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        guard data.count <= Self.limit - self.data.count else {
            failure = URLError(.dataLengthExceedsMaximum)
            dataTask.cancel()
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Preserve the size error when Foundation reports the cancellation it caused.
        let result: Result<(Data, HTTPURLResponse), Error>
        if let error = failure ?? error {
            result = .failure(error)
        } else if let response {
            result = .success((data, response))
        } else {
            result = .failure(PairingError.invalidServer)
        }
        completionLock.lock()
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        completionLock.unlock()
        continuation?.resume(with: result)
    }
}
