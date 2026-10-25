// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.

import AppKit
import CoreVideo
import WebRTC
import XCTest
@testable import ScrnshrMac

final class PresentationTests: XCTestCase {
    func testNoPictureRemainsMutedEvenWhenTransportIsConnected() async {
        await MainActor.run {
            let controller = PresentationController()
            var muteEvents: [Bool] = []
            controller.onMuteChanged = { muteEvents.append($0) }

            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            controller.setUserMuted(false)
            controller.resume()
            controller.setVideoTrack(nil)

            XCTAssertTrue(controller.isMuted)
            XCTAssertFalse(controller.isBlackedOut)
            XCTAssertEqual(controller.statusText, "Waiting for the first picture")
            XCTAssertEqual(muteEvents, [true])
        }
    }

    func testBlackoutSurvivesReconnectAndNewFramesUntilResume() async throws {
        try await MainActor.run {
            try Self.requireMetal()
            let controller = PresentationController()
            var muteEvents: [Bool] = []
            controller.onMuteChanged = { muteEvents.append($0) }
            controller.showWindow()
            defer { controller.close() }
            let view = try Self.presentationView()
            let frame = try Self.frame()

            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            controller.setExternalVideoFrame(frame)
            XCTAssertFalse(controller.isMuted)
            XCTAssertTrue(try Self.cover(in: view).isHidden)

            controller.blackout()
            XCTAssertTrue(controller.isMuted)
            try Self.assertOpaqueBlackCover(view)
            XCTAssertEqual(try Self.cover(in: view).subviews.compactMap { $0 as? NSTextField }.first?.stringValue, "")
            let previousRenderer = try Self.renderer(in: view)

            controller.setConnectionState(.reconnecting)
            XCTAssertFalse(try Self.renderer(in: view) === previousRenderer)
            controller.setConnectionState(.connected)
            controller.setExternalVideoFrame(frame)
            XCTAssertTrue(controller.isBlackedOut)
            XCTAssertTrue(controller.isMuted)
            try Self.assertOpaqueBlackCover(view)

            controller.resume()
            XCTAssertFalse(controller.isBlackedOut)
            XCTAssertFalse(controller.isMuted)
            XCTAssertTrue(try Self.cover(in: view).isHidden)
            XCTAssertEqual(muteEvents, [true, false, true, false])
        }
    }

    func testStopTrackRemovalAndFailureRequireANewPicture() async throws {
        try await MainActor.run {
            try Self.requireMetal()
            let controller = PresentationController()
            controller.showWindow()
            defer { controller.close() }
            let view = try Self.presentationView()
            let frame = try Self.frame()
            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            controller.setExternalVideoFrame(frame)
            let originalRenderer = try Self.renderer(in: view)

            controller.setCaptureStatus(.stopped)
            XCTAssertTrue(controller.isMuted)
            XCTAssertEqual(controller.statusText, "Screen sharing stopped")
            XCTAssertFalse(try Self.renderer(in: view) === originalRenderer)
            try Self.assertOpaqueBlackCover(view)

            controller.setCaptureStatus(.sharing)
            controller.resume()
            XCTAssertTrue(controller.isMuted)
            XCTAssertEqual(controller.statusText, "Waiting for the first picture")
            controller.setExternalVideoFrame(frame)
            XCTAssertFalse(controller.isMuted)

            let resumedRenderer = try Self.renderer(in: view)
            controller.setVideoTrack(nil)
            XCTAssertTrue(controller.isMuted)
            XCTAssertFalse(try Self.renderer(in: view) === resumedRenderer)
            try Self.assertOpaqueBlackCover(view)
            controller.setUserMuted(false)
            controller.resume()
            XCTAssertTrue(controller.isMuted)

            controller.setExternalVideoFrame(frame)
            controller.setConnectionState(.failed)
            XCTAssertTrue(controller.isMuted)
            XCTAssertEqual(controller.statusText, "Connection failed")
            try Self.assertOpaqueBlackCover(view)
            controller.setConnectionState(.connected)
            controller.resume()
            XCTAssertTrue(controller.isMuted)
            controller.setExternalVideoFrame(frame)
            XCTAssertFalse(controller.isMuted)
        }
    }

    func testRepeatedTeardownDiscardsReuseRendererUntilAnotherFrameArrives() async throws {
        try await MainActor.run {
            try Self.requireMetal()
            let controller = PresentationController()
            controller.showWindow()
            defer { controller.close() }
            let view = try Self.presentationView()
            let initialRenderer = try Self.renderer(in: view)

            controller.setVideoTrack(nil)
            controller.setCaptureStatus(.stopped)
            controller.setConnectionState(.closed)
            XCTAssertTrue(try Self.renderer(in: view) === initialRenderer)

            // Repeat after recovery, including a frame retained behind blackout.
            for blackedOut in [false, true] {
                controller.setConnectionState(.connected)
                controller.setCaptureStatus(.sharing)
                if blackedOut { controller.blackout() }
                controller.setExternalVideoFrame(try Self.frame())
                let populatedRenderer = try Self.renderer(in: view)

                controller.setCaptureStatus(.stopped)
                let clearedRenderer = try Self.renderer(in: view)
                XCTAssertFalse(clearedRenderer === populatedRenderer)
                XCTAssertNil(populatedRenderer.superview)
                XCTAssertTrue(controller.isMuted)
                try Self.assertOpaqueBlackCover(view)

                controller.setVideoTrack(nil)
                controller.setConnectionState(.closed)
                controller.setVideoTrack(nil)
                XCTAssertTrue(try Self.renderer(in: view) === clearedRenderer)
                try Self.assertOpaqueBlackCover(view)

                controller.setConnectionState(.connected)
                controller.setCaptureStatus(.sharing)
                controller.resume()
                XCTAssertTrue(controller.isMuted)
                try Self.assertOpaqueBlackCover(view)
            }
        }
    }

