// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import SwiftUI

@main
struct ScrnshrPhoneApp: App {
    @StateObject private var session = SessionCoordinator(role: .sender)

    var body: some Scene {
        WindowGroup { PhoneControls(session: session) }
    }
}

private struct PhoneControls: View {
    @ObservedObject var session: SessionCoordinator
    @State private var joinCode = ""
    @State private var scanning = false
    @State private var scannedCode: String?
    @State private var pendingCode: String?
    @State private var pairingHost = ""
    @State private var showingCalibration = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(session.status).font(.headline).accessibilityIdentifier("session-status")
                    Text("Share this iPhone's screen and app sounds. Use the phone to control your demo.")
                        .foregroundStyle(.secondary)
                    Picker("Connection", selection: $session.mode) {
                        ForEach(SessionCoordinator.Mode.allCases, id: \.self) { mode in Text(mode.rawValue).tag(mode) }
                    }.pickerStyle(.segmented).disabled(session.hasSession || session.isBusy)
                    if session.mode == .internet {
                        Button("Scan Mac code") { scannedCode = nil; scanning = true }
                            .buttonStyle(.borderedProminent)
                        TextField("Paste a scrnshr pairing link", text: $joinCode, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Join session") { confirmPairing(joinCode) }.disabled(joinCode.isEmpty)
                        if session.canRestore {
                            Button("Reconnect saved session") { Task { await session.restoreSession() } }
                        }
                        Toggle("Use relay only", isOn: $session.relayOnly).disabled(session.approved)
                        if session.approved { Text("Approved by the Mac").foregroundStyle(.green) }
                    } else {
                        Button("New direct session") { Task { await session.startDirectSession() } }
                        ManualSignalingView(session: session)
                    }
                    HStack {
                        Button("Share screen") { session.startSharing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(session.isSharing || (session.mode == .internet && !session.approved))
                        Button("Stop", role: .destructive) { Task { await session.stop() } }
                    }
                    Button("Show calibration screen") { showingCalibration = true }
                    if let error = session.error {
                        Text(error).font(.callout).foregroundStyle(.red).accessibilityIdentifier("session-error")
                        Button("Dismiss message") { session.error = nil }
                    }
                }.padding()
            }
            .navigationTitle("scrnshr")
            .sheet(isPresented: $scanning, onDismiss: {
                if let value = scannedCode {
                    scannedCode = nil
                    confirmPairing(value)
                }
            }) {
                NavigationStack {
                    QRCodeScanner(onCode: { value in
                        guard scanning else { return }
                        scannedCode = value
                        scanning = false
                    }, onError: { session.error = $0 })
                        .navigationTitle("Scan Mac code")
                        .toolbar { Button("Cancel") { scannedCode = nil; scanning = false } }
                }
            }
            .fullScreenCover(isPresented: $showingCalibration) {
                CalibrationView { showingCalibration = false }
            }
            .confirmationDialog("Connect to \(pairingHost)?", isPresented: Binding(
                get: { pendingCode != nil }, set: { if !$0 { pendingCode = nil } }
            ), titleVisibility: .visible) {
                Button("Join") {
                    if let pendingCode { Task { await session.joinInternetSession(pendingCode) } }
                    pendingCode = nil
                }
                Button("Cancel", role: .cancel) { pendingCode = nil }
            } message: {
                Text("The Mac must approve this phone before you can share.")
            }
            .onOpenURL { confirmPairing($0.absoluteString) }
        }
    }

    private func confirmPairing(_ value: String) {
        do {
            let code = try PairingCode.parse(value)
            pairingHost = code.server.host ?? "your server"
            pendingCode = value
        } catch { session.error = error.localizedDescription }
    }
}

private struct CalibrationView: View {
    let dismiss: () -> Void
    @State private var inverted = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                (inverted ? Color.white : Color.black).ignoresSafeArea()
                VStack {
                    HStack { corner("TOP LEFT", .red); Spacer(); corner("TOP RIGHT", .green) }
                    Spacer()
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                        VStack(spacing: 12) {
                            Text("Full phone picture").font(.title)
                            Text(String(format: "%.3f", context.date.timeIntervalSince1970))
                                .font(.system(.title3, design: .monospaced))
                            Text("Small text: abcdefghijklmnopqrstuvwxyz 0123456789").font(.caption2)
                            Text("\(Int(geometry.size.width)) × \(Int(geometry.size.height)) points").font(.caption)
                        }.foregroundStyle(inverted ? Color.black : Color.white)
                    }
                    Button("Flash") { inverted.toggle() }.buttonStyle(.bordered)
                    Button("Back to controls", action: dismiss).buttonStyle(.bordered)
                    Spacer()
                    HStack { corner("BOTTOM LEFT", .blue); Spacer(); corner("BOTTOM RIGHT", .yellow) }
                }.padding(8)
            }.overlay(Rectangle().stroke(.red, lineWidth: 3))
        }
    }

    private func corner(_ label: String, _ color: Color) -> some View {
        Text(label).font(.caption2.bold()).padding(6).foregroundStyle(.black).background(color)
    }
}
