// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

import Combine
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
@preconcurrency import WebRTC

@MainActor
public final class WebRTCSession: NSObject, ObservableObject {
    @Published public private(set) var connectionState: MediaConnectionState = .idle
    @Published public private(set) var remoteVideoTrack: RTCVideoTrack?

    public var onSignal: ((RTCSignal) -> Void)?
    public var onCaptureStatus: ((CaptureStatus) -> Void)?
    public var onConnectionState: ((MediaConnectionState) -> Void)?
    public var onVideoTrack: ((RTCVideoTrack) -> Void)?
    public var onError: ((String) -> Void)?

    public let role: PeerRole
    private let factory: RTCPeerConnectionFactory
    private let hasCustomAudioDevice: Bool
    private nonisolated let videoInput = ScreenVideoInput()
    private var peer: RTCPeerConnection?
    private var localVideo: RTCVideoTrack?
    private var localAudio: RTCAudioTrack?
    private var remoteAudio: [RTCAudioTrack] = []
    private var remoteAudioMuted = false
    private var statusChannel: RTCDataChannel?
    private var localCaptureStatus: CaptureStatus = .ready
    private var remoteCaptureStatus: CaptureStatus = .ready
    private var pendingICE: [RTCIceCandidate] = []
    private var pendingLocalICE: [RTCIceCandidate] = []
    private var pendingDescriptions: [RTCSignal] = []
    private var activeOfferIdentity: String?
    private var activeAnswerIdentity: String?
    private var cachedOfferIdentity: String?
    private var cachedAnswer: String?
    private var applyingDescription = false
    private var creatingOffer = false
    private var offerPending = false
    private var restartPending = false
    private var hasNegotiated = false
    private var recoveryTask: Task<Void, Never>?
    private var captureStatusTask: Task<Void, Never>?
    private var captureHeartbeat: CaptureHeartbeatWatchdog?
    private var captureHeartbeatExpired = false
    private var recoveryExhausted = false

    private static let initializeSSL: Void = { _ = RTCInitializeSSL() }()

