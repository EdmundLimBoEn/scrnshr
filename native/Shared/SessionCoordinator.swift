// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import Combine
import Foundation
import WebRTC

struct ManualSignalBundle: Codable {
    let version: Int
    let id: UUID
    let role: PeerRole
    let signals: [RTCSignal]

    static func parse(_ text: String, expectedRole: PeerRole) throws -> ManualSignalBundle {
        guard text.utf8.count <= 131072 else { throw PairingError.invalidCode }
        let bundle = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard bundle.version == 1, bundle.role == expectedRole, !bundle.signals.isEmpty,
              bundle.signals.count <= 512 else { throw PairingError.invalidCode }
        return bundle
    }
}

private struct SavedSession: Codable {
    let code: PairingCode
    let token: String
    let expiresAt: Date
    let authentication: SignalAuthenticationState?
}

@MainActor
final class SessionCoordinator: ObservableObject {
    enum Mode: String, CaseIterable { case direct = "Direct LAN", internet = "Internet" }

    let role: PeerRole
    let media: WebRTCSession
    #if os(iOS)
    let audioDevice: AppAudioDevice
    let capture: ScreenCaptureController
    #else
    let presentation: PresentationController
    #endif

    @Published var mode: Mode = .direct
    @Published var status = "Ready to connect"
    @Published var error: String?
    @Published var pairingURL = ""
    @Published var approvalRequired = false
    @Published var approved = false
    @Published var isSharing = false
    @Published var signalingAvailable = false
    @Published var manualOutput = ""
    @Published var canRestore = false
    @Published var relayOnly = false
    @Published var connectivity = ""
    @Published var serverAddress: String
    @Published var ownerToken = ""
    @Published var isBusy = false

    private let signaling = SignalingClient()
    private var code: PairingCode?
    private var token: String?
    private var expiresAt: Date?
    private var authenticator: SignalAuthenticator?
    private var manualId = UUID()
    private var manualSignals: [RTCSignal] = []
    private var importedCounts: [UUID: Int] = [:]
    private var pendingSignals: [RTCSignal] = []
    private var expiryTask: Task<Void, Never>?
    private var suppressCaptureCallbacks = false
    private var internetMediaConfigured = false
    private var awaitingReceiverRestart = false

    var hasSession: Bool { code != nil || approved || isSharing || !manualSignals.isEmpty }

    init(role: PeerRole) {
        self.role = role
        serverAddress = UserDefaults.standard.string(forKey: "signaling-server") ?? ""
        #if os(iOS)
        let device = AppAudioDevice()
        audioDevice = device
        capture = ScreenCaptureController(audioDevice: device)
        media = WebRTCSession(role: role, audioDevice: device)
        #else
        media = WebRTCSession(role: role)
        presentation = PresentationController()
        #endif
        if let data = try? KeychainStore.load(account: "owner-token"),
           let value = String(data: data, encoding: .utf8) { ownerToken = value }
        if let data = try? KeychainStore.load(account: "session-\(role.rawValue)"),
           let saved = try? JSONDecoder().decode(SavedSession.self, from: data) {
            canRestore = saved.expiresAt > .now
        }
        installCallbacks()
        media.configure(iceServers: [], relayOnly: false)
    }

