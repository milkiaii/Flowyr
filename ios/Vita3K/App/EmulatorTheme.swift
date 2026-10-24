import SwiftUI
import UIKit

struct ArtColors: Sendable {
    let bg0: Color, bg1: Color, ink: Color, soft: Color
}

struct Palette: Sendable {
    let background: Color
    let panel: Color
    let artworkBackground: Color
    let accent: Color
    let warning: Color
    let debug: Color
    let performance: Color
    let scheme: ColorScheme
    var art: ArtColors? = nil
}

enum AppTheme: String, CaseIterable, Sendable {
    case dark, light, pink, miku

    var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    var label: String {
        switch self {
        case .dark: "Escuro"
        case .light: "Claro"
        case .pink: "Rosa"
        case .miku: "Miku"
        }
    }

    var palette: Palette {
        switch self {
        case .dark:
            Palette(background: Color(hex: 0x000000), panel: Color(hex: 0x1C1C1E), artworkBackground: Color(hex: 0x2C2C2E),
                    accent: Color(hex: 0xAEAEB2), warning: Color(hex: 0xFF6B61), debug: Color(hex: 0xFFD60A),
                    performance: Color(hex: 0x64D2FF), scheme: .dark)
        case .light:
            Palette(background: Color(hex: 0xFFFFFF), panel: Color(hex: 0xF2F2F4), artworkBackground: Color(hex: 0xE3E3E8),
                    accent: Color(hex: 0x48484A), warning: Color(hex: 0xB3261E), debug: Color(hex: 0x805500),
                    performance: Color(hex: 0x006B80), scheme: .light)
        case .pink:
            Palette(background: Color(hex: 0xFDDCE9), panel: Color(hex: 0xFFF4F8, alpha: 0.82), artworkBackground: Color(hex: 0xF8C4DA),
                    accent: Color(hex: 0xC93F7A), warning: Color(hex: 0xB3261E), debug: Color(hex: 0x805500),
                    performance: Color(hex: 0x8A3FA8), scheme: .light,
                    art: ArtColors(bg0: Color(hex: 0xFDDCE9), bg1: Color(hex: 0xF8C4DA), ink: Color(hex: 0xDE6C98), soft: Color(hex: 0xF4A3C2)))
        case .miku:
            Palette(background: Color(hex: 0xDDF7F6), panel: Color(hex: 0xF3FFFE, alpha: 0.82), artworkBackground: Color(hex: 0xBFEBEB),
                    accent: Color(hex: 0x1B8F92), warning: Color(hex: 0xB3261E), debug: Color(hex: 0x805500),
                    performance: Color(hex: 0x1F6FA8), scheme: .light,
                    art: ArtColors(bg0: Color(hex: 0xDDF7F6), bg1: Color(hex: 0xBFEBEB), ink: Color(hex: 0x3DB5B7), soft: Color(hex: 0x86D8D8)))
        }
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = AppTheme.dark.palette
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

enum EmulatorTheme {
    static let lightModePreference = "interface.lightMode"
    static let themePreference = "interface.theme"
}

struct AppThemeModifier: ViewModifier {
    @AppStorage(EmulatorTheme.themePreference) private var raw = ""
    @AppStorage(EmulatorTheme.lightModePreference) private var legacyLight = false
    private var theme: AppTheme { AppTheme(rawValue: raw) ?? (legacyLight ? .light : .dark) }
    func body(content: Content) -> some View {
        let p = theme.palette
        content
            .environment(\.palette, p)
            .tint(p.accent)
            .preferredColorScheme(p.scheme)
    }
}

extension View {
    func appTheme() -> some View { modifier(AppThemeModifier()) }
}

struct EmulatorCard<Content: View>: View {
    @Environment(\.palette) private var palette
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct JITBadge: View {
    @Environment(\.palette) private var palette
    let status: CoreController.JITStatus
    var body: some View {
        Label(LocalizedStringKey(status.rawValue), systemImage: status == .ready ? "bolt.fill" : status == .checking ? "clock" : "bolt.slash.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .ready ? palette.accent : status == .checking ? Color.secondary : palette.warning)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: Capsule())
            .accessibilityIdentifier("jit-status")
    }
}

struct LoggingModeBanner: View {
    @Environment(\.palette) private var palette
    let mode: Vita3KCore.LoggingMode

    private var label: String {
        switch mode {
        case .off: ""
        case .debug: "Modo Debug"
        case .compat: "Modo Compat Fix"
        case .performance: "Modo Performance Fix"
        case .graphics: "Modo Graphics Fix"
        }
    }

    private var symbol: String {
        switch mode {
        case .off: ""
        case .debug: "ladybug.fill"
        case .compat: "wrench.and.screwdriver.fill"
        case .performance: "speedometer"
        case .graphics: "sparkles.tv"
        }
    }

    private var tint: Color {
        switch mode {
        case .off: .secondary
        case .debug: palette.debug
        case .compat: palette.warning
        case .performance: palette.performance
        case .graphics: .purple
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Label(LocalizedStringKey(label), systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text("Ativo").font(.caption.weight(.medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 20).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: Rectangle())
        .background(palette.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(LocalizedStringKey(label))) ativo"))
        .accessibilityIdentifier("logging-mode")
        .accessibilityValue(mode.rawValue)
    }
}

struct GameArtwork: View {
    @Environment(\.palette) private var palette
    let titleID: String
    @State private var artwork: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [palette.artworkBackground, palette.panel],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(palette.accent.opacity(0.7))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityHidden(true)
        .task(id: titleID) {
            let path = URL.documentsDirectory.appendingPathComponent("vita/ux0/app")
                .appendingPathComponent(titleID).appendingPathComponent("sce_sys/icon0.png").path
            artwork = UIImage(contentsOfFile: path)
        }
    }
}
