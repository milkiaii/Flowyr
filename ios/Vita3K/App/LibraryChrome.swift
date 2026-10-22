// Vita3K iOS shell app
// Library chrome: top bar (logo + device status), floating bottom bar,
// game cover loading and the landscape cover carousel.

import Network
import SwiftUI
import UIKit

// MARK: - Device status (time / network / battery)

@MainActor
final class DeviceStatus: ObservableObject {
    enum Link { case wifi, cellular, other, offline }

    static let shared = DeviceStatus()

    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var link: Link = .other

    private let monitor = NWPathMonitor()

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBattery()
        let center = NotificationCenter.default
        for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshBattery() }
            }
        }
        monitor.pathUpdateHandler = { [weak self] path in
            let link: Link
            if path.status != .satisfied { link = .offline }
            else if path.usesInterfaceType(.wifi) { link = .wifi }
            else if path.usesInterfaceType(.cellular) { link = .cellular }
            else { link = .other }
            Task { @MainActor in self?.link = link }
        }
        monitor.start(queue: DispatchQueue(label: "veeb.network-monitor"))
    }

    private func refreshBattery() {
        batteryLevel = UIDevice.current.batteryLevel
        batteryState = UIDevice.current.batteryState
    }

    var isCharging: Bool { batteryState == .charging || batteryState == .full }
    var batteryPercent: Int? { batteryLevel < 0 ? nil : Int((batteryLevel * 100).rounded()) }

    var batterySymbol: String {
        guard let percent = batteryPercent else { return "battery.100" }
        switch percent {
        case 88...: return "battery.100"
        case 63..<88: return "battery.75"
        case 38..<63: return "battery.50"
        case 13..<38: return "battery.25"
        default: return "battery.0"
        }
    }

    var linkSymbol: String {
        switch link {
        case .wifi, .other: "wifi"
        case .cellular: "antenna.radiowaves.left.and.right"
        case .offline: "wifi.slash"
        }
    }
}

// MARK: - Top bar

private extension View {
    func chromePill() -> some View {
        self
            .background(EmulatorTheme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
    }
}

struct LibraryTopBar: View {
    @ObservedObject var status: DeviceStatus
    let jitStatus: CoreController.JITStatus
    let onJITTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            brand
            Spacer(minLength: 6)
            info
        }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Image("LogoMark")
                .resizable().scaledToFit()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(verbatim: "VEEB-SE")
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .tracking(1.4)
                .lineLimit(1)
        }
        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 7)
        .chromePill()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Veeb-SE"))
    }

    private var info: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                statusGroup(showDate: true)
                statusGroup(showDate: false)
            }
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20)
            Button(action: onJITTap) {
                Image(systemName: jitSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(jitColor)
                    .frame(width: 40, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(jitStatus == .checking)
            .accessibilityLabel(Text(LocalizedStringKey(jitStatus.rawValue)))
            .accessibilityIdentifier("jit-status")
        }
        .chromePill()
    }

    private func statusGroup(showDate: Bool) -> some View {
        HStack(spacing: 8) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: timeStyle(showDate: showDate))
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    .lineLimit(1).fixedSize()
            }
            Image(systemName: status.linkSymbol).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 2) {
                Image(systemName: status.batterySymbol)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(batteryColor)
                if status.isCharging {
                    Image(systemName: "bolt.fill").font(.system(size: 9, weight: .bold))
                }
            }
        }
        .padding(.horizontal, 12).frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    private func timeStyle(showDate: Bool) -> Date.FormatStyle {
        showDate
            ? Date.FormatStyle().day().month(.twoDigits).year(.twoDigits).hour().minute()
            : Date.FormatStyle().hour().minute()
    }

    private var batteryColor: Color {
        if let percent = status.batteryPercent, percent <= 20, !status.isCharging {
            return EmulatorTheme.warning
        }
        return .primary
    }

    private var jitSymbol: String {
        switch jitStatus {
        case .ready: "bolt.fill"
        case .checking: "clock"
        case .unavailable: "bolt.slash.fill"
        }
    }

    private var jitColor: Color {
        switch jitStatus {
        case .ready: .primary
        case .checking: .secondary
        case .unavailable: EmulatorTheme.warning
        }
    }
}

// MARK: - Floating bottom bar

struct LibraryFloatingBar: View {
    let layoutSymbol: String
    let layoutLabel: LocalizedStringKey
    let importDisabled: Bool
    let onLayout: () -> Void
    let onImport: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(spacing: 26) {
            barButton(layoutSymbol, action: onLayout)
                .accessibilityLabel(Text(layoutLabel))
                .accessibilityIdentifier("layout-toggle")
            barButton("plus", action: onImport)
                .disabled(importDisabled)
                .accessibilityLabel(Text("Importar"))
                .accessibilityIdentifier("import-content")
            barButton("gearshape.fill", action: onSettings)
                .accessibilityLabel(Text("Opções"))
                .accessibilityIdentifier("open-settings")
        }
        .padding(.horizontal, 22).padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
    }

    private func barButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 46, height: 46)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Game cover

/// "Wide artwork" (default) or the classic square icons.
enum GameIconStyle {
    static let preference = "library.classicIcons"
}