    func testClosingAndReopeningCannotClearBlackoutOrUserMute() async throws {
        try await MainActor.run {
            try Self.requireMetal()
            let controller = PresentationController()
            controller.showWindow()
            defer { controller.close() }
            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            controller.setExternalVideoFrame(try Self.frame())
            XCTAssertFalse(controller.isMuted)

            controller.setUserMuted(true)
            controller.close()
            controller.showWindow()
            controller.setExternalVideoFrame(try Self.frame())
            XCTAssertTrue(controller.isBlackedOut)
            XCTAssertTrue(controller.isMuted)
            try Self.assertOpaqueBlackCover(try Self.presentationView())

            controller.resume()
            XCTAssertFalse(controller.isBlackedOut)
            XCTAssertTrue(controller.isMuted)
            controller.setUserMuted(false)
            XCTAssertFalse(controller.isMuted)
        }
    }

    func testRotationPreservesTheWholePictureAndCentersBlackMargins() async throws {
        try await MainActor.run {
            try Self.requireMetal()
            let controller = PresentationController()
            controller.showWindow()
            defer { controller.close() }
            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            let view = try Self.presentationView()

            for rotation in [RTCVideoRotation._0, ._90, ._180, ._270, ._0] {
                controller.setExternalVideoFrame(try Self.frame(rotation: rotation))
                let renderer = try Self.renderer(in: view)
                let expectedAspect: CGFloat = rotation.rawValue % 180 == 0 ? 0.5 : 2
                XCTAssertEqual(renderer.frame.width / renderer.frame.height, expectedAspect, accuracy: 0.001)
                XCTAssertEqual(renderer.frame.midX, view.bounds.midX, accuracy: 0.001)
                XCTAssertEqual(renderer.frame.midY, view.bounds.midY, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(renderer.frame.minX, view.bounds.minX - 0.001)
                XCTAssertGreaterThanOrEqual(renderer.frame.minY, view.bounds.minY - 0.001)
                XCTAssertLessThanOrEqual(renderer.frame.maxX, view.bounds.maxX + 0.001)
                XCTAssertLessThanOrEqual(renderer.frame.maxY, view.bounds.maxY + 0.001)
                XCTAssertFalse(controller.isMuted)
                XCTAssertTrue(try Self.cover(in: view).isHidden)
            }

            controller.setConnectionState(.connected)
            controller.setCaptureStatus(.sharing)
            XCTAssertFalse(controller.isMuted, "Unchanged capture and transport states must preserve a static picture.")
        }
    }

    @MainActor
    private static func requireMetal() throws {
        _ = NSApplication.shared
        guard RTCMTLNSVideoView.isMetalAvailable() else {
            throw XCTSkip("Synthetic presentation-frame tests require a Metal renderer, without HDMI or capture hardware.")
        }
    }

    @MainActor
    private static func presentationView() throws -> PresentationView {
        let window = try XCTUnwrap(NSApp.windows.last { $0.isVisible && $0.title == "scrnshr Presentation" })
        return try XCTUnwrap(window.contentView as? PresentationView)
    }

    @MainActor
    private static func renderer(in view: PresentationView) throws -> RTCMTLNSVideoView {
        try XCTUnwrap(view.subviews.compactMap { $0 as? RTCMTLNSVideoView }.first)
    }

    @MainActor
    private static func cover(in view: PresentationView) throws -> NSView {
        try XCTUnwrap(view.subviews.last { !($0 is RTCMTLNSVideoView) })
    }

    @MainActor
    private static func assertOpaqueBlackCover(_ view: PresentationView, file: StaticString = #filePath, line: UInt = #line) throws {
        let cover = try cover(in: view)
        XCTAssertFalse(cover.isHidden, file: file, line: line)
        XCTAssertTrue(cover.isOpaque, file: file, line: line)
        XCTAssertEqual(cover.frame, view.bounds, file: file, line: line)
        XCTAssertEqual(cover.layer?.opacity, 1, file: file, line: line)
        let cgColor = try XCTUnwrap(cover.layer?.backgroundColor)
        let color = try XCTUnwrap(NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, file: file, line: line)
        XCTAssertTrue(try renderer(in: view).isHidden, file: file, line: line)
    }

    private static func frame(rotation: RTCVideoRotation = ._0) throws -> RTCVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 16, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let bytes = CVPixelBufferGetBaseAddress(buffer) {
            bytes.initializeMemory(as: UInt8.self, repeating: 0, count: CVPixelBufferGetBytesPerRow(buffer) * 32)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: rotation, timeStampNs: 1_000_000)
    }
}
