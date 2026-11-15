import Foundation

#if canImport(AppKit)
import AppKit
#endif

public struct HotKeyShortcut: Codable, Equatable, Hashable, Sendable {
    // Carbon Events.h modifier masks (HIToolbox)
    public static let carbonCmdKey: UInt32 = 0x0100
    public static let carbonShiftKey: UInt32 = 0x0200
    public static let carbonOptionKey: UInt32 = 0x0800
    public static let carbonControlKey: UInt32 = 0x1000

    public static let defaultSaveClip = HotKeyShortcut(
        keyCode: 1, // kVK_ANSI_S
        carbonModifiers: carbonOptionKey | carbonCmdKey,
        displayString: "⌥⌘S"
    )

    public let keyCode: UInt32
    public let carbonModifiers: UInt32
    public let displayString: String

    public init(
        keyCode: UInt32,
        carbonModifiers: UInt32,
        displayString: String? = nil
    ) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.displayString = displayString ?? Self.formatDisplayString(
            keyCode: keyCode,
            carbonModifiers: carbonModifiers
        )
    }

    public static func formatDisplayString(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var prefix = ""
        if (carbonModifiers & carbonControlKey) != 0 { prefix += "⌃" }
        if (carbonModifiers & carbonOptionKey) != 0 { prefix += "⌥" }
        if (carbonModifiers & carbonShiftKey) != 0 { prefix += "⇧" }
        if (carbonModifiers & carbonCmdKey) != 0 { prefix += "⌘" }
        return prefix + keyName(for: keyCode)
    }

    public static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "↩"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "⌫"
        case 53: return "⎋"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 109: return "F10"
        case 111: return "F12"
        case 118: return "F4"
        case 120: return "F2"
        case 122: return "F1"
        default: return "Key(\(keyCode))"
        }
    }

    #if canImport(AppKit)
    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= carbonCmdKey }
        if flags.contains(.option) { mask |= carbonOptionKey }
        if flags.contains(.shift) { mask |= carbonShiftKey }
        if flags.contains(.control) { mask |= carbonControlKey }
        return mask
    }

    public var nsEventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if (carbonModifiers & Self.carbonCmdKey) != 0 { flags.insert(.command) }
        if (carbonModifiers & Self.carbonOptionKey) != 0 { flags.insert(.option) }
        if (carbonModifiers & Self.carbonShiftKey) != 0 { flags.insert(.shift) }
        if (carbonModifiers & Self.carbonControlKey) != 0 { flags.insert(.control) }
        return flags
    }

    public init?(event: NSEvent) {
        let relevantFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let mods = Self.carbonModifiers(from: relevantFlags)
        // Require at least one primary modifier (Command, Option, or Control) for global safety.
        let hasPrimaryModifier = (mods & (Self.carbonCmdKey | Self.carbonOptionKey | Self.carbonControlKey)) != 0
        guard hasPrimaryModifier else { return nil }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
    }
    #endif
}