    #if os(iOS)
    public convenience init(role: PeerRole, audioDevice: RTCAudioDevice? = nil) {
        _ = Self.initializeSSL
        let encoder = Self.makeEncoder()
        let decoder = RTCDefaultVideoDecoderFactory()
        let factory: RTCPeerConnectionFactory
        if let audioDevice {
            factory = RTCPeerConnectionFactory(
                encoderFactory: encoder, decoderFactory: decoder, audioDevice: audioDevice
            )
        } else {
            factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        }
        self.init(role: role, factory: factory, hasCustomAudioDevice: audioDevice != nil)
    }
    #else
    public convenience init(role: PeerRole) {
        _ = Self.initializeSSL
        let factory = RTCPeerConnectionFactory(
            encoderFactory: Self.makeEncoder(), decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.init(role: role, factory: factory, hasCustomAudioDevice: false)
    }
    #endif

    private init(role: PeerRole, factory: RTCPeerConnectionFactory, hasCustomAudioDevice: Bool) {
        self.role = role
        self.factory = factory
        self.hasCustomAudioDevice = hasCustomAudioDevice
        super.init()
    }

    private static func makeEncoder() -> RTCDefaultVideoEncoderFactory {
        let encoder = RTCDefaultVideoEncoderFactory()
        if let h264 = encoder.supportedCodecs().first(where: { $0.name == "H264" }) {
            encoder.preferredCodec = h264
        }
        return encoder
    }

    public func configure(iceServers: [ICEServer], relayOnly: Bool = false) {
        guard role != .sender || hasCustomAudioDevice else {
            fail("Screen sharing requires the app-audio device. Microphone fallback is disabled.")
            return
        }
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceTransportPolicy = relayOnly ? .relay : .all
        configuration.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        if let peer {
            if !peer.setConfiguration(configuration) {
                onError?("The connection could not update its ICE servers.")
            }
            return
        }
        guard let newPeer = factory.peerConnection(
            with: configuration, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        ) else {
            fail("The media connection could not be created.")
            return
        }
        peer = newPeer
        setState(.idle)
        if role == .sender {
            let videoSource = factory.videoSource(forScreenCast: true)
            let video = factory.videoTrack(with: videoSource, trackId: "screen")
            let audioSource = factory.audioSource(with: RTCMediaConstraints(
                mandatoryConstraints: [
                    "googEchoCancellation": "false", "googAutoGainControl": "false",
                    "googNoiseSuppression": "false", "googHighpassFilter": "false"
                ], optionalConstraints: nil
            ))
            let audio = factory.audioTrack(with: audioSource, trackId: "app-audio")
            video.isEnabled = localCaptureStatus == .sharing
            audio.isEnabled = localCaptureStatus == .sharing
            let videoSettings = RTCRtpTransceiverInit()
            videoSettings.direction = .sendOnly
            videoSettings.streamIds = ["screen-share"]
            let audioSettings = RTCRtpTransceiverInit()
            audioSettings.direction = .sendOnly
            audioSettings.streamIds = ["screen-share"]
            guard let transceiver = newPeer.addTransceiver(with: video, init: videoSettings),
                  newPeer.addTransceiver(with: audio, init: audioSettings) != nil else {
                close()
                fail("The screen and app-audio tracks could not be created.")
                return
            }
            let parameters = transceiver.sender.parameters
            for encoding in parameters.encodings {
                encoding.maxFramerate = 30
                encoding.maxBitrateBps = 8_000_000
            }
            parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
            transceiver.sender.parameters = parameters
            localVideo = video
            localAudio = audio
            videoInput.attach(videoSource, enabled: localCaptureStatus == .sharing)
            let channelSettings = RTCDataChannelConfiguration()
            channelSettings.isOrdered = true
            guard let channel = newPeer.dataChannel(forLabel: "capture-status", configuration: channelSettings) else {
                close()
                fail("The capture status channel could not be created.")
                return
            }
            statusChannel = channel
            channel.delegate = self
        } else {
            let videoSettings = RTCRtpTransceiverInit()
            videoSettings.direction = .recvOnly
            let audioSettings = RTCRtpTransceiverInit()
            audioSettings.direction = .recvOnly
            guard newPeer.addTransceiver(of: .video, init: videoSettings) != nil,
                  newPeer.addTransceiver(of: .audio, init: audioSettings) != nil else {
                close()
                fail("The receiver tracks could not be created.")
                return
            }
        }
    }

    public func startOffer() {
        guard role == .sender, localCaptureStatus == .sharing, let peer else { return }
        if creatingOffer || applyingDescription {
            offerPending = true
            return
        }
        if peer.signalingState == .haveLocalOffer, let outstanding = peer.localDescription {
            // Signaling may have lost the offer while the receiver was offline.
            // The current local description also includes candidates gathered since it was created.
            offerPending = false
            restartPending = false
            onSignal?(.offer(outstanding.sdp))
            flushLocalICE()
            return
        }
        if peer.signalingState != .stable {
            offerPending = true
            return
        }
        offerPending = false
        creatingOffer = true
        let shouldRestart = restartPending
        if connectionState != .connected || shouldRestart {
            setState(hasNegotiated ? .reconnecting : .connecting)
        }
        restartPending = false
        if shouldRestart { peer.restartIce() }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: shouldRestart ? ["IceRestart": "true"] : nil,
            optionalConstraints: nil
        )
        peer.offer(for: constraints) { [weak self] description, error in
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                guard let description, error == nil else {
                    self.creatingOffer = false
                    self.fail(error?.localizedDescription ?? "The media offer could not be created.")
                    return
                }
                peer.setLocalDescription(description) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.peer === peer else { return }
                        self.creatingOffer = false
                        guard error == nil else {
                            self.fail(error!.localizedDescription)
                            return
                        }
                        self.onSignal?(.offer(description.sdp))
                        self.flushLocalICE()
                    }
                }
            }
        }
    }

    public func accept(_ signal: RTCSignal) {
        guard let peer else {
            onError?("Configure the media connection before importing a signal.")
            return
        }
        switch signal {
        case .ice(let candidate, let mid, let index):
            guard index >= 0, !candidate.isEmpty else { return }
            let ice = RTCIceCandidate(sdp: candidate, sdpMLineIndex: index, sdpMid: mid)
            if peer.remoteDescription == nil || applyingDescription {
                guard pendingICE.count < 256 else {
                    fail("Too many ICE candidates arrived before the session description.")
                    return
                }
                pendingICE.append(ice)
            } else {
                addICE(ice, to: peer)
            }
        case .offer(let sdp):
            if role == .receiver {
                let identity = SDPNegotiationIdentity.make(sdp)
                if activeOfferIdentity == identity {
                    acceptEmbeddedICE(sdp)
                    return
                }
                if let index = pendingDescriptions.firstIndex(where: {
                    if case .offer(let queued) = $0 { return SDPNegotiationIdentity.make(queued) == identity }
                    return false
                }) {
                    pendingDescriptions[index] = signal
                    return
                }
                if cachedOfferIdentity == identity, let cachedAnswer {
                    acceptEmbeddedICE(sdp)
                    onSignal?(.answer(peer.localDescription?.sdp ?? cachedAnswer))
                    flushLocalICE()
                    return
                }
            }
            enqueueDescription(signal)
        case .answer(let sdp):
            if role == .sender {
                if hasNegotiated, peer.signalingState == .stable {
                    acceptEmbeddedICE(sdp)
                    return
                }
                let identity = SDPNegotiationIdentity.make(sdp)
                if activeAnswerIdentity == identity {
                    acceptEmbeddedICE(sdp)
                    return
                }
                if let index = pendingDescriptions.firstIndex(where: {
                    if case .answer(let queued) = $0 { return SDPNegotiationIdentity.make(queued) == identity }
                    return false
                }) {
                    pendingDescriptions[index] = signal
                    return
                }
            }
            enqueueDescription(signal)
        case .restart:
            guard role == .sender, hasNegotiated, localCaptureStatus == .sharing else { return }
            restartPending = true
            startOffer()
        }
    }

    private func enqueueDescription(_ signal: RTCSignal) {
        guard pendingDescriptions.count < 4 else {
            fail("Too many overlapping session descriptions arrived.")
            return
        }
        pendingDescriptions.append(signal)
        applyNextDescription()
    }

    public nonisolated func sendVideo(_ sampleBuffer: CMSampleBuffer) {
        videoInput.offer(sampleBuffer)
    }

    public func sendCaptureStatus(_ status: CaptureStatus) {
        localCaptureStatus = status
        localVideo?.isEnabled = status == .sharing
        localAudio?.isEnabled = status == .sharing
        videoInput.setEnabled(status == .sharing)
        if status != .sharing {
            recoveryTask?.cancel()
            recoveryTask = nil
            restartPending = false
            offerPending = false
        }
        publishCaptureStatus()
    }

    public func setRemoteAudioMuted(_ muted: Bool) {
        remoteAudioMuted = muted
        for track in remoteAudio { track.isEnabled = !muted }
    }

    public func close() {
        recoveryTask?.cancel()
        recoveryTask = nil
        captureStatusTask?.cancel()
        captureStatusTask = nil
        captureHeartbeat = nil
        captureHeartbeatExpired = false
        recoveryExhausted = false
        videoInput.detach()
        statusChannel?.delegate = nil
        statusChannel?.close()
        statusChannel = nil
        let oldPeer = peer
        peer = nil
        oldPeer?.delegate = nil
        oldPeer?.close()
        localVideo = nil
        localAudio = nil
        remoteVideoTrack = nil
        remoteAudio.removeAll()
        pendingICE.removeAll()
        pendingLocalICE.removeAll()
        pendingDescriptions.removeAll()
        activeOfferIdentity = nil
        activeAnswerIdentity = nil
        cachedOfferIdentity = nil
        cachedAnswer = nil
        applyingDescription = false
        creatingOffer = false
        offerPending = false
        restartPending = false
        hasNegotiated = false
        remoteCaptureStatus = .ready
        localCaptureStatus = .ready
        setState(.closed)
    }

    public func statisticsSummary() async -> String {
        guard let peer else { return "{\"state\":\"closed\"}" }
        let captureDiagnostics = videoInput.diagnostics()
        let channelState: String
        switch statusChannel?.readyState {
        case .some(.connecting): channelState = "connecting"
        case .some(.open): channelState = "open"
        case .some(.closing): channelState = "closing"
        case .some(.closed): channelState = "closed"
        default: channelState = "unavailable"
        }
        let mediaDiagnostics = [
            "role": role.rawValue, "connectionState": connectionState.rawValue,
            "captureStatus": role == .sender ? localCaptureStatus.rawValue : remoteCaptureStatus.rawValue,
            "captureChannelState": channelState
        ]
        return await withCheckedContinuation { continuation in
            peer.statistics { report in
                let allowedKeys: Set<String> = [
                    "kind", "mediaType", "framesPerSecond", "frameWidth", "frameHeight",
                    "framesEncoded", "framesDecoded", "framesDropped", "packetsLost",
                    "bytesSent", "bytesReceived", "jitter", "jitterBufferDelay",
                    "jitterBufferEmittedCount", "currentRoundTripTime", "totalRoundTripTime",
                    "availableOutgoingBitrate", "nominated", "state", "candidateType",
                    "protocol", "relayProtocol", "qualityLimitationReason", "totalEncodeTime",
                    "totalDecodeTime", "totalSamplesReceived", "concealedSamples",
                    "codecId", "mimeType", "clockRate", "encoderImplementation", "decoderImplementation",
                    "powerEfficientEncoder", "powerEfficientDecoder", "frames", "keyFramesEncoded", "keyFramesDecoded",
                    "packetsSent", "nackCount", "pliCount", "firCount", "retransmittedBytesSent",
                    "framesSent", "framesReceived", "width", "height"
                ]
                let types: Set<String> = ["outbound-rtp", "inbound-rtp", "candidate-pair", "local-candidate", "remote-candidate", "codec", "media-source"]
                let entries: [[String: Any]] = report.statistics.values
                    .filter { types.contains($0.type) }
                    .sorted { $0.id < $1.id }
                    .map { ["id": $0.id, "type": $0.type, "values": $0.values.filter { allowedKeys.contains($0.key) }] }
                let data = try? JSONSerialization.data(withJSONObject: ["media": mediaDiagnostics, "capture": captureDiagnostics, "statistics": entries], options: [.prettyPrinted, .sortedKeys])
                continuation.resume(returning: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")
            }
        }
    }

    private func applyNextDescription() {
        guard !applyingDescription, !pendingDescriptions.isEmpty, let peer else { return }
        let signal = pendingDescriptions.removeFirst()
        let description: RTCSessionDescription
        let isOffer: Bool
        switch signal {
        case .offer(let sdp) where role == .receiver:
            description = RTCSessionDescription(type: .offer, sdp: sdp)
            activeOfferIdentity = SDPNegotiationIdentity.make(sdp)
            isOffer = true
        case .answer(let sdp) where role == .sender:
            if hasNegotiated, peer.signalingState == .stable {
                applyNextDescription()
                return
            }
            description = RTCSessionDescription(type: .answer, sdp: sdp)
            activeAnswerIdentity = SDPNegotiationIdentity.make(sdp)
            isOffer = false
        default:
            onError?("Only the iPhone sender can create a media offer.")
            applyNextDescription()
            return
        }
        applyingDescription = true
        if connectionState != .connected { setState(hasNegotiated ? .reconnecting : .connecting) }
        peer.setRemoteDescription(description) { [weak self] error in
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                guard error == nil else {
                    self.clearActiveDescription()
                    self.fail(error!.localizedDescription)
                    self.applyNextDescription()
                    return
                }
                let candidates = self.pendingICE
                self.pendingICE.removeAll()
                for candidate in candidates { self.addICE(candidate, to: peer) }
                if isOffer {
                    self.createAnswer(for: peer)
                } else {
                    self.finishDescription()
                }
            }
        }
    }

    private func createAnswer(for peer: RTCPeerConnection) {
        peer.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { [weak self] description, error in
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                guard let description, error == nil else {
                    self.clearActiveDescription()
                    self.fail(error?.localizedDescription ?? "The media answer could not be created.")
                    return
                }
                peer.setLocalDescription(description) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.peer === peer else { return }
                        guard error == nil else {
                            self.clearActiveDescription()
                            self.fail(error!.localizedDescription)
                            return
                        }
                        self.cachedOfferIdentity = self.activeOfferIdentity
                        self.cachedAnswer = description.sdp
                        self.onSignal?(.answer(description.sdp))
                        self.flushLocalICE()
                        self.finishDescription()
                    }
                }
            }
        }
    }

    private func finishDescription() {
        hasNegotiated = true
        clearActiveDescription()
        if let peer {
            let candidates = pendingICE
            pendingICE.removeAll()
            for candidate in candidates { addICE(candidate, to: peer) }
        }
        flushLocalICE()
        applyNextDescription()
        if offerPending { startOffer() }
    }

    private func clearActiveDescription() {
        applyingDescription = false
        activeOfferIdentity = nil
        activeAnswerIdentity = nil
    }

    private func acceptEmbeddedICE(_ sdp: String) {
        var index: Int32 = -1
        var mid: String?
        for line in sdp.components(separatedBy: .newlines) {
            if line.hasPrefix("m=") {
                index += 1
                mid = nil
            } else if line.hasPrefix("a=mid:") {
                mid = String(line.dropFirst(6))
            } else if line.hasPrefix("a=candidate:"), index >= 0 {
                accept(.ice(candidate: String(line.dropFirst(2)), sdpMid: mid, sdpMLineIndex: index))
            }
        }
    }

    private func addICE(_ candidate: RTCIceCandidate, to peer: RTCPeerConnection) {
        peer.add(candidate) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.peer === peer else { return }
                self.onError?("An ICE candidate could not be applied: \(error.localizedDescription)")
            }
        }
    }

    private func emitLocalICE(_ candidate: RTCIceCandidate) {
        onSignal?(.ice(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }

    private func flushLocalICE() {
        let candidates = pendingLocalICE
        pendingLocalICE.removeAll()
        for candidate in candidates { emitLocalICE(candidate) }
    }

    private func publishCaptureStatus() {
        guard role == .sender, let statusChannel, statusChannel.readyState == .open,
              statusChannel.bufferedAmount < 4096,
              let data = try? JSONEncoder().encode(CaptureStatusMessage(status: localCaptureStatus)) else { return }
        if !statusChannel.sendData(RTCDataBuffer(data: data, isBinary: false)) {
            onError?("The capture status could not be sent.")
        }
    }

    private func startCaptureHeartbeat() {
        guard captureStatusTask == nil, statusChannel?.readyState == .open else { return }
        if role == .receiver, captureHeartbeat == nil {
            captureHeartbeat = CaptureHeartbeatWatchdog(startedAt: ProcessInfo.processInfo.systemUptime)
        }
        publishCaptureStatus()
        refreshStaticPicture(force: true)
        captureStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, !Task.isCancelled, self.peer != nil else { return }
                if self.role == .sender {
                    self.publishCaptureStatus()
                    self.refreshStaticPicture()
                } else if !self.captureHeartbeatExpired,
                          self.captureHeartbeat?.isExpired(at: ProcessInfo.processInfo.systemUptime) == true {
                    // A static picture is healthy as long as capture status still arrives.
                    self.captureHeartbeatExpired = true
                    self.mediaStateChanged(.reconnecting)
                }
            }
        }
    }

    private func registerRemoteTrack(_ track: RTCMediaStreamTrack?) {
        if let video = track as? RTCVideoTrack {
            if remoteVideoTrack === video { return }
            remoteVideoTrack = video
            onVideoTrack?(video)
        } else if let audio = track as? RTCAudioTrack {
            audio.isEnabled = !remoteAudioMuted
            if let index = remoteAudio.firstIndex(where: { $0.trackId == audio.trackId }) {
                remoteAudio[index] = audio
            } else {
                remoteAudio.append(audio)
            }
        }
    }

    private func removeRemoteTrack(_ track: RTCMediaStreamTrack?) {
        guard let track else { return }
        remoteAudio.removeAll { $0.trackId == track.trackId }
        if remoteVideoTrack?.trackId == track.trackId {
            remoteVideoTrack = nil
            remoteCaptureStatus = .stopped
            onCaptureStatus?(.stopped)
        }
    }

    private func mediaStateChanged(_ state: MediaConnectionState) {
        if state == .connected {
            if role == .receiver {
                guard !captureHeartbeatExpired, statusChannel?.readyState != .closed,
                      statusChannel?.readyState != .closing else { return }
            }
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryExhausted = false
            setState(.connected)
            publishCaptureStatus()
            refreshStaticPicture(force: true)
        } else if state == .reconnecting || state == .failed {
            let sharing = role == .sender ? localCaptureStatus == .sharing : remoteCaptureStatus == .sharing
            guard sharing && hasNegotiated else {
                setState(state)
                return
            }
            guard !recoveryExhausted else {
                setState(.failed)
                return
            }
            setState(.reconnecting)
            guard recoveryTask == nil else { return }
            recoveryTask = Task { [weak self] in
                for seconds: UInt64 in [2, 5, 10] {
                    try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                    guard let self, !Task.isCancelled, self.peer != nil, self.connectionState != .connected else { return }
                    let stillSharing = self.role == .sender ? self.localCaptureStatus == .sharing : self.remoteCaptureStatus == .sharing
                    guard stillSharing else { return }
                    if self.role == .sender {
                        self.restartPending = true
                        self.startOffer()
                    } else {
                        self.onSignal?(.restart)
                    }
                }
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, !Task.isCancelled, self.connectionState != .connected else { return }
                self.recoveryTask = nil
                self.recoveryExhausted = true
                self.setState(.failed)
                self.onError?("The media connection could not recover. Reconnect the session to retry.")
            }
        } else {
            setState(state)
        }
    }

    private func setState(_ state: MediaConnectionState) {
        guard connectionState != state else { return }
        connectionState = state
        onConnectionState?(state)
    }

    private func refreshStaticPicture(force: Bool = false) {
        guard role == .sender, connectionState == .connected, localCaptureStatus == .sharing else { return }
        videoInput.refresh(force: force)
    }

    private func fail(_ message: String) {
        setState(.failed)
        onError?(message)
    }
}

