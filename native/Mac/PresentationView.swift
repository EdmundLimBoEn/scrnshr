// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

#if os(macOS)
import AppKit
import WebRTC

@MainActor
final class PresentationView: NSView {
    private var videoView: RTCMTLNSVideoView? = RTCMTLNSVideoView.isMetalAvailable()
        ? RTCMTLNSVideoView(frame: .zero) : nil
    private let cover = PresentationCover(frame: .zero)
    private var videoSize = CGSize(width: 9, height: 19.5)
    private var rendererHasSize = false

    override var isOpaque: Bool { true }
    var canRenderVideo: Bool { videoView != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if let videoView { addSubview(videoView) }
        addSubview(cover)
        obscure(message: "Waiting for screen sharing")
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func layout() {
        super.layout()
        videoView?.frame = fittedRect(for: videoSize, inside: bounds)
        cover.frame = bounds
    }

    func render(_ frame: RTCVideoFrame, displaySize: CGSize) {
        let sizeChanged = videoSize != displaySize
        videoSize = displaySize
        if sizeChanged {
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        videoView?.renderFrame(frame)
        if sizeChanged || !rendererHasSize {
            videoView?.setSize(displaySize)
            rendererHasSize = true
        }
    }

    func discardRetainedPicture() {
        // WebRTC's Metal renderer ignores renderFrame(nil), retaining its last texture.
        rendererHasSize = false
        videoView?.removeFromSuperview()
        if RTCMTLNSVideoView.isMetalAvailable() {
            let replacement = RTCMTLNSVideoView(frame: fittedRect(for: videoSize, inside: bounds))
            videoView = replacement
            addSubview(replacement, positioned: .below, relativeTo: cover)
        } else {
            videoView = nil
        }
        obscure(message: cover.message)
    }

    func obscure(message: String) {
        cover.message = message
        cover.isHidden = false
        videoView?.isHidden = true
        setAccessibilityLabel(message.isEmpty ? "Presentation blacked out" : message)
    }

    func reveal() {
        videoView?.isHidden = false
        cover.isHidden = true
        setAccessibilityLabel("iPhone screen")
    }

    private func fittedRect(for size: CGSize, inside bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }
}

@MainActor
private final class PresentationCover: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    var message: String = "" {
        didSet {
            guard message != oldValue else { return }
            label.stringValue = message
            needsLayout = true
        }
    }

    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.opacity = 1
        label.font = .systemFont(ofSize: 24, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.isSelectable = false
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
    }

    override func layout() {
        super.layout()
        let width = max(0, min(600, bounds.width - 48))
        let height = label.cell?.cellSize(
            forBounds: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        ).height ?? 30
        label.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}
#endif
