// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import Combine
import CoreMedia
@preconcurrency import ScreenCaptureKit
import UIKit

@MainActor
final class ScreenCaptureController: NSObject, ObservableObject {
    @Published private(set) var isCapturing = false
    @Published private(set) var isStarting = false

    var onVideo: ((CMSampleBuffer) -> Void)?
    var onStatus: ((CaptureStatus) -> Void)?
    var onError: ((String) -> Void)?

    private let audioDevice: AppAudioDevice
    private let picker = SCContentSharingPicker.shared
    private let videoQueue = DispatchQueue(label: "systems.edmundlim.scrnshr.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "systems.edmundlim.scrnshr.capture.audio", qos: .userInteractive)
    private var observer: CapturePickerObserver?
    private var output: CaptureSampleOutput?
    private var stream: SCStream?
    private var generation: UInt64 = 0
    private var pickerPresented = false

    init(audioDevice: AppAudioDevice) {
        self.audioDevice = audioDevice
        super.init()
    }

    func start() {
        guard !isCapturing, !isStarting, !pickerPresented else { return }
        generation &+= 1
        let observer = CapturePickerObserver(controller: self, generation: generation)
        self.observer = observer
        var configuration = SCContentSharingPickerConfiguration()
        configuration.showsMicrophoneControl = false
        picker.defaultConfiguration = configuration
        picker.add(observer)
        picker.isActive = true
        pickerPresented = true
        onStatus?(.ready)
        picker.present()
    }

    func stop() async {
        generation &+= 1
        let previous = stream
        let previousOutput = output
        stream = nil
        output = nil
        previousOutput?.disable()
        deactivatePicker()
        isStarting = false
        isCapturing = false
        audioDevice.reset()
        onStatus?(.stopped)
        if let previous {
            try? await previous.stopCapture()
            if let previousOutput {
                try? previous.removeStreamOutput(previousOutput, type: .screen)
                try? previous.removeStreamOutput(previousOutput, type: .audio)
            }
        }
    }

    fileprivate func picked(_ filter: SCContentFilter, for existing: SCStream?, generation request: UInt64) async {
        guard request == generation, pickerPresented, !isStarting, !isCapturing else { return }
        pickerPresented = false
        isStarting = true
        audioDevice.reset()

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        let bounds = UIScreen.main.nativeBounds
        configuration.width = Int(bounds.width)
        configuration.height = Int(bounds.height)

        let output = CaptureSampleOutput(audioDevice: audioDevice) { [weak self] sample in
            guard let self, self.generation == request else { return }
            self.onVideo?(sample)
        } onAudioError: { [weak self] in
            guard let self, self.generation == request else { return }
            self.onError?("The screen audio format could not be sent. Stop sharing and try again.")
        } onCaptureUnavailable: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == request else { return }
                await self.stop()
            }
        }
        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = newStream
        self.output = output
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
            try await newStream.startCapture()
            guard request == generation, stream === newStream else {
                output.disable()
                try? await newStream.stopCapture()
                return
            }
            isStarting = false
            isCapturing = true
            onStatus?(.sharing)
        } catch {
            output.disable()
            try? await newStream.stopCapture()
            guard request == generation else { return }
            stream = nil
            self.output = nil
            isStarting = false
            isCapturing = false
            audioDevice.reset()
            deactivatePicker()
            onStatus?(.stopped)
            onError?(error.localizedDescription)
        }
    }

    fileprivate func pickerCancelled(for existing: SCStream?, generation request: UInt64) {
        guard request == generation, existing == nil, !isStarting, !isCapturing else { return }
        generation &+= 1
        deactivatePicker()
        onStatus?(.ready)
    }

    fileprivate func pickerFailed(_ error: Error, generation request: UInt64) async {
        guard request == generation else { return }
        await stop()
        guard generation == request &+ 1 else { return }
        onError?(error.localizedDescription)
    }

    private func deactivatePicker() {
        pickerPresented = false
        if let observer {
            picker.remove(observer)
            self.observer = nil
        }
        picker.isActive = false
    }
}

extension ScreenCaptureController: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, self.stream === stream else { return }
            let stoppedGeneration = self.generation &+ 1
            await self.stop()
            guard self.generation == stoppedGeneration else { return }
            self.onError?(error.localizedDescription)
        }
    }
}

private final class CapturePickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private weak var controller: ScreenCaptureController?
    private let generation: UInt64

    init(controller: ScreenCaptureController, generation: UInt64) {
        self.controller = controller
        self.generation = generation
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await controller?.picked(filter, for: stream, generation: generation)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            controller?.pickerCancelled(for: stream, generation: generation)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await controller?.pickerFailed(error, generation: generation)
        }
    }
}

// The main actor receives at most one pending frame, even if rendering is slower than capture.
private final class CaptureSampleOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let audioDevice: AppAudioDevice
    private let onVideo: @MainActor (CMSampleBuffer) -> Void
    private let onAudioError: @MainActor () -> Void
    private let onCaptureUnavailable: @MainActor () -> Void
    private var enabled = true
    private var pendingVideo: CMSampleBuffer?
    private var videoScheduled = false
    private var audioErrorReported = false

    init(audioDevice: AppAudioDevice, onVideo: @escaping @MainActor (CMSampleBuffer) -> Void,
         onAudioError: @escaping @MainActor () -> Void,
         onCaptureUnavailable: @escaping @MainActor () -> Void) {
        self.audioDevice = audioDevice
        self.onVideo = onVideo
        self.onAudioError = onAudioError
        self.onCaptureUnavailable = onCaptureUnavailable
        super.init()
    }

    func disable() {
        lock.lock()
        enabled = false
        pendingVideo = nil
        lock.unlock()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock()
        guard enabled else {
            lock.unlock()
            return
        }
        switch type {
        case .screen:
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
               let status = attachments.first?[.status] as? NSNumber,
               let frameStatus = SCFrameStatus(rawValue: status.intValue),
               frameStatus == .stopped || frameStatus == .suspended || frameStatus == .blank {
                enabled = false
                pendingVideo = nil
                audioDevice.reset()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in self?.onCaptureUnavailable() }
                return
            }
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
                  CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
                lock.unlock()
                return
            }
            pendingVideo = sampleBuffer
            let shouldSchedule = !videoScheduled
            videoScheduled = true
            lock.unlock()
            if shouldSchedule {
                DispatchQueue.main.async { [weak self] in self?.deliverVideo() }
            }
        case .audio:
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer) else {
                lock.unlock()
                return
            }
            let accepted = audioDevice.push(sampleBuffer: sampleBuffer)
            let shouldReport = !accepted && !audioErrorReported
            if shouldReport { audioErrorReported = true }
            lock.unlock()
            if shouldReport {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isEnabled else { return }
                    self.onAudioError()
                }
            }
        default:
            lock.unlock()
        }
    }

    private var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    @MainActor private func deliverVideo() {
        lock.lock()
        let frame = enabled ? pendingVideo : nil
        pendingVideo = nil
        videoScheduled = false
        lock.unlock()
        if let frame { onVideo(frame) }
    }
}