extension WebRTCSession: RTCPeerConnectionDelegate {
    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            for track in stream.videoTracks { self.registerRemoteTrack(track) }
            for track in stream.audioTracks { self.registerRemoteTrack(track) }
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            for track in stream.videoTracks { self.removeRemoteTrack(track) }
            for track in stream.audioTracks { self.removeRemoteTrack(track) }
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .checking: self.mediaStateChanged(self.hasNegotiated ? .reconnecting : .connecting)
            case .connected, .completed:
                if peerConnection.connectionState == .connected { self.mediaStateChanged(.connected) }
            case .disconnected: self.mediaStateChanged(.reconnecting)
            case .failed: self.mediaStateChanged(.failed)
            case .closed: self.mediaStateChanged(.closed)
            default: break
            }
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            switch newState {
            case .connecting: self.mediaStateChanged(self.hasNegotiated ? .reconnecting : .connecting)
            case .connected: self.mediaStateChanged(.connected)
            case .disconnected: self.mediaStateChanged(.reconnecting)
            case .failed: self.mediaStateChanged(.failed)
            case .closed: self.mediaStateChanged(.closed)
            default: break
            }
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            if self.creatingOffer || self.applyingDescription {
                guard self.pendingLocalICE.count < 256 else {
                    self.fail("Too many local ICE candidates arrived during negotiation.")
                    return
                }
                self.pendingLocalICE.append(candidate)
            } else {
                self.emitLocalICE(candidate)
            }
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection, self.role == .receiver,
                  dataChannel.label == "capture-status", self.statusChannel == nil else {
                dataChannel.close()
                return
            }
            self.statusChannel = dataChannel
            dataChannel.delegate = self
            self.startCaptureHeartbeat()
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.registerRemoteTrack(rtpReceiver.track)
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.registerRemoteTrack(transceiver.receiver.track)
        }
    }

    public nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.removeRemoteTrack(rtpReceiver.track)
        }
    }
}

