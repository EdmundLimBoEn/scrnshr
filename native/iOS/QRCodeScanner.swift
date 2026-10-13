// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AVFoundation
import SwiftUI
import UIKit

@MainActor
struct QRCodeScanner: UIViewRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void = { _ in }) {
        self.onCode = onCode
        self.onError = onError
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onError: onError) }

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: ScannerView, context: Context) {
        context.coordinator.onCode = onCode
        context.coordinator.onError = onError
    }

    static func dismantleUIView(_ uiView: ScannerView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.previewLayer.session = nil
    }

    @MainActor
    final class Coordinator {
        var onCode: (String) -> Void
        var onError: (String) -> Void
        private weak var view: ScannerView?
        private var camera: CameraController?
        private var observers: [NSObjectProtocol] = []
        private var reportedError: String?

        init(onCode: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onCode = onCode
            self.onError = onError
        }

        func attach(to view: ScannerView) {
            self.view = view
            let camera = CameraController { [weak self] event in
                Task { @MainActor in self?.receive(event) }
            }
            self.camera = camera
            view.previewLayer.session = camera.session
            observers = [
                NotificationCenter.default.addObserver(
                    forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.camera?.pause() }
                },
                NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.camera?.start() }
                }
            ]
            camera.start()
        }

        func detach() {
            view = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            camera?.stop()
            camera = nil
        }

        private func receive(_ event: CameraController.Event) {
            guard let view else { return }
            switch event {
            case .ready:
                reportedError = nil
                view.show(message: nil)
                view.setNeedsLayout()
            case .error(let message, let settings):
                view.show(message: message, settings: settings)
                if reportedError != message {
                    reportedError = message
                    onError(message)
                }
            case .code(let code):
                detach()
                onCode(code)
            }
        }
    }

    @MainActor
    final class ScannerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private let message = UILabel()
        private let settings = UIButton(type: .system)
        private let panel = UIStackView()
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        init() {
            super.init(frame: .zero)
            backgroundColor = .black
            previewLayer.videoGravity = .resizeAspectFill
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
                rotationCoordinator = coordinator
                rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview) { [weak self] _, _ in
                    Task { @MainActor in self?.setNeedsLayout() }
                }
            }
            message.textColor = .white
            message.textAlignment = .center
            message.numberOfLines = 0
            message.text = "Requesting camera access…"
            settings.setTitle("Open Settings", for: .normal)
            settings.isHidden = true
            settings.addAction(UIAction { _ in
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }, for: .touchUpInside)
            panel.axis = .vertical
            panel.spacing = 16
            panel.addArrangedSubview(message)
            panel.addArrangedSubview(settings)
            panel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(panel)
            NSLayoutConstraint.activate([
                panel.centerYAnchor.constraint(equalTo: centerYAnchor),
                panel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
                panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
            ])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func show(message text: String?, settings canOpenSettings: Bool = false) {
            message.text = text
            panel.isHidden = text == nil
            settings.isHidden = !canOpenSettings
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection, let rotationCoordinator else { return }
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}

// Capture configuration, lifecycle flags, and metadata callbacks belong to this queue.
private final class CameraController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case ready
        case error(String, settings: Bool)
        case code(String)
    }

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "systems.edmundlim.scrnshr.qr-camera")
    private let onEvent: @Sendable (Event) -> Void
    private var output: AVCaptureMetadataOutput?
    private var active = false
    private var stopped = false
    private var scanned = false
    private var requestingPermission = false

    init(onEvent: @escaping @Sendable (Event) -> Void) {
        self.onEvent = onEvent
        super.init()
    }

    func start() {
        queue.async { [self] in
            guard !stopped, !scanned else { return }
            active = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: startAuthorized()
            case .notDetermined:
                guard !requestingPermission else { return }
                requestingPermission = true
                AVCaptureDevice.requestAccess(for: .video) { [self] granted in
                    queue.async { [self] in
                        requestingPermission = false
                        guard active, !stopped, !scanned else { return }
                        if granted { startAuthorized() } else { permissionDenied() }
                    }
                }
            default: permissionDenied()
            }
        }
    }

    func pause() {
        queue.async { [self] in
            active = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            active = false
            if session.isRunning { session.stopRunning() }
            output?.setMetadataObjectsDelegate(nil, queue: nil)
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration()
            output = nil
        }
    }

    private func permissionDenied() {
        onEvent(.error("Allow camera access in Settings to scan the Mac's pairing code.", settings: true))
    }

    private func startAuthorized() {
        if output == nil {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                onEvent(.error("The camera is unavailable. Enter the pairing link instead.", settings: false))
                return
            }
            let metadata = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(metadata) else {
                session.commitConfiguration()
                onEvent(.error("The camera cannot scan QR codes. Enter the pairing link instead.", settings: false))
                return
            }
            session.addInput(input)
            session.addOutput(metadata)
            guard metadata.availableMetadataObjectTypes.contains(.qr) else {
                session.removeOutput(metadata)
                session.removeInput(input)
                session.commitConfiguration()
                onEvent(.error("QR scanning is unavailable. Enter the pairing link instead.", settings: false))
                return
            }
            metadata.setMetadataObjectsDelegate(self, queue: queue)
            metadata.metadataObjectTypes = [.qr]
            session.commitConfiguration()
            output = metadata
        }
        if !session.isRunning { session.startRunning() }
        if session.isRunning {
            onEvent(.ready)
        } else {
            onEvent(.error("The camera could not start. Enter the pairing link instead.", settings: false))
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard active, !stopped, !scanned,
              let code = objects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue })
                .first(where: { !$0.isEmpty }) else { return }
        scanned = true
        onEvent(.code(code))
        pause()
    }
}
