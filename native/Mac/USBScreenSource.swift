// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
#if os(macOS)
import AVFoundation
import Combine
import CoreMediaIO
import WebRTC

struct USBScreenDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class USBScreenSource: ObservableObject {
    @Published private(set) var devices: [USBScreenDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "USB capture is experimental and video-only by default. Connect and trust your iPhone, then refresh."

    var onVideoFrame: ((RTCVideoFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onRunningChanged: ((Bool) -> Void)?

    private var generation = UUID()
    private lazy var pipeline = USBScreenPipeline(
        onDevices: { [weak self] devices in
            DispatchQueue.main.async { self?.devices = devices }
        },
        onFrame: { [weak self] frame, generation in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.onVideoFrame?(frame)
            }
        },
        onState: { [weak self] running, text, generation in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.updateState(running: running, text: text)
            }
        }
    )

    init() {}

    func refreshDevices() async {
        let result = await pipeline.refreshDevices()
        devices = result.devices
        if !isRunning {
            updateState(running: false, text: result.status)
        }
    }

    @discardableResult
    func scheduleStart(deviceID: String, includeAudio: Bool = false,
                       stopSession: @escaping @MainActor () async -> Void,
                       showPresentation: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        // Register the whole source switch synchronously, before the task can suspend.
        // All Stop and wireless source-switch actions already invalidate this generation.
        stop()
        let operation = generation
        return Task { @MainActor in
            guard generation == operation else { return }
            await stopSession()
            guard generation == operation else { return }
            showPresentation()
            await start(deviceID: deviceID, includeAudio: includeAudio)
        }
    }

    func start(deviceID: String, includeAudio: Bool = false) async {
        stop()
        let operation = generation
        let discovery = await pipeline.refreshDevices()
        guard generation == operation else { return }
        devices = discovery.devices
        guard devices.contains(where: { $0.id == deviceID }) else {
            updateState(running: false, text: discovery.status)
            return
        }
        updateState(running: false, text: includeAudio
            ? "Requesting iPhone screen access and experimental USB audio access. The audio feed may include speech."
            : "Requesting access to the connected iPhone screen. USB audio is off.")
        let mediaTypes: [AVMediaType] = includeAudio ? [.video, .audio] : [.video]
        for mediaType in mediaTypes {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: mediaType) {
            case .authorized:
                granted = true
            case .notDetermined:
                granted = await AVCaptureDevice.requestAccess(for: mediaType)
            default:
                granted = false
            }
            guard generation == operation else { return }
            guard granted else {
                let kind = mediaType == .video ? "Camera" : "Microphone"
                updateState(running: false, text: "Allow \(kind) access in System Settings for USB phone capture. Only the selected phone input is used.")
                return
            }
        }
        await pipeline.start(deviceID: deviceID, includeAudio: includeAudio, generation: operation)
    }

    func stop() {
        generation = UUID()
        pipeline.stop()
        updateState(running: false, text: "USB capture stopped.")
    }

    func setMuted(_ muted: Bool) {
        pipeline.setMuted(muted)
    }

    private func updateState(running: Bool, text: String) {
        let changed = isRunning != running
        isRunning = running
        statusText = text
        if changed { onRunningChanged?(running) }
        onStatus?(text)
    }
}

private struct USBDiscoveryResult: Sendable {
    let devices: [USBScreenDevice]
    let status: String
}

