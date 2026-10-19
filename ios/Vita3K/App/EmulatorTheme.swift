import SwiftUI
import UIKit

enum EmulatorTheme {
    static let lightModePreference = "interface.lightMode"

    static let background = adaptive(light: 0xFFF6EC, dark: 0x140D07)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x1F150D)
    static let artworkBackground = adaptive(light: 0xFFE6C7, dark: 0x5A3A1E)
    // Logo orange, with a deeper shade for readable controls on light surfaces.
    static let accent = adaptive(light: 0xB84A00, dark: 0xFF8A1F)
    // Red, so warnings stay distinct from the orange accent.
    static let warning = adaptive(light: 0xB3261E, dark: 0xFF6B61)
    static let debug = adaptive(light: 0x805500, dark: 0xFFD60A)
    static let performance = adaptive(light: 0x006B80, dark: 0x64D2FF)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        })
    }
}

struct EmulatorCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct JITBadge: View {
    let status: CoreController.JITStatus
    var body: some View {
        Label(LocalizedStringKey(status.rawValue), systemImage: status == .ready ? "bolt.fill" : status == .checking ? "clock" : "bolt.slash.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(status == .ready ? EmulatorTheme.accent : status == .checking ? Color.secondary : EmulatorTheme.warning)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.primary.opacity(0.06), in: Capsule())
            .accessibilityIdentifier("jit-status")
    }
}

struct LoggingModeBanner: View {
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
        case .debug: EmulatorTheme.debug
        case .compat: EmulatorTheme.warning
        case .performance: EmulatorTheme.performance
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
        .background(EmulatorTheme.background)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(Text(LocalizedStringKey(label))) ativo"))
        .accessibilityIdentifier("logging-mode")
        .accessibilityValue(mode.rawValue)
    }
}

struct GameArtwork: View {
    let titleID: String
    @State private var artwork: UIImage?
    var body: some View {
        ZStack {
            LinearGradient(colors: [EmulatorTheme.artworkBackground, EmulatorTheme.panel],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let artwork {
                Image(uiImage: artwork).resizable().scaledToFit()
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 44, weight: .light)).foregroundStyle(EmulatorTheme.accent.opacity(0.7))
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
