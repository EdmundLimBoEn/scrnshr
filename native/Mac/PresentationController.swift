// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

#if os(macOS)
import AppKit
import Combine
import CoreGraphics
import WebRTC

@MainActor
final class PresentationController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isBlackedOut = false
    @Published private(set) var isMuted = true
    @Published private(set) var statusText = "Waiting for screen sharing"

    var onMuteChanged: ((Bool) -> Void)? {
        didSet { onMuteChanged?(isMuted) }
    }

    private var window: NSWindow?
    private var presentationView: PresentationView?
    private var videoTrack: RTCVideoTrack?
    private var frameSink: PresentationFrameSink?
    private var frameSinkID = UUID()
    private var connectionState: MediaConnectionState = .idle
    private var captureStatus: CaptureStatus = .ready
    private var userMuted = false
    private var hasCurrentPicture = false
    private var presentationVisible = false
    private var displayLossRequiresResume = false
    private var presentationDisplayID: CGDirectDisplayID?
    private var screenObserver: NSObjectProtocol?

    override init() {
        super.init()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkPresentationDisplay() }
        }
    }

    deinit {
        if let videoTrack, let frameSink { videoTrack.remove(frameSink) }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    func setVideoTrack(_ track: RTCVideoTrack?) {
        if let videoTrack, let frameSink {
            videoTrack.remove(frameSink)
        }
        videoTrack = track
        frameSink = nil
        frameSinkID = UUID()
        discardPicture()

        if let track {
            let sinkID = frameSinkID
            let sink = PresentationFrameSink { [weak self] frame, size in
                guard let self, self.frameSinkID == sinkID else { return }
                self.receive(frame, displaySize: size)
            }
            frameSink = sink
            track.add(sink)
        }
        updatePresentation()
    }

    func setConnectionState(_ state: MediaConnectionState) {
        guard connectionState != state else { return }
        frameSink?.discardPendingFrame()
        connectionState = state
        if state != .connected { discardPicture() }
        updatePresentation()
    }

    func setCaptureStatus(_ status: CaptureStatus) {
        guard captureStatus != status else { return }
        frameSink?.discardPendingFrame()
        captureStatus = status
        if status != .sharing { discardPicture() }
        updatePresentation()
    }

    func setUserMuted(_ muted: Bool) {
        userMuted = muted
        updatePresentation()
    }

    func blackout() {
        isBlackedOut = true
        updatePresentation()
    }

    func resume() {
        displayLossRequiresResume = false
        isBlackedOut = false
        updatePresentation()
    }

    func showWindow() {
        if window == nil {
            let view = PresentationView(frame: CGRect(x: 0, y: 0, width: 430, height: 820))
            let newWindow = NSWindow(
                contentRect: view.frame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            newWindow.title = "scrnshr Presentation"
            newWindow.backgroundColor = .black
            newWindow.isOpaque = true
            newWindow.isReleasedWhenClosed = false
            newWindow.collectionBehavior = [.fullScreenPrimary]
            newWindow.minSize = CGSize(width: 240, height: 300)
            newWindow.contentView = view
            newWindow.delegate = self
            newWindow.center()
            presentationView = view
            window = newWindow
            hasCurrentPicture = false
        }
        presentationVisible = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        recordPresentationDisplay()
        updatePresentation()
    }

    func toggleFullScreen() {
        showWindow()
        window?.toggleFullScreen(nil)
    }

    func close() {
        blackout()
        presentationVisible = false
        window?.close()
        updatePresentation()
    }

    func setExternalVideoFrame(_ frame: RTCVideoFrame) {
        let rotated = frame.rotation.rawValue % 180 != 0
        let size = CGSize(
            width: CGFloat(rotated ? frame.height : frame.width),
            height: CGFloat(rotated ? frame.width : frame.height)
        )
        receive(frame, displaySize: size)
    }

    func windowWillClose(_ notification: Notification) {
        presentationVisible = false
        isBlackedOut = true
        updatePresentation()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        recordPresentationDisplay()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        recordPresentationDisplay()
    }

    private func receive(_ frame: RTCVideoFrame, displaySize: CGSize) {
        guard connectionState == .connected, captureStatus == .sharing else { return }
        presentationView?.render(frame, displaySize: displaySize)
        hasCurrentPicture = presentationView?.canRenderVideo == true
        updatePresentation()
    }

    private func discardPicture() {
        guard hasCurrentPicture else { return }
        hasCurrentPicture = false
        presentationView?.discardRetainedPicture()
    }

    private func updatePresentation() {
        let canShowPicture = connectionState == .connected && captureStatus == .sharing && hasCurrentPicture
        let effectiveMute = userMuted || isBlackedOut || !canShowPicture || !presentationVisible
        if isMuted != effectiveMute {
            isMuted = effectiveMute
            onMuteChanged?(effectiveMute)
        }

        if isBlackedOut {
            setStatusText(displayLossRequiresResume
                ? "Display disconnected. Resume when your presentation display is ready."
                : "Presentation blacked out")
            presentationView?.obscure(message: "")
            return
        }

        let nextStatus: String
        if captureStatus == .stopped {
            nextStatus = "Screen sharing stopped"
        } else {
            switch connectionState {
            case .idle: nextStatus = "Waiting for a connection"
            case .connecting: nextStatus = "Connecting"
            case .connected:
                if presentationView?.canRenderVideo == false {
                    nextStatus = "Metal video rendering is unavailable on this Mac"
                } else {
                    nextStatus = captureStatus == .sharing
                        ? (hasCurrentPicture ? "Presenting iPhone screen" : "Waiting for the first picture")
                        : "Waiting for screen sharing"
                }
            case .reconnecting: nextStatus = "Reconnecting"
            case .failed: nextStatus = "Connection failed"
            case .closed: nextStatus = "Session ended"
            }
        }
        setStatusText(nextStatus)

        if canShowPicture {
            presentationView?.reveal()
        } else {
            presentationView?.obscure(message: statusText)
        }
    }

    private func setStatusText(_ text: String) {
        if statusText != text { statusText = text }
    }

    private func checkPresentationDisplay() {
        guard presentationVisible, let displayID = presentationDisplayID else { return }
        if !connectedDisplayIDs.contains(displayID) {
            displayLossRequiresResume = true
            blackout()
        }
    }

    private func recordPresentationDisplay() {
        // The OS may move the window before delivering its display-removal notification.
        checkPresentationDisplay()
        presentationDisplayID = window?.screen.flatMap(Self.displayID)
    }

    private var connectedDisplayIDs: Set<CGDirectDisplayID> {
        Set(NSScreen.screens.compactMap(Self.displayID))
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class PresentationFrameSink: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private let onFrame: @MainActor (RTCVideoFrame, CGSize) -> Void
    private var latestFrame: RTCVideoFrame?
    private var displaySize = CGSize.zero
    private var deliveryScheduled = false

    init(onFrame: @escaping @MainActor (RTCVideoFrame, CGSize) -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {
        lock.lock()
        displaySize = size
        lock.unlock()
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        latestFrame = frame
        if displaySize.width == 0 || displaySize.height == 0 {
            let rotated = frame.rotation.rawValue % 180 != 0
            displaySize = CGSize(
                width: CGFloat(rotated ? frame.height : frame.width),
                height: CGFloat(rotated ? frame.width : frame.height)
            )
        }
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatest() }
        }
    }

    func discardPendingFrame() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let frame = latestFrame
        let size = displaySize
        latestFrame = nil
        deliveryScheduled = false
        lock.unlock()
        if let frame { onFrame(frame, size) }
    }
}
#endif