// All mutable capture and renderer state belongs to queue, including delegate callbacks.
private final class USBScreenPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onDevices: ([USBScreenDevice]) -> Void
    private let onFrame: (RTCVideoFrame, UUID) -> Void
    private let onState: (Bool, String, UUID) -> Void

    private let queue = DispatchQueue(label: "systems.edmundlim.scrnshr.usb", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var includesAudio = false
    private var selectedDeviceID: String?
    private var generation: UUID?
    private var observers: [NSObjectProtocol] = []
    private var sessionObservers: [NSObjectProtocol] = []
    private var livenessTimer: DispatchSourceTimer?
    private var receivedVideo = false
    private var dimensions: (Int, Int)?
    private var muted = false
    private var screenDevicesEnabled = false

    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var pendingAudio: [CMSampleBuffer] = []
    private var audioRequested = false
    private var audioClockStarted = false
    private var lastAudioTime: CMTime?

    init(onDevices: @escaping ([USBScreenDevice]) -> Void, onFrame: @escaping (RTCVideoFrame, UUID) -> Void, onState: @escaping (Bool, String, UUID) -> Void) {
        self.onDevices = onDevices
        self.onFrame = onFrame
        self.onState = onState
        super.init()
        synchronizer.addRenderer(audioRenderer)
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    if name == AVCaptureDevice.wasDisconnectedNotification, let deviceID, deviceID == self.selectedDeviceID {
                        self.fail("USB iPhone disconnected. Reconnect, unlock, and trust the phone before starting again.")
                    }
                    let result = self.discover()
                    self.onDevices(result.devices)
                }
            })
        }
    }

    deinit {
        for observer in observers + sessionObservers { NotificationCenter.default.removeObserver(observer) }
        livenessTimer?.cancel()
        audioRenderer.stopRequestingMediaData()
        audioRenderer.flush()
        session?.stopRunning()
    }

    func refreshDevices() async -> USBDiscoveryResult {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.discover()) }
        }
    }

    func start(deviceID: String, includeAudio: Bool, generation: UUID) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.startOnQueue(deviceID: deviceID, includeAudio: includeAudio, generation: generation)
                continuation.resume()
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    func setMuted(_ muted: Bool) {
        queue.async {
            self.muted = muted
            self.audioRenderer.isMuted = muted
        }
    }

    private func discover() -> USBDiscoveryResult {
        do {
            try allowScreenDevices()
            let allowedIDs = try screenDeviceIDs()
            let candidates = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .muxed, position: .unspecified).devices
            let devices = candidates.filter {
                allowedIDs.contains($0.uniqueID) && $0.isConnected && !$0.isContinuityCamera
                    && $0.hasMediaType(.video)
            }.map { USBScreenDevice(id: $0.uniqueID, name: $0.localizedName) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            let status = devices.isEmpty
                ? "No trusted USB iPhone screen input found. Unlock the phone, use a data cable, approve Trust, and refresh."
                : "Choose your iPhone for experimental video-only USB capture. USB audio requires a separate opt-in."
            return USBDiscoveryResult(devices: devices, status: status)
        } catch {
            return USBDiscoveryResult(devices: [], status: error.localizedDescription)
        }
    }

    private func startOnQueue(deviceID: String, includeAudio: Bool, generation: UUID) {
        stopOnQueue()
        self.generation = generation
        do {
            let discovery = discover()
            onDevices(discovery.devices)
            guard discovery.devices.contains(where: { $0.id == deviceID }),
                  let device = AVCaptureDevice(uniqueID: deviceID) else {
                throw USBScreenError.unavailable(discovery.status)
            }
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            if !includeAudio {
                for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
            }
            let video = AVCaptureVideoDataOutput()
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            video.alwaysDiscardsLateVideoFrames = true
            video.setSampleBufferDelegate(self, queue: queue)
            var audio: AVCaptureAudioDataOutput?
            if includeAudio {
                guard device.hasMediaType(.audio) else {
                    throw USBScreenError.unavailable("The selected USB iPhone input does not provide audio. Start with USB audio off.")
                }
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                audio = output
            }
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                throw USBScreenError.unavailable("The USB iPhone input is busy or unavailable. Close QuickTime or other capture apps and try again.")
            }
            session.addInput(input)
            guard session.canAddOutput(video) else {
                session.commitConfiguration()
                throw USBScreenError.unavailable("The USB iPhone input does not support screen video.")
            }
            session.addOutput(video)
            if let audio {
                guard session.canAddOutput(audio) else {
                    session.commitConfiguration()
                    throw USBScreenError.unavailable("The USB iPhone input does not support experimental audio capture. Start with USB audio off.")
                }
                session.addOutput(audio)
                guard audio.connection(with: .audio) != nil else {
                    session.commitConfiguration()
                    throw USBScreenError.unavailable("The selected phone has no USB audio connection. Start with USB audio off.")
                }
            }
            guard let connection = video.connection(with: .video) else {
                session.commitConfiguration()
                throw USBScreenError.unavailable("The selected phone has no USB screen connection.")
            }
            if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            session.commitConfiguration()
            self.session = session
            selectedDeviceID = deviceID
            videoOutput = video
            audioOutput = audio
            includesAudio = includeAudio
            installSessionObservers(session)
            audioRenderer.isMuted = muted
            session.startRunning()
            guard session.isRunning else {
                throw USBScreenError.unavailable("USB capture could not start. Unlock and trust the iPhone, then try again.")
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self, weak session] in
                guard let self, let session, self.session === session else { return }
                if !session.isRunning || !device.isConnected || device.isSuspended {
                    self.fail("USB capture is no longer active. Unlock the iPhone and start again.")
                }
            }
            livenessTimer = timer
            timer.resume()
            onState(false, includeAudio
                ? "Waiting for USB iPhone screen frames. Experimental USB audio is on and may include speech."
                : "Waiting for USB iPhone screen frames. USB audio is off.", generation)
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.generation == generation, !self.receivedVideo else { return }
                self.fail("No USB screen frames arrived. Check the cable, unlock and trust the iPhone, then start again.")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func installSessionObservers(_ session: AVCaptureSession) {
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification, AVCaptureSession.didStopRunningNotification] {
            sessionObservers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self, weak session] notification in
                let detail = notification.userInfo?.values.compactMap { ($0 as? NSError)?.localizedDescription }.first
                self?.queue.async { [weak self, weak session] in
                    guard let self, let session, self.session === session else { return }
                    self.fail(detail ?? "USB capture stopped or was interrupted. Unlock the iPhone and start again.")
                }
            })
        }
    }

    private func stopOnQueue() {
        let previous = session
        session = nil
        livenessTimer?.cancel()
        livenessTimer = nil
        for observer in sessionObservers { NotificationCenter.default.removeObserver(observer) }
        sessionObservers.removeAll()
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        audioOutput?.setSampleBufferDelegate(nil, queue: nil)
        previous?.stopRunning()
        videoOutput = nil
        audioOutput = nil
        includesAudio = false
        selectedDeviceID = nil
        generation = nil
        receivedVideo = false
        dimensions = nil
        resetAudio()
    }

    private func fail(_ text: String) {
        let current = generation
        stopOnQueue()
        if let current { onState(false, text, current) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let generation, session != nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if output === videoOutput {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard time.isNumeric, CMTimeCompare(time, .zero) >= 0 else { return }
            let nanoseconds = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default).value
            // Keep as-delivered pixels. USB orientation still requires hardware validation; do not add a second transform.
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixelBuffer), rotation: ._0, timeStampNs: nanoseconds)
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            if !receivedVideo || dimensions?.0 != width || dimensions?.1 != height {
                receivedVideo = true
                dimensions = (width, height)
                let audioState = includesAudio ? "Experimental audio is on and may include speech." : "Video-only. USB audio is off."
                onState(true, "Experimental USB capture: \(width) × \(height). \(audioState)", generation)
            }
            onFrame(frame, generation)
        } else if includesAudio, output === audioOutput {
            receiveAudio(sampleBuffer)
        }
    }

    private func receiveAudio(_ sampleBuffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isNumeric, CMTimeCompare(time, .zero) >= 0 else { return }
        if let lastAudioTime, CMTimeCompare(time, lastAudioTime) < 0 { resetAudio() }
        lastAudioTime = time
        if pendingAudio.count >= 8 { resetAudio() }
        pendingAudio.append(sampleBuffer)
        drainAudio()
    }

    private func drainAudio() {
        guard includesAudio, session != nil else { return }
        if audioRenderer.status == .failed {
            fail("USB audio playback failed: \(audioRenderer.error?.localizedDescription ?? "unknown error"). Start again after checking the Mac audio output.")
            return
        }
        while audioRenderer.isReadyForMoreMediaData, !pendingAudio.isEmpty {
            let sample = pendingAudio.removeFirst()
            audioRenderer.enqueue(sample)
            if !audioClockStarted {
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                let hostTime = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(value: 35, timescale: 1000))
                synchronizer.setRate(1, time: time, atHostTime: hostTime)
                audioClockStarted = true
            }
        }
        if pendingAudio.isEmpty {
            audioRenderer.stopRequestingMediaData()
            audioRequested = false
        } else if !audioRequested {
            audioRequested = true
            audioRenderer.requestMediaDataWhenReady(on: queue) { [weak self] in self?.drainAudio() }
        }
    }

    private func resetAudio() {
        audioRenderer.stopRequestingMediaData()
        synchronizer.setRate(0, time: .invalid)
        audioRenderer.flush()
        pendingAudio.removeAll()
        audioRequested = false
        audioClockStarted = false
        lastAudioTime = nil
    }

    private func allowScreenDevices() throws {
        guard !screenDevicesEnabled else { return }
        for (selector, value) in [(kCMIOHardwarePropertyAllowScreenCaptureDevices, UInt32(1)), (kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, UInt32(0))] {
            var address = propertyAddress(selector)
            var allowed = value
            let status = CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allowed)
            guard status == noErr else {
                throw USBScreenError.unavailable("macOS could not enable USB screen capture. CoreMediaIO error \(status).")
            }
        }
        screenDevicesEnabled = true
    }

    private func screenDeviceIDs() throws -> Set<String> {
        // This system plug-in is an implementation detail. Unknown creators fail closed rather than selecting a camera.
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/CoreMediaIO.framework/Resources/iOSScreenCapture.plugin")
        guard let creator = Bundle(url: url)?.bundleIdentifier, creator.hasPrefix("com.apple.") else {
            throw USBScreenError.unavailable("Apple's USB iPhone screen-capture plug-in is unavailable on this Mac. Use wireless sharing.")
        }
        var address = propertyAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size % UInt32(MemoryLayout<CMIOObjectID>.size) == 0, size <= 4096 else {
            throw USBScreenError.unavailable("macOS could not enumerate USB screen inputs.")
        }
        guard size != 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let status = ids.withUnsafeMutableBytes { bytes in
            CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, bytes.baseAddress)
        }
        guard status == noErr, used <= size, used % UInt32(MemoryLayout<CMIOObjectID>.size) == 0 else {
            throw USBScreenError.unavailable("macOS could not read USB screen inputs. CoreMediaIO error \(status).")
        }
        return Set(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size).compactMap { id in
            guard readString(id, selector: kCMIOObjectPropertyCreator) == creator else { return nil }
            return readString(id, selector: kCMIODevicePropertyDeviceUID)
        })
    }

    private func readString(_ objectID: CMIOObjectID, selector: Int) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(objectID, &address, 0, nil, size, &used, &value)
        let result = value?.takeRetainedValue()
        guard status == noErr, used == size, let result else { return nil }
        return result as String
    }

    private func propertyAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector), mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }
}

private enum USBScreenError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let text): return text
        }
    }
}
#endif