    func startDirectSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await reset(endServerSession: true)
        mode = .direct
        approved = true
        connectivity = "Direct LAN"
        media.configure(iceServers: [], relayOnly: false)
        status = role == .sender ? "Share the screen, then copy the offer to the Mac." : "Import the phone's offer to connect."
        #if os(macOS)
        presentation.showWindow()
        #endif
    }

    func createInternetSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let server = URL(string: serverAddress) else { throw PairingError.invalidServer }
            _ = try PairingCode.validateServer(server)
            guard !ownerToken.isEmpty else {
                throw NSError(domain: "scrnshr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter the server's owner credential first."])
            }
            await reset(endServerSession: true)
            mode = .internet
            status = "Creating session"
            let created = try await signaling.createSession(server: server, ownerToken: ownerToken)
            let expiration = try created.expiration
            let pairing = try PairingCode(server: server, sessionId: created.sessionId,
                                          joinToken: created.joinToken, expiresAt: expiration)
            code = pairing
            token = created.receiverToken
            expiresAt = expiration
            authenticator = try SignalAuthenticator(sessionId: pairing.sessionId, pairingKey: pairing.pairingKey, role: role)
            pairingURL = try pairing.url.absoluteString
            UserDefaults.standard.set(server.absoluteString, forKey: "signaling-server")
            try KeychainStore.save(Data(ownerToken.utf8), account: "owner-token")
            try saveSession()
            let ice = try await signaling.iceConfiguration(server: server, sessionId: pairing.sessionId, token: created.receiverToken)
            connectivity = ice.connectivity
            media.configure(iceServers: ice.iceServers, relayOnly: relayOnly)
            internetMediaConfigured = true
            try signaling.connect(server: server, sessionId: pairing.sessionId, token: created.receiverToken)
            scheduleExpiry(expiration)
            status = "Scan the code on the iPhone."
            #if os(macOS)
            presentation.showWindow()
            #endif
        } catch { fail(error) }
    }

    func joinInternetSession(_ text: String) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let pairing = try PairingCode.parse(text)
            await reset(endServerSession: true)
            mode = .internet
            code = pairing
            token = pairing.joinToken
            expiresAt = pairing.expiresAt
            authenticator = try SignalAuthenticator(sessionId: pairing.sessionId, pairingKey: pairing.pairingKey, role: role)
            serverAddress = pairing.server.absoluteString
            try signaling.connect(server: pairing.server, sessionId: pairing.sessionId, token: pairing.joinToken)
            status = "Waiting for approval on the Mac."
            scheduleExpiry(pairing.expiresAt)
        } catch { fail(error) }
    }

    func restoreSession() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            guard let data = try KeychainStore.load(account: "session-\(role.rawValue)") else { throw PairingError.expired }
            let saved = try JSONDecoder().decode(SavedSession.self, from: data)
            guard saved.expiresAt > .now else { throw PairingError.expired }
            _ = try PairingCode.validateServer(saved.code.server)
            await reset()
            mode = .internet
            code = saved.code
            token = saved.token
            expiresAt = saved.expiresAt
            authenticator = try SignalAuthenticator(sessionId: saved.code.sessionId, pairingKey: saved.code.pairingKey,
                                                    role: role, checkpoint: saved.authentication)
            awaitingReceiverRestart = role == .receiver
            approved = true
            try await configureInternetMedia()
            try signaling.connect(server: saved.code.server, sessionId: saved.code.sessionId, token: saved.token)
            scheduleExpiry(saved.expiresAt)
            status = role == .sender ? "Connected. Approve screen sharing again to resume." : "Waiting for the phone to reconnect."
            #if os(macOS)
            presentation.showWindow()
            #endif
        } catch { fail(error) }
    }

    func approvePhone(_ accepted: Bool) {
        approvalRequired = false
        signaling.approve(accepted)
    }

    func importManualSignals(_ text: String) {
        do {
            guard mode == .direct else { throw PairingError.invalidCode }
            let bundle = try ManualSignalBundle.parse(text, expectedRole: role == .sender ? .receiver : .sender)
            let count = importedCounts[bundle.id] ?? 0
            guard bundle.signals.count >= count else { throw PairingError.replayedSignal }
            approved = true
            for signal in bundle.signals.dropFirst(count) { media.accept(signal) }
            importedCounts[bundle.id] = bundle.signals.count
            status = "Connecting over the LAN"
            #if os(macOS)
            presentation.showWindow()
            #endif
        } catch { fail(error) }
    }

    #if os(iOS)
    func startSharing() {
        guard mode == .direct || approved else { return }
        error = nil
        capture.start()
    }
    #endif

    func stop() async {
        media.sendCaptureStatus(.stopped)
        #if os(macOS)
        presentation.setCaptureStatus(.stopped)
        #endif
        #if os(iOS)
        await capture.stop()
        #endif
        await signaling.endSession()
        await reset()
        KeychainStore.delete(account: "session-\(role.rawValue)")
        canRestore = false
        status = "Sharing stopped"
        #if os(macOS)
        presentation.setCaptureStatus(.stopped)
        #endif
    }

    private func reset(endServerSession: Bool = false) async {
        expiryTask?.cancel()
        suppressCaptureCallbacks = true
        #if os(iOS)
        await capture.stop()
        audioDevice.reset()
        #endif
        suppressCaptureCallbacks = false
        if endServerSession, code != nil {
            media.sendCaptureStatus(.stopped)
            #if os(macOS)
            presentation.setCaptureStatus(.stopped)
            #endif
            await signaling.endSession()
        }
        signaling.close()
        media.close()
        code = nil
        token = nil
        expiresAt = nil
        authenticator = nil
        internetMediaConfigured = false
        awaitingReceiverRestart = false
        approved = false
        approvalRequired = false
        isSharing = false
        pairingURL = ""
        manualId = UUID()
        manualSignals = []
        pendingSignals = []
        importedCounts = [:]
        manualOutput = ""
        error = nil
    }

    private func installCallbacks() {
        media.onSignal = { [weak self] signal in self?.send(signal) }
        media.onError = { [weak self] message in self?.error = message }
        media.onConnectionState = { [weak self] state in
            guard let self else { return }
            switch state {
            case .idle: self.status = "Ready to connect"
            case .connecting: self.status = "Connecting"
            case .connected: self.status = "Connected"
            case .reconnecting: self.status = "Reconnecting"
            case .failed: self.status = "Connection failed. Start a new session."
            case .closed: self.status = "Sharing stopped"
            }
            #if os(macOS)
            self.presentation.setConnectionState(state)
            #endif
        }
        media.onCaptureStatus = { [weak self] status in
            self?.isSharing = status == .sharing
            #if os(macOS)
            self?.presentation.setCaptureStatus(status)
            #endif
        }
        #if os(iOS)
        capture.onVideo = { [weak media] sample in media?.sendVideo(sample) }
        capture.onError = { [weak self] message in self?.error = message }
        capture.onStatus = { [weak self] status in
            guard let self, !self.suppressCaptureCallbacks else { return }
            self.isSharing = status == .sharing
            self.media.sendCaptureStatus(status)
            if status == .sharing { self.media.startOffer() }
            if status == .stopped { self.status = "Sharing stopped. Approve sharing on the iPhone to restart." }
        }
        #else
        media.onVideoTrack = { [weak self] track in self?.presentation.setVideoTrack(track) }
        presentation.onMuteChanged = { [weak media] muted in media?.setRemoteAudioMuted(muted) }
        #endif
        signaling.onMessage = { [weak self] message in
            Task { @MainActor in await self?.receive(message) }
        }
        signaling.onAvailability = { [weak self] available in
            guard let self else { return }
            let regained = available && !self.signalingAvailable
            self.signalingAvailable = available
            if regained, self.role == .sender, self.isSharing, self.approved,
               self.media.connectionState != .connected { self.media.startOffer() }
        }
        signaling.onError = { [weak self] message in self?.error = message }
    }

    private func send(_ signal: RTCSignal) {
        do {
            if mode == .direct {
                manualSignals.append(signal)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let bundle = ManualSignalBundle(version: 1, id: manualId, role: role, signals: manualSignals)
                let data = try encoder.encode(bundle)
                manualOutput = String(data: data, encoding: .utf8) ?? ""
                return
            }
            guard var authenticator else { throw PairingError.authenticationFailed }
            if authenticator.generation == nil {
                if case .offer = signal {} else { pendingSignals.append(signal); return }
            }
            let signed = try authenticator.sign(signal)
            self.authenticator = authenticator
            try saveSession()
            signaling.sendSignal(payload: signed.payload, mac: signed.mac)
            let pending = pendingSignals
            pendingSignals.removeAll()
            for candidate in pending { send(candidate) }
        } catch { fail(error) }
    }

    private func receive(_ message: ServerMessage) async {
        do {
            switch message.type {
            case "waiting": status = "Waiting for the other device"
            case "peer":
                if message.role == .receiver, isSharing, approved, media.connectionState != .connected { media.startOffer() }
            case "approval-required": approvalRequired = true; status = "Approve the phone to continue"
            case "approved":
                if let resume = message.resumeToken {
                    guard Data(base64URL: resume)?.count == 32 else { throw PairingError.invalidCode }
                    token = resume
                    signaling.updateToken(resume)
                    if let code { expiresAt = code.expiresAt; scheduleExpiry(code.expiresAt) }
                }
                try await configureInternetMedia()
                approved = true
                try saveSession()
                if awaitingReceiverRestart, authenticator?.generation != nil {
                    awaitingReceiverRestart = false
                    send(.restart)
                }
                status = isSharing ? "Sharing screen" : (role == .sender ? "Approved. Tap Share screen." : "Waiting for screen sharing")
            case "signal":
                guard approved, var authenticator, let payload = message.payload, let mac = message.mac else {
                    throw PairingError.authenticationFailed
                }
                let signal = try authenticator.verify(payload: payload, mac: mac)
                self.authenticator = authenticator
                try saveSession()
                media.accept(signal)
            case "peer-left":
                status = "The other device disconnected. Waiting for it to return."
            case "rejected", "ended":
                media.sendCaptureStatus(.stopped)
                await reset()
                KeychainStore.delete(account: "session-\(role.rawValue)")
                canRestore = false
                status = message.type == "rejected" ? "The Mac declined this phone." : "Session ended"
            case "error": error = message.message ?? "The signaling server could not complete the request."
            default: throw PairingError.invalidCode
            }
        } catch { fail(error) }
    }

    private func configureInternetMedia() async throws {
        guard !internetMediaConfigured else { return }
        guard let code, let token else { throw PairingError.invalidCode }
        let ice = try await signaling.iceConfiguration(server: code.server, sessionId: code.sessionId, token: token)
        connectivity = ice.connectivity
        media.configure(iceServers: ice.iceServers, relayOnly: relayOnly)
        internetMediaConfigured = true
    }

    private func saveSession() throws {
        guard let code, let token, let expiresAt else { return }
        let saved = SavedSession(code: code, token: token, expiresAt: expiresAt,
                                 authentication: authenticator?.checkpoint)
        try KeychainStore.save(JSONEncoder().encode(saved), account: "session-\(role.rawValue)")
        canRestore = expiresAt > .now
    }

    private func scheduleExpiry(_ expiration: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            let interval = max(0, expiration.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.stop()
            self.status = "Session expired. Create a new session."
        }
    }

    private func fail(_ error: Error) { self.error = error.localizedDescription }
}