extension WebRTCSession: RTCDataChannelDelegate {
    public nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        Task { @MainActor [weak self] in
            guard let self, self.statusChannel === dataChannel else { return }
            if dataChannel.readyState == .open {
                self.startCaptureHeartbeat()
            } else if dataChannel.readyState == .closed {
                self.captureStatusTask?.cancel()
                self.captureStatusTask = nil
                self.captureHeartbeatExpired = true
                self.mediaStateChanged(.reconnecting)
            }
        }
    }

    public nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary, buffer.data.count <= 1024,
              let message = try? JSONDecoder().decode(CaptureStatusMessage.self, from: buffer.data),
              message.isValid else { return }
        Task { @MainActor [weak self] in
            guard let self, self.role == .receiver, self.statusChannel === dataChannel,
                  dataChannel.readyState == .open else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.captureHeartbeat == nil {
                self.captureHeartbeat = CaptureHeartbeatWatchdog(startedAt: now)
            } else {
                self.captureHeartbeat?.received(at: now)
            }
            self.remoteCaptureStatus = message.status
            self.captureHeartbeatExpired = false
            if message.status != .sharing {
                self.recoveryTask?.cancel()
                self.recoveryTask = nil
            }
            self.onCaptureStatus?(message.status)
            if self.peer?.connectionState == .connected {
                self.mediaStateChanged(.connected)
            }
        }
    }
}

