import CoreText
import SwiftUI

/// The editor's design tokens from `web/editor.html`.
enum Theme {
    static let bgPrimary = Color(hex: 0x1A1A1E)
    static let bgSecondary = Color(hex: 0x222226)
    static let bgTertiary = Color(hex: 0x2A2A2F)
    static let bgElevated = Color(hex: 0x303036)
    static let bgSlide = Color(hex: 0x111114)
    static let borderSubtle = Color(hex: 0x3A3A40)
    static let borderMuted = Color(hex: 0x2E2E34)
    static let borderHover = Color(hex: 0x4A4A50)
    static let textPrimary = Color(hex: 0xE8E8EC)
    static let textSecondary = Color(hex: 0xA0A0A8)
    static let textMuted = Color(hex: 0x6A6A72)
    static let green = Color(hex: 0x4CAF50)
    static let greenHover = Color(hex: 0x5CBF60)
    static let greenDim = Color(hex: 0x3D8B40)
    static let greenGlow = Color(hex: 0x4CAF50).opacity(0.15)
    static let blue = Color(hex: 0x5B9BD5)
    static let red = Color(hex: 0xE05555)
    static let orange = Color(hex: 0xE09040)

    static let radiusSmall: CGFloat = 4
    static let radiusMedium: CGFloat = 8
    static let radiusLarge: CGFloat = 12

    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let name = switch weight {
        case .medium: "JetBrainsMono-Medium"
        case .semibold, .bold: "JetBrainsMono-SemiBold"
        default: "JetBrainsMono-Regular"
        }
        return .custom(name, size: size)
    }

    /// Registers the bundled JetBrains Mono so `mono` resolves on Macs without it installed.
    static func registerFonts() {
        for name in ["JetBrainsMono-Regular", "JetBrainsMono-Medium", "JetBrainsMono-SemiBold", "IBMPlexSans-SemiBold", "IBMPlexSans-SemiBoldItalic"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Resources/Fonts") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// "Slides to Video" set like the README wordmark: IBM Plex Sans SemiBold, "to" in green italic.
struct Wordmark: View {
    var size: CGFloat = 15

    var body: some View {
        (Text("Slides ") + Text("to").font(.custom("IBMPlexSans-SemiBoldItalic", size: size)).foregroundColor(Theme.green) + Text(" Video"))
            .font(.custom("IBMPlexSans-SemiBold", size: size))
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Uppercase section label: 11 to 12 px, semibold, muted, letter-spaced.
struct SectionLabel: View {
    let text: String
    var size: CGFloat = 11

    init(_ text: String, size: CGFloat = 11) {
        self.text = text
        self.size = size
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.ui(size, .semibold))
            .tracking(size * 0.06)
            .foregroundStyle(Theme.textMuted)
    }
}

struct EditorButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, ghost, generateAll, light }

    let kind: Kind
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, compact: compact, isEnabled: isEnabled)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let compact: Bool
        let isEnabled: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.ui(compact ? 11 : 12, .semibold))
                .labelStyle(EditorLabelStyle())
                .padding(.horizontal, kind == .ghost ? 8 : (compact ? 12 : 14))
                .padding(.vertical, compact ? 5 : 6)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall).strokeBorder(border, lineWidth: 1))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
                .animation(.easeOut(duration: 0.15), value: hovering)
        }

        private var foreground: Color {
            switch kind {
            case .primary: .white
            case .secondary, .ghost: hovering ? Theme.textPrimary : Theme.textSecondary
            case .generateAll: Theme.blue
            case .light: Theme.bgPrimary
            }
        }

        private var background: Color {
            switch kind {
            case .primary: hovering ? Theme.greenHover : Theme.green
            case .secondary: hovering ? Theme.bgElevated : Theme.bgTertiary
            case .ghost: hovering ? Theme.bgTertiary : .clear
            case .generateAll: hovering ? Theme.blue.opacity(0.1) : Theme.bgTertiary
            case .light: hovering ? Color(hex: 0xF4F4F6) : Color(hex: 0xE8E8EC)
            }
        }

        private var border: Color {
            switch kind {
            case .primary: hovering ? Theme.greenHover : Theme.green
            case .secondary: hovering ? Theme.borderHover : Theme.borderSubtle
            case .ghost: .clear
            case .generateAll: Theme.blue.opacity(hovering ? 0.5 : 0.3)
            case .light: .clear
            }
        }
    }
}

struct EditorLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 11, weight: .semibold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == EditorButtonStyle {
    static func editor(_ kind: EditorButtonStyle.Kind, compact: Bool = false) -> EditorButtonStyle {
        EditorButtonStyle(kind: kind, compact: compact)
    }
}

/// A small spinning ring like the editor's `.spinner`.
struct Spinner: View {
    var size: CGFloat = 14
    var color: Color = .primary
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.28)
            .stroke(color, style: StrokeStyle(lineWidth: size / 7, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.6).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
