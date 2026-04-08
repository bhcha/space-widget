import Foundation

struct ShortcutBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var enabled: Bool

    var displayString: String {
        var parts: [String] = []
        if modifiers & 0x0100 != 0 { parts.append("⌘") }
        if modifiers & 0x0800 != 0 { parts.append("⌥") }
        if modifiers & 0x1000 != 0 { parts.append("⌃") }
        if modifiers & 0x0200 != 0 { parts.append("⇧") }
        parts.append(keyCodeName)
        return parts.joined()
    }

    private var keyCodeName: String {
        switch keyCode {
        case 0x24: return "↩"
        case 0x7B: return "←"
        case 0x7C: return "→"
        case 0x7E: return "↑"
        case 0x7D: return "↓"
        case 0x30: return "⇥"
        case 0x31: return "Space"
        case 0x33: return "⌫"
        case 0x35: return "⎋"
        default:
            let keyMap: [UInt32: String] = [
                0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E",
                0x03: "F", 0x05: "G", 0x04: "H", 0x22: "I", 0x26: "J",
                0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O",
                0x23: "P", 0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T",
                0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X", 0x10: "Y",
                0x06: "Z",
                0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5",
                0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0",
            ]
            return keyMap[keyCode] ?? "?"
        }
    }
}