private final class ScreenVideoInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "systems.edmund.scrnshr.video", qos: .userInteractive)
    private let lock = NSLock()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var source: RTCVideoSource?
    private var capturer: RTCVideoCapturer?
    private var latest: CMSampleBuffer?
    private var cachedFrame: RTCVideoFrame?
    private var lastCapturedHostTime: TimeInterval?
    private var refreshRequested = false
    private var framesOffered: UInt64 = 0
    private var framesCaptured: UInt64 = 0
    private var framesSubmitted: UInt64 = 0
    private var framesRefreshed: UInt64 = 0
    private var lastSubmittedTimestampNs: Int64?
    private var enabled = false
    private var draining = false
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var frameClock = CaptureFrameClock()
    private var lastWidth = 0
    private var lastHeight = 0

    func attach(_ source: RTCVideoSource, enabled: Bool) {
        lock.lock()
        self.source = source
        capturer = RTCVideoCapturer(delegate: source)
        self.enabled = enabled
        generation &+= 1
        latest = nil
        cachedFrame = nil
        lastCapturedHostTime = nil
        refreshRequested = false
        framesOffered = 0
        framesCaptured = 0
        framesSubmitted = 0
        framesRefreshed = 0
        lastSubmittedTimestampNs = nil
        lock.unlock()
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        if self.enabled != enabled {
            generation &+= 1
            latest = nil
            cachedFrame = nil
            lastCapturedHostTime = nil
            refreshRequested = false
        }
        self.enabled = enabled
        if !enabled { latest = nil }
        lock.unlock()
    }

    func detach() {
        lock.lock()
        enabled = false
        source = nil
        capturer = nil
        latest = nil
        cachedFrame = nil
        lastCapturedHostTime = nil
        refreshRequested = false
        generation &+= 1
        lock.unlock()
    }

    func offer(_ sample: CMSampleBuffer) {
        lock.lock()
        guard enabled, source != nil else { lock.unlock(); return }
        framesOffered &+= 1
        latest = sample
        let shouldStart = !draining
        draining = true
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    func refresh(force: Bool) {
        lock.lock()
        guard enabled, source != nil, cachedFrame != nil else { lock.unlock(); return }
        guard force || lastCapturedHostTime.map({ ProcessInfo.processInfo.systemUptime - $0 >= 1 }) == true else {
            lock.unlock()
            return
        }
        refreshRequested = true
        let shouldStart = !draining
        draining = true
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    func diagnostics() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var values: [String: Any] = [
            "enabled": enabled, "cachedFrame": cachedFrame != nil,
            "refreshRequested": refreshRequested, "pendingFrame": latest != nil,
            "framesOffered": framesOffered, "framesCaptured": framesCaptured,
            "framesSubmittedToSource": framesSubmitted, "framesRefreshed": framesRefreshed
        ]
        if let lastSubmittedTimestampNs { values["lastSubmittedTimestampNs"] = lastSubmittedTimestampNs }
        if let lastCapturedHostTime {
            values["secondsSinceCapture"] = max(0, ProcessInfo.processInfo.systemUptime - lastCapturedHostTime)
        }
        return values
    }

    private func drain() {
        while true {
            lock.lock()
            guard enabled, let source, let capturer,
                  latest != nil || (refreshRequested && cachedFrame != nil) else {
                draining = false
                lock.unlock()
                return
            }
            let sample = latest
            let refreshFrame = refreshRequested ? cachedFrame : nil
            latest = nil
            refreshRequested = false
            let currentGeneration = generation
            lock.unlock()
            if activeGeneration != currentGeneration {
                activeGeneration = currentGeneration
                frameClock.reset()
                lastWidth = 0
                lastHeight = 0
            }
            if sample == nil, let refreshFrame {
                guard let timestamp = frameClock.refreshTimestamp(hostTime: CMClockGetTime(CMClockGetHostTimeClock())) else { continue }
                let frame = RTCVideoFrame(buffer: refreshFrame.buffer, rotation: refreshFrame.rotation, timeStampNs: timestamp)
                lock.lock()
                let stillCurrent = enabled && generation == currentGeneration
                if stillCurrent {
                    framesSubmitted &+= 1
                    framesRefreshed &+= 1
                    lastSubmittedTimestampNs = timestamp
                }
                lock.unlock()
                if stillCurrent { source.capturer(capturer, didCapture: frame) }
                continue
            }
            guard let sample else { continue }
            guard CMSampleBufferIsValid(sample), let capturedBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let timestamp = frameClock.accept(
                presentationTime: pts, fallbackHostTime: CMClockGetTime(CMClockGetHostTimeClock())
            ) else { continue }
            let orientation = Self.orientation(sample)
            let pixelBuffer: CVPixelBuffer
            if orientation.mirrorBeforeRotation {
                guard let mirrored = mirror(capturedBuffer) else { continue }
                pixelBuffer = mirrored
            } else {
                pixelBuffer = capturedBuffer
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            guard width <= Int(Int32.max), height <= Int(Int32.max) else { continue }
            if width != lastWidth || height != lastHeight {
                // A fixed 16:9 request would crop the phone. Keep the actual capture ratio.
                source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 30)
                lastWidth = width
                lastHeight = height
            }
            let rotation: RTCVideoRotation
            switch orientation.rotationDegrees {
            case 90: rotation = ._90
            case 180: rotation = ._180
            case 270: rotation = ._270
            default: rotation = ._0
            }
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: rotation, timeStampNs: timestamp)
            lock.lock()
            let stillCurrent = enabled && generation == currentGeneration
            if stillCurrent {
                cachedFrame = frame
                lastCapturedHostTime = ProcessInfo.processInfo.systemUptime
                refreshRequested = false
                framesSubmitted &+= 1
                framesCaptured &+= 1
                lastSubmittedTimestampNs = timestamp
            }
            lock.unlock()
            guard stillCurrent else { continue }
            source.capturer(capturer, didCapture: frame)
        }
    }

    private static func orientation(_ sample: CMSampleBuffer) -> ScreenFrameOrientation {
        #if os(iOS) && canImport(ScreenCaptureKit)
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let number = attachments.first?[.videoOrientation] as? NSNumber else {
            return ScreenFrameOrientation(exifValue: 1)
        }
        return ScreenFrameOrientation(exifValue: number.uint32Value)
        #else
        return ScreenFrameOrientation(exifValue: 1)
        #endif
    }

    private func mirror(_ input: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        let image = CIImage(cvPixelBuffer: input)
            .transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(width), ty: 0))
        imageContext.render(image, to: output)
        return output
    }
}

