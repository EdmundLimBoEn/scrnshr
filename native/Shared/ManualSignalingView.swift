// Written by gpt-6.1-sol in T3 Code through the Codex harness on behalf of Edmund.
import SwiftUI

struct ManualSignalingView: View {
    @ObservedObject var session: SessionCoordinator
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy the phone's offer to the Mac, then the Mac's answer to the phone. Copy again if more connection candidates arrive.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Outgoing connection bundle").font(.headline)
            TextEditor(text: .constant(session.manualOutput))
                .font(.system(.caption, design: .monospaced)).frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            HStack {
                Button("Copy bundle") { copy(session.manualOutput) }.disabled(session.manualOutput.isEmpty)
                if !session.manualOutput.isEmpty {
                    ShareLink(item: session.manualOutput) { Label("Share bundle", systemImage: "square.and.arrow.up") }
                }
            }
            Text("Incoming connection bundle").font(.headline)
            TextEditor(text: $input)
                .font(.system(.caption, design: .monospaced)).frame(minHeight: 90, maxHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            Button("Import bundle") { session.importManualSignals(input) }.disabled(input.isEmpty)
        }
    }

    private func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}
