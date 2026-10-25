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

    private let signaling: SignalingClient
    private let credentialNamespace: String
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
    private var approvalInitializationGeneration: UInt64?
    private var internetMediaConfigured = false
    private var awaitingReceiverRestart = false
    private var sessionGeneration: UInt64 = 0
    private var signalingGeneration: UInt64?

    var hasSession: Bool { code != nil || approved || isSharing || !manualSignals.isEmpty }

    private var ownerCredentialAccount: String { credentialNamespace + "owner-token" }
    private var sessionCredentialAccount: String { credentialNamespace + "session-\(role.rawValue)" }

    init(role: PeerRole, signaling: SignalingClient? = nil, credentialNamespace: String = "") {
        self.role = role
        self.signaling = signaling ?? SignalingClient()
        self.credentialNamespace = credentialNamespace
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
        if let data = try? KeychainStore.load(account: ownerCredentialAccount),
           let value = String(data: data, encoding: .utf8) { ownerToken = value }
        if let data = try? KeychainStore.load(account: sessionCredentialAccount),
           let saved = try? JSONDecoder().decode(SavedSession.self, from: data) {
            canRestore = saved.expiresAt > .now
        }
        configureMedia(iceServers: [], relayOnly: false)
    }

    func startDirectSession() async {
        guard !isBusy else { return }
        var operationGeneration = sessionGeneration
        isBusy = true
        defer { if operationGeneration == sessionGeneration { isBusy = false } }
        operationGeneration = await reset(endServerSession: true, preserveBusy: true)
        guard operationGeneration == sessionGeneration else { return }
        mode = .direct
        approved = true
        connectivity = "Direct LAN"
        configureMedia(iceServers: [], relayOnly: false)
        status = role == .sender ? "Share the screen, then copy the offer to the Mac." : "Import the phone's offer to connect."
        #if os(macOS)
        presentation.showWindow()
        #endif
    }

    func createInternetSession() async {
        guard !isBusy else { return }
        var operationGeneration = sessionGeneration
        var initializationStarted = false
        isBusy = true
        defer { if operationGeneration == sessionGeneration { isBusy = false } }
        do {
            guard let server = URL(string: serverAddress) else { throw PairingError.invalidServer }
            _ = try PairingCode.validateServer(server)
            guard !ownerToken.isEmpty else {
                throw NSError(domain: "scrnshr", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter the server's owner credential first."])
            }
            operationGeneration = await reset(endServerSession: true, preserveBusy: true)
            guard operationGeneration == sessionGeneration else { return }
            initializationStarted = true
            mode = .internet
            status = "Creating session"
            let created = try await signaling.createSession(server: server, ownerToken: ownerToken)
            guard operationGeneration == sessionGeneration else { return }
            let expiration = try created.expiration
            let pairing = try PairingCode(server: server, sessionId: created.sessionId,
                                          joinToken: created.joinToken, expiresAt: expiration)
            code = pairing
            token = created.receiverToken
            expiresAt = expiration
            scheduleExpiry(expiration)
            authenticator = try SignalAuthenticator(sessionId: pairing.sessionId, pairingKey: pairing.pairingKey, role: role)
            pairingURL = try pairing.url.absoluteString
            UserDefaults.standard.set(server.absoluteString, forKey: "signaling-server")
            try KeychainStore.save(Data(ownerToken.utf8), account: ownerCredentialAccount)
            try saveSession()
            let ice = try await signaling.iceConfiguration(server: server, sessionId: pairing.sessionId, token: created.receiverToken)
            guard operationGeneration == sessionGeneration else { return }
            connectivity = ice.connectivity
            configureMedia(iceServers: ice.iceServers, relayOnly: relayOnly)
            internetMediaConfigured = true
            signalingGeneration = operationGeneration
            try signaling.connect(server: server, sessionId: pairing.sessionId, token: created.receiverToken)
            status = "Scan the code on the iPhone."
            #if os(macOS)
            presentation.showWindow()
            #endif
        } catch {
            guard operationGeneration == sessionGeneration else { return }
            if initializationStarted {
                operationGeneration = await reset(preserveBusy: true)
                guard operationGeneration == sessionGeneration else { return }
                KeychainStore.delete(account: sessionCredentialAccount)
                canRestore = false
                status = "Session creation failed. Create a new session to retry."
            }
            fail(error)
        }
    }

    func joinInternetSession(_ text: String) async {
        guard !isBusy else { return }
        var operationGeneration = sessionGeneration
        isBusy = true
        defer { if operationGeneration == sessionGeneration { isBusy = false } }
        do {
            let pairing = try PairingCode.parse(text)
            operationGeneration = await reset(endServerSession: true, preserveBusy: true)
            guard operationGeneration == sessionGeneration else { return }
            mode = .internet
            code = pairing
            token = pairing.joinToken
            expiresAt = pairing.expiresAt
            authenticator = try SignalAuthenticator(sessionId: pairing.sessionId, pairingKey: pairing.pairingKey, role: role)
            serverAddress = pairing.server.absoluteString
            signalingGeneration = operationGeneration
            try signaling.connect(server: pairing.server, sessionId: pairing.sessionId, token: pairing.joinToken)
            status = "Waiting for approval on the Mac."
            scheduleExpiry(pairing.expiresAt)
        } catch { if operationGeneration == sessionGeneration { fail(error) } }
    }

    func restoreSession() async {
        guard !isBusy else { return }
        var operationGeneration = sessionGeneration
        isBusy = true
        defer { if operationGeneration == sessionGeneration { isBusy = false } }
        do {
            guard let data = try KeychainStore.load(account: sessionCredentialAccount) else { throw PairingError.expired }
            let saved = try JSONDecoder().decode(SavedSession.self, from: data)
            guard saved.expiresAt > .now else { throw PairingError.expired }
            _ = try PairingCode.validateServer(saved.code.server)
            #if os(macOS)
            presentation.blackout()
            #endif
            operationGeneration = await reset(preserveBusy: true)
            guard operationGeneration == sessionGeneration else { return }
            mode = .internet
            code = saved.code
            token = saved.token
            expiresAt = saved.expiresAt
            scheduleExpiry(saved.expiresAt)
            authenticator = try SignalAuthenticator(sessionId: saved.code.sessionId, pairingKey: saved.code.pairingKey,
                                                    role: role, checkpoint: saved.authentication)
            awaitingReceiverRestart = role == .receiver
            try await configureInternetMedia(expectedGeneration: operationGeneration)
            guard operationGeneration == sessionGeneration else { return }
            signalingGeneration = operationGeneration
            try signaling.connect(server: saved.code.server, sessionId: saved.code.sessionId, token: saved.token)
            approved = true
            status = role == .sender ? "Connected. Approve screen sharing again to resume." : "Waiting for the phone to reconnect."
            #if os(macOS)
            presentation.showWindow()
            #endif
        } catch {
            guard operationGeneration == sessionGeneration else { return }
            let failure = error as NSError
            if failure.domain == "scrnshr.signaling", [401, 410].contains(failure.code) {
                await requireFreshPairing()
            } else {
                approved = false
                fail(error)
            }
        }
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
        sessionGeneration &+= 1
        var operationGeneration = sessionGeneration
        signalingGeneration = nil
        isBusy = true
        defer { if operationGeneration == sessionGeneration { isBusy = false } }
        media.sendCaptureStatus(.stopped)
        closeMedia()
        #if os(iOS)
        await capture.stop()
        guard operationGeneration == sessionGeneration else { return }
        #endif
        await signaling.endSession()
        guard operationGeneration == sessionGeneration else { return }
        operationGeneration = await reset(preserveBusy: true)
        guard operationGeneration == sessionGeneration else { return }
        KeychainStore.delete(account: sessionCredentialAccount)
        canRestore = false
        status = "Sharing stopped"
        #if os(macOS)
        presentation.setCaptureStatus(.stopped)
        #endif
    }

    @discardableResult
    private func reset(endServerSession: Bool = false, preserveBusy: Bool = false) async -> UInt64 {
        sessionGeneration &+= 1
        let operationGeneration = sessionGeneration
        signalingGeneration = nil
        isBusy = preserveBusy
        expiryTask?.cancel()
        suppressCaptureCallbacks = true
        if endServerSession, code != nil { media.sendCaptureStatus(.stopped) }
        closeMedia()
        #if os(iOS)
        await capture.stop()
        guard operationGeneration == sessionGeneration else { return operationGeneration }
        audioDevice.reset()
        #endif
        suppressCaptureCallbacks = false
        if endServerSession, code != nil {
            await signaling.endSession()
            guard operationGeneration == sessionGeneration else { return operationGeneration }
        }
        signaling.close()
        code = nil
        token = nil
        expiresAt = nil
        authenticator = nil
        approvalInitializationGeneration = nil
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
        return operationGeneration
    }

    private func closeMedia() {
        // sessionGeneration has already invalidated callbacks before any suspension.
        isSharing = false
        #if os(macOS)
        presentation.setCaptureStatus(.stopped)
        presentation.setVideoTrack(nil)
        #endif
        media.close()
    }

    private func configureMedia(iceServers: [ICEServer], relayOnly: Bool) {
        installCallbacks()
        media.configure(iceServers: iceServers, relayOnly: relayOnly)
    }

    private func installCallbacks() {
        let generation = sessionGeneration
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
            guard let self, self.sessionGeneration == generation else { return }
            self.isSharing = status == .sharing
            #if os(macOS)
            self.presentation.setCaptureStatus(status)
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
        media.onVideoTrack = { [weak self] track in
            guard let self, self.sessionGeneration == generation else { return }
            self.presentation.setVideoTrack(track)
        }
        presentation.onMuteChanged = { [weak media] muted in media?.setRemoteAudioMuted(muted) }
        #endif
        signaling.onMessage = { [weak self] message in
            guard let self, let generation = self.signalingGeneration else { return }
            Task { @MainActor [weak self] in await self?.receive(message, expectedGeneration: generation) }
        }
        signaling.onAvailability = { [weak self] available in
            guard let self else { return }
            guard self.signalingGeneration == self.sessionGeneration else {
                if !available { self.signalingAvailable = false }
                return
            }
            let regained = available && !self.signalingAvailable
            self.signalingAvailable = available
            if regained, self.role == .sender, self.isSharing, self.approved,
               self.media.connectionState != .connected { self.media.startOffer() }
        }
        signaling.onPairingRequired = { [weak self] in
            guard let self, let generation = self.signalingGeneration else { return }
            Task { @MainActor [weak self] in
                guard let self, generation == self.sessionGeneration else { return }
                await self.requireFreshPairing()
            }
        }
        signaling.onError = { [weak self] message in
            guard let self, self.signalingGeneration == self.sessionGeneration else { return }
            self.error = message
        }
    }

    private func requireFreshPairing() async {
        let resetGeneration = await reset()
        guard resetGeneration == sessionGeneration else { return }
        KeychainStore.delete(account: sessionCredentialAccount)
        canRestore = false
        status = "Pairing required"
        error = "This session can no longer reconnect. Create a new session on the Mac and scan its new code on the iPhone."
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

    private func receive(_ message: ServerMessage, expectedGeneration: UInt64) async {
        guard expectedGeneration == sessionGeneration else { return }
        do {
            switch message.type {
            case "waiting": status = "Waiting for the other device"
            case "peer":
                if message.role == .receiver, isSharing, approved, media.connectionState != .connected { media.startOffer() }
            case "approval-required": approvalRequired = true; status = "Approve the phone to continue"
            case "approved":
                guard approvalInitializationGeneration != expectedGeneration else { return }
                approvalInitializationGeneration = expectedGeneration
                defer {
                    if approvalInitializationGeneration == expectedGeneration { approvalInitializationGeneration = nil }
                }
                if let resume = message.resumeToken {
                    guard Data(base64URL: resume)?.count == 32 else { throw PairingError.invalidCode }
                    token = resume
                    signaling.updateToken(resume)
                    if let code { expiresAt = code.expiresAt; scheduleExpiry(code.expiresAt) }
                }
                // Approval revokes the join token: retain the validated replacement even if ICE fails.
                try saveSession()
                try await configureInternetMedia(expectedGeneration: expectedGeneration, maximumAttempts: 3)
                guard expectedGeneration == sessionGeneration else { return }
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
                let resetGeneration = await reset()
                guard resetGeneration == sessionGeneration else { return }
                KeychainStore.delete(account: sessionCredentialAccount)
                canRestore = false
                status = message.type == "rejected" ? "The Mac declined this phone." : "Session ended"
            case "error": error = message.message ?? "The signaling server could not complete the request."
            default: throw PairingError.invalidCode
            }
        } catch { if expectedGeneration == sessionGeneration { fail(error) } }
    }

    private func configureInternetMedia(expectedGeneration: UInt64, maximumAttempts: Int = 1) async throws {
        guard expectedGeneration == sessionGeneration else { throw CancellationError() }
        guard !internetMediaConfigured else { return }
        guard let code, let token else { throw PairingError.invalidCode }
        let ice = try await fetchICE(code: code, token: token, expectedGeneration: expectedGeneration,
                                     maximumAttempts: maximumAttempts)
        guard expectedGeneration == sessionGeneration, self.code?.sessionId == code.sessionId else {
            throw CancellationError()
        }
        connectivity = ice.connectivity
        configureMedia(iceServers: ice.iceServers, relayOnly: relayOnly)
        internetMediaConfigured = true
    }

    private func fetchICE(code: PairingCode, token: String, expectedGeneration: UInt64,
                          maximumAttempts: Int) async throws -> ICEConfiguration {
        var attempt = 0
        while true {
            guard expectedGeneration == sessionGeneration, !Task.isCancelled else { throw CancellationError() }
            attempt += 1
            do {
                return try await signaling.iceConfiguration(server: code.server, sessionId: code.sessionId, token: token)
            } catch {
                guard expectedGeneration == sessionGeneration else { throw CancellationError() }
                let failure = error as NSError
                let transient = (failure.domain == NSURLErrorDomain && failure.code != NSURLErrorCancelled)
                    || (failure.domain == "scrnshr.signaling" && (failure.code == 429 || (500...599).contains(failure.code)))
                guard transient, attempt < maximumAttempts else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    private func saveSession() throws {
        guard let code, let token, let expiresAt else { return }
        let saved = SavedSession(code: code, token: token, expiresAt: expiresAt,
                                 authentication: authenticator?.checkpoint)
        try KeychainStore.save(JSONEncoder().encode(saved), account: sessionCredentialAccount)
        canRestore = expiresAt > .now
    }

    private func scheduleExpiry(_ expiration: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            let interval = min(max(0, expiration.timeIntervalSinceNow), PairingCode.maximumSessionDelay)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.stop()
            self.status = "Session expired. Create a new session."
        }
    }

    private func fail(_ error: Error) { self.error = error.localizedDescription }
}