struct CaptureFrameClock {
    private var lastTimestampNs: Int64?

    mutating func reset() { lastTimestampNs = nil }

    mutating func accept(presentationTime: CMTime, fallbackHostTime: CMTime) -> Int64? {
        guard let timestamp = Self.timestampNanoseconds(presentationTime: presentationTime, fallbackHostTime: fallbackHostTime),
              lastTimestampNs.map({ timestamp > $0 }) ?? true else { return nil }
        lastTimestampNs = timestamp
        return timestamp
    }

    mutating func refreshTimestamp(hostTime: CMTime) -> Int64? {
        guard let hostTimestamp = Self.timestampNanoseconds(presentationTime: hostTime, fallbackHostTime: hostTime) else { return nil }
        let timestamp: Int64
        if let previous = lastTimestampNs {
            guard previous < Int64.max else { return nil }
            timestamp = max(hostTimestamp, previous + 1)
        } else {
            timestamp = hostTimestamp
        }
        lastTimestampNs = timestamp
        return timestamp
    }

    static func timestampNanoseconds(presentationTime: CMTime, fallbackHostTime: CMTime) -> Int64? {
        let time = presentationTime.isNumeric ? presentationTime : fallbackHostTime
        let converted = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        guard converted.isNumeric, converted.value >= 0 else { return nil }
        return converted.value
    }
}