enum GameCoverLoader {
    nonisolated(unsafe) private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 48
        return cache
    }()

    private static let candidates = [
        "sce_sys/pic0.png",
        "sce_sys/livearea/contents/bg.png",
        "sce_sys/livearea/contents/bg0.png",
        "sce_sys/icon0.png",
    ]

    /// Artwork for the title (cached, downscaled). Classic mode uses only the
    /// square icon; otherwise the widest artwork available.
    static func load(_ titleID: String, classic: Bool = false) async -> UIImage? {
        let key = (classic ? "icon:" : "art:") + titleID
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let image: UIImage? = await Task.detached(priority: .utility) { () async -> UIImage? in
            let root = URL.documentsDirectory.appendingPathComponent("vita/ux0/app")
                .appendingPathComponent(titleID)
            for relative in (classic ? ["sce_sys/icon0.png"] : candidates) {
                let path = root.appendingPathComponent(relative).path
                guard let original = UIImage(contentsOfFile: path) else { continue }
                let longest = max(original.size.width, original.size.height)
                guard longest > 960 else { return original.preparingForDisplay() ?? original }
                let scale = 960 / longest
                let size = CGSize(width: original.size.width * scale, height: original.size.height * scale)
                return await original.byPreparingThumbnail(ofSize: size) ?? original
            }
            return nil
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

/// 16:9 cover. Wide artwork fills the frame; square icons are fitted on the
/// panel gradient instead of being cropped.
struct GameCover: View {
    let titleID: String
    var cornerRadius: CGFloat = 16
    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @State private var image: UIImage?

    private var isWide: Bool {
        guard let image else { return false }
        return !classicIcons && image.size.width / max(image.size.height, 1) > 1.3
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [EmulatorTheme.artworkBackground, EmulatorTheme.panel],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                if isWide {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(uiImage: image).resizable().scaledToFit().padding(10)
                }
            } else {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
        .aspectRatio(classicIcons ? 1 : 16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
        .task(id: "\(titleID)|\(classicIcons)") {
            image = await GameCoverLoader.load(titleID, classic: classicIcons)
        }
    }
}

// MARK: - Landscape carousel

struct GameCarousel<Menu: View>: View {
    let games: [CoreController.AppInfo]
    let initialID: String?
    /// The centered game. Shared with the library so a gamepad can move it.
    @Binding var scrolledID: String?
    let onLaunch: (String) -> Void
    @ViewBuilder let menu: (CoreController.AppInfo) -> Menu

    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    /// Local scroll position. It is committed to `scrolledID` only when the
    /// scroll settles, so the library is not re-rendered (and the scroll
    /// interrupted) on every cover that passes the center.
    @State private var position: String?

    var body: some View {
        GeometryReader { proxy in
            let width = cardWidth(in: proxy.size)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 22) {
                    ForEach(games) { game in
                        card(game, width: width).id(game.titleId)
                    }
                }
                .scrollTargetLayout()
            }
            // Inset the content (not the layout) so snapping stays measured
            // on the covers themselves.
            .safeAreaPadding(.horizontal, max(0, (proxy.size.width - width) / 2))
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position, anchor: .center)
            .scrollIndicators(.hidden)
            .sensoryFeedback(.selection, trigger: position)
            .onScrollPhaseChange { _, phase in
                if phase == .idle, let position, position != scrolledID { scrolledID = position }
            }
            // Gamepad (or anything else) moved the focus: follow it.
            .onChange(of: scrolledID) { _, new in
                guard let new, new != position else { return }
                withAnimation(.snappy) { position = new }
            }
            .onAppear {
                let start = games.contains(where: { $0.titleId == scrolledID }) ? scrolledID
                    : (games.contains(where: { $0.titleId == initialID }) ? initialID : games.first?.titleId)
                position = start
                scrolledID = start
            }
        }
    }

    private func cardWidth(in size: CGSize) -> CGFloat {
        let aspect: CGFloat = classicIcons ? 1 : 16.0 / 9.0
        let byHeight = max(140, size.height - 80) * aspect
        return max(classicIcons ? 150 : 200, min(byHeight, size.width * (classicIcons ? 0.4 : 0.56)))
    }

    private func card(_ game: CoreController.AppInfo, width: CGFloat) -> some View {
        VStack(spacing: 10) {
            GameCover(titleID: game.titleId, cornerRadius: 22)
                .frame(width: width)
            Text(game.title.isEmpty ? game.titleId : game.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(game.titleId)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(width: width)
        .visualEffect { content, proxy in
            let frame = proxy.frame(in: .scrollView(axis: .horizontal))
            let viewport = proxy.bounds(of: .scrollView(axis: .horizontal)) ?? .zero
            let stride = max(frame.width + 22, 1)
            let distance = Double(min(abs(frame.midX - viewport.midX) / stride, 1))
            return content
                .scaleEffect(CGFloat(1 - 0.14 * distance))
                .brightness(-0.25 * distance)
                .saturation(1 - 0.25 * distance)
        }
        .contentShape(.rect)
        .onTapGesture { onLaunch(game.titleId) }
        .contextMenu { menu(game) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("game-\(game.titleId)")
    }
}
