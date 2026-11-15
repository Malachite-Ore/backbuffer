import SwiftUI

enum Theme {
    // MARK: - Q9=C Medal / Raycast Dark Graphite Palette

    static let background = Color(red: 13.0 / 255.0, green: 15.0 / 255.0, blue: 20.0 / 255.0)         // #0D0F14
    static let surfaceSubtle = Color(red: 17.0 / 255.0, green: 20.0 / 255.0, blue: 28.0 / 255.0)      // #11141C
    static let surfaceCard = Color(red: 21.0 / 255.0, green: 25.0 / 255.0, blue: 34.0 / 255.0)        // #151922
    static let surfaceElevated = Color(red: 28.0 / 255.0, green: 34.0 / 255.0, blue: 48.0 / 255.0)    // #1C2230
    static let surfaceHover = Color(red: 35.0 / 255.0, green: 42.0 / 255.0, blue: 59.0 / 255.0)       // #232A3B

    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.16)

    // MARK: - Accents & Semantic Status

    static let amber = Color(red: 245.0 / 255.0, green: 166.0 / 255.0, blue: 35.0 / 255.0)            // #F5A623
    static let amberPressed = Color(red: 224.0 / 255.0, green: 145.0 / 255.0, blue: 20.0 / 255.0)
    static let amberInk = Color(red: 20.0 / 255.0, green: 14.0 / 255.0, blue: 4.0 / 255.0)
    static let amberSoft = amber.opacity(0.16)

    static let emerald = Color(red: 46.0 / 255.0, green: 204.0 / 255.0, blue: 113.0 / 255.0)         // #2ECC71
    static let emeraldSoft = emerald.opacity(0.15)

    static let crimson = Color(red: 229.0 / 255.0, green: 72.0 / 255.0, blue: 77.0 / 255.0)           // #E5484D
    static let crimsonSoft = crimson.opacity(0.16)

    // MARK: - Typography Colors

    static let textPrimary = Color(red: 244.0 / 255.0, green: 246.0 / 255.0, blue: 250.0 / 255.0)     // #F4F6FA
    static let textSecondary = Color(red: 156.0 / 255.0, green: 165.0 / 255.0, blue: 182.0 / 255.0)   // #9CA5B6
    static let textMuted = Color(red: 108.0 / 255.0, green: 118.0 / 255.0, blue: 138.0 / 255.0)       // #6C768A

    // MARK: - Typography Helpers

    static func tabular(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.system(size: size, weight: weight).monospacedDigit()
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        Font.system(size: size, weight: weight, design: .monospaced).monospacedDigit()
    }

    // MARK: - Formatting

    static func formatMB(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000.0
        return String(format: "%.1f MB", mb)
    }

    static func formatMB(_ mb: Double) -> String {
        String(format: "%.1f MB", mb)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped.rounded())
        let mins = whole / 60
        let secs = whole % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    static func formatPreciseTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped - Double(mins * 60)
        return String(format: "%02d:%04.1f", mins, secs)
    }
}

// MARK: - View Modifiers

struct GraphiteCardModifier: ViewModifier {
    var background: Color = Theme.surfaceCard
    var cornerRadius: CGFloat = 10
    var borderColor: Color = Theme.border
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
    }
}

extension View {
    func graphiteCard(
        background: Color = Theme.surfaceCard,
        cornerRadius: CGFloat = 10,
        borderColor: Color = Theme.border,
        borderWidth: CGFloat = 1
    ) -> some View {
        modifier(
            GraphiteCardModifier(
                background: background,
                cornerRadius: cornerRadius,
                borderColor: borderColor,
                borderWidth: borderWidth
            )
        )
    }
}

// MARK: - Reusable Badges & Buttons

struct StatusPill: View {
    enum Tone {
        case neutral
        case amber
        case emerald
        case crimson

        var foreground: Color {
            switch self {
            case .neutral: return Theme.textSecondary
            case .amber: return Theme.amber
            case .emerald: return Theme.emerald
            case .crimson: return Theme.crimson
            }
        }

        var background: Color {
            switch self {
            case .neutral: return Theme.surfaceElevated
            case .amber: return Theme.amberSoft
            case .emerald: return Theme.emeraldSoft
            case .crimson: return Theme.crimsonSoft
            }
        }

        var border: Color {
            switch self {
            case .neutral: return Theme.border
            case .amber: return Theme.amber.opacity(0.35)
            case .emerald: return Theme.emerald.opacity(0.35)
            case .crimson: return Theme.crimson.opacity(0.4)
            }
        }
    }

    let text: String
    var icon: String? = nil
    var tone: Tone = .neutral
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: fontSize - 1, weight: .semibold))
            }
            Text(text)
                .font(Theme.mono(fontSize, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(tone.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tone.background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tone.border, lineWidth: 1)
        )
    }
}

struct AmberCTAButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 12.5, weight: .semibold))
            .foregroundColor(Theme.amberInk)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.amberPressed : Theme.amber)
            )
            .opacity(configuration.isPressed ? 0.94 : 1.0)
    }
}

struct GraphiteSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false
    var isDestructive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 12.5, weight: .medium))
            .foregroundColor(isDestructive ? Theme.crimson : Theme.textPrimary)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.surfaceHover : Theme.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isDestructive ? Theme.crimson.opacity(0.35) : Theme.borderStrong,
                        lineWidth: 1
                    )
            )
    }
}

struct PillChoiceButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.tabular(12, weight: isSelected ? .semibold : .medium))
            .foregroundColor(isSelected ? Theme.amberInk : Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isSelected
                            ? (configuration.isPressed ? Theme.amberPressed : Theme.amber)
                            : (configuration.isPressed ? Theme.surfaceHover : Theme.surfaceElevated)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? Theme.amber : Theme.border,
                        lineWidth: 1
                    )
            )
    }
}
