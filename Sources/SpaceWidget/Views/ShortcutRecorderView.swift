import SwiftUI
import AppKit

struct ShortcutRecorderView: View {
    @Binding var binding: ShortcutBinding
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: { toggleRecording() }) {
            Text(isRecording ? "Press shortcut..." : binding.displayString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(isRecording ? .accentColor : .primary)
                .frame(width: 130, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isRecording ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isRecording ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode

            // Escape cancels recording
            if keyCode == 0x35 {
                stopRecording()
                return nil
            }

            // Convert NSEvent modifiers to Carbon modifiers
            var carbonMods: UInt32 = 0
            if event.modifierFlags.contains(.command) { carbonMods |= 0x0100 }
            if event.modifierFlags.contains(.option) { carbonMods |= 0x0800 }
            if event.modifierFlags.contains(.control) { carbonMods |= 0x1000 }
            if event.modifierFlags.contains(.shift) { carbonMods |= 0x0200 }

            // Require at least one modifier
            guard carbonMods != 0 else { return nil }

            binding = ShortcutBinding(
                keyCode: UInt32(keyCode),
                modifiers: carbonMods,
                enabled: binding.enabled
            )
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
