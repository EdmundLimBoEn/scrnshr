// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import AppKit
import CoreImage
import SwiftUI

@main
struct ScrnshrMacApp: App {
    @StateObject private var session = SessionCoordinator(role: .receiver)
    @StateObject private var usb = USBScreenSource()

    var body: some Scene {
        WindowGroup("scrnshr controls") {
            MacControls(session: session, presentation: session.presentation, usb: usb)
                .frame(minWidth: 520, minHeight: 600)
        }
        .commands {
            CommandMenu("Presentation") {
                Button("Show phone window") { session.presentation.showWindow() }
                Button("Fullscreen phone window") { session.presentation.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
                Divider()
                Button("Blackout and mute") { session.presentation.blackout() }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Resume picture") { session.presentation.resume() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Stop sharing") { usb.stop(); Task { await session.stop() } }
                    .keyboardShortcut(".", modifiers: [.command])
            }
        }
    }
}

private struct MacControls: View {
    @ObservedObject var session: SessionCoordinator
    @ObservedObject var presentation: PresentationController
    @ObservedObject var usb: USBScreenSource
    @State private var selectedUSB = ""
    @State private var diagnostics = ""
    @State private var usbAudio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("scrnshr").font(.largeTitle.bold())
                Text(session.status).font(.headline).accessibilityIdentifier("session-status")
                Picker("Connection", selection: $session.mode) {
                    ForEach(SessionCoordinator.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(session.hasSession || session.isBusy)
                if session.mode == .internet {
                    GroupBox("Internet pairing") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("HTTPS signaling server", text: $session.serverAddress)
                            SecureField("Owner credential", text: $session.ownerToken)
                            Toggle("Use relay only for connectivity testing", isOn: $session.relayOnly)
                                .disabled(!session.pairingURL.isEmpty)
                            HStack {
                                Button("Create session") { usb.stop(); Task { await session.createInternetSession() } }
                                    .buttonStyle(.borderedProminent).disabled(session.isBusy)
                                if session.canRestore {
                                    Button("Reconnect saved session") { usb.stop(); Task { await session.restoreSession() } }
                                        .disabled(session.isBusy)
                                }
                            }
                            if let qr = qrImage {
                                HStack(alignment: .top, spacing: 16) {
                                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                                        .frame(width: 210, height: 210).background(.white)
                                        .accessibilityLabel("Phone pairing QR code")
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Scan this code in scrnshr on the iPhone, then approve the phone here.")
                                        Text("The code expires after five minutes.").foregroundStyle(.secondary)
                                        Button("Copy pairing link") { copyPairingLink() }
                                    }
                                }
                            }
                            if session.approvalRequired {
                                HStack {
                                    Text("An iPhone requests this session.")
                                    Button("Approve phone") { session.approvePhone(true) }.buttonStyle(.borderedProminent)
                                    Button("Reject", role: .destructive) { session.approvePhone(false) }
                                }
                            }
                            if session.connectivity == "local-only" {
                                Text("This server has no TURN relay. Internet connectivity is unavailable.").foregroundStyle(.red)
                            }
                        }.padding(6)
                    }
                } else {
                    Button("New direct LAN session") { usb.stop(); Task { await session.startDirectSession() } }
                        .disabled(session.isBusy)
                    ManualSignalingView(session: session)
                }
                GroupBox("Presentation") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Move the phone window to the HDMI display and enter fullscreen. Select sound output in macOS Sound settings.")
                            .foregroundStyle(.secondary)
                        Text(presentation.statusText)
                        HStack {
                            Button("Show phone window") { presentation.showWindow() }
                            Button("Fullscreen") { presentation.toggleFullScreen() }
                        }
                        HStack {
                            Button("Blackout and mute") { presentation.blackout() }
                            Button("Resume") { presentation.resume() }.disabled(!presentation.isBlackedOut)
                            Button(presentation.isMuted ? "Unmute app sound" : "Mute app sound") {
                                presentation.setUserMuted(!presentation.isMuted)
                            }
                            Button("Stop", role: .destructive) { usb.stop(); Task { await session.stop() } }
                        }
                    }.padding(6)
                }
                DisclosureGroup("USB phone capture, experimental") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(usb.statusText).foregroundStyle(.secondary)
                        HStack {
                            Button("Refresh phones") { Task { await usb.refreshDevices() } }
                            Picker("Phone", selection: $selectedUSB) {
                                Text("Choose a phone").tag("")
                                ForEach(usb.devices) { Text($0.name).tag($0.id) }
                            }
                        }
                        Toggle("Enable experimental USB audio", isOn: $usbAudio).disabled(usb.isRunning)
                        HStack {
                            Button("Start USB capture") {
                                usb.scheduleStart(deviceID: selectedUSB, includeAudio: usbAudio,
                                                  stopSession: { await session.stop() },
                                                  showPresentation: { presentation.showWindow() })
                            }.disabled(selectedUSB.isEmpty || usb.isRunning)
                            Button("Stop USB") { usb.stop() }.disabled(!usb.isRunning)
                        }
                    }.padding(.top, 10)
                }
                DisclosureGroup("Connection diagnostics") {
                    VStack(alignment: .leading) {
                        Button("Refresh statistics") { Task { diagnostics = await session.media.statisticsSummary() } }
                        Text(diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.padding(.top, 10)
                }
                if let error = session.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("session-error")
                    Button("Dismiss message") { session.error = nil }
                }
            }.padding(24)
        }
        .onAppear {
            presentation.onMuteChanged = { muted in
                session.media.setRemoteAudioMuted(muted)
                usb.setMuted(muted)
            }
            usb.setMuted(presentation.isMuted)
            usb.onVideoFrame = { frame in presentation.setExternalVideoFrame(frame) }
            usb.onRunningChanged = { running in
                presentation.setConnectionState(running ? .connected : .closed)
                presentation.setCaptureStatus(running ? .sharing : .stopped)
            }
        }
        .onChange(of: usb.devices) { _, devices in
            if !devices.contains(where: { $0.id == selectedUSB }) { selectedUSB = devices.first?.id ?? "" }
        }
    }

    private var qrImage: NSImage? {
        guard !session.pairingURL.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(session.pairingURL.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 8, y: 8)))
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func copyPairingLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.pairingURL, forType: .string)
    }
}
