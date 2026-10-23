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
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

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
        center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
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

    /// Fill level for the variable-value battery symbol (1 when unknown).
    var batteryFill: Double { batteryLevel < 0 ? 1 : Double(max(0, min(1, batteryLevel))) }

    /// Follows the system battery colors: green charging, yellow/orange in
    /// Low Power Mode, red when low, otherwise the normal (white/black) fill.
    var batteryFillColor: Color {
        if isCharging { return .green }
        if lowPowerMode { return .orange }
        if let percent = batteryPercent, percent <= 20 { return .red }
        return .primary
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
            BatteryIcon(level: status.batteryFill, fill: status.batteryFillColor, charging: status.isCharging)
        }
        .padding(.horizontal, 12).frame(height: 34)
        .accessibilityElement(children: .combine)
    }

    private func timeStyle(showDate: Bool) -> Date.FormatStyle {
        showDate
            ? Date.FormatStyle().day().month(.twoDigits).year(.twoDigits).hour().minute()
            : Date.FormatStyle().hour().minute()
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

// MARK: - Battery icon

/// iOS-style battery: gray outline, colored fill *inside* it sized to the
/// charge level, and a bolt over the fill while charging.
struct BatteryIcon: View {
    let level: Double
    let fill: Color
    let charging: Bool

    private let bodyWidth: CGFloat = 25
    private let bodyHeight: CGFloat = 12
    private let inset: CGFloat = 1.8

    var body: some View {
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.45), lineWidth: 1.2)
                RoundedRectangle(cornerRadius: 2.4, style: .continuous)
                    .fill(fill)
                    .frame(width: max(3, (bodyWidth - inset * 2) * CGFloat(max(0, min(1, level)))),
                           height: bodyHeight - inset * 2)
                    .padding(.leading, inset)
                if charging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 0.6)
                        .frame(width: bodyWidth, height: bodyHeight)
                }
            }
            .frame(width: bodyWidth, height: bodyHeight)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.45))
                .frame(width: 2, height: 4.5)
        }
        .accessibilityHidden(true)
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
        Button {
            UISounds.shared.play(.tap)
            action()
        } label: {
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
        Group {
            if classicIcons {
                // Classic icon: no backing box, fully rounded like an app icon.
                GeometryReader { geo in
                    Group {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            EmulatorTheme.panel
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: geo.size.width * 0.24, style: .continuous))
                }
                .aspectRatio(1, contentMode: .fit)
            } else {
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
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .accessibilityHidden(true)
        .task(id: "\(titleID)|\(classicIcons)") {
            image = await GameCoverLoader.load(titleID, classic: classicIcons)
        }
    }
}

// MARK: - Landscape carousel

enum LibraryMotion {
    /// Quick, lightly damped spring: retargets smoothly when the focus
    /// changes again mid-flight (rapid back-and-forth swipes).
    static var move: Animation { .spring(response: 0.26, dampingFraction: 0.88) }
}

/// A centered cover row driven directly by the focused game and a drag
/// offset (no ScrollView / scroll-position state), so swipes and gamepad
/// moves can never get out of step with each other.
struct GameCarousel<Menu: View>: View {
    let games: [CoreController.AppInfo]
    let initialID: String?
    /// The centered game. Shared with the library so a gamepad can move it.
    @Binding var focusedID: String?
    let onLaunch: (String) -> Void
    @ViewBuilder let menu: (CoreController.AppInfo) -> Menu

    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @State private var drag: CGFloat = 0

    private var currentIndex: Int {
        games.firstIndex(where: { $0.titleId == focusedID }) ?? 0
    }

    var body: some View {
        GeometryReader { proxy in
            let width = cardWidth(in: proxy.size)
            let spacing: CGFloat = 22
            let stride = width + spacing
            let current = min(currentIndex, max(games.count - 1, 0))
            let reach = Int(ceil(proxy.size.width / stride / 2)) + 1
            let lo = max(0, current - reach)
            let hi = min(games.count - 1, current + reach)
            ZStack {
                if !games.isEmpty, lo <= hi {
                    ForEach(lo...hi, id: \.self) { i in
                        let relative = CGFloat(i - current) + drag / stride
                        let distance = min(abs(relative), 1)
                        let depth = Double(abs(relative))
                        card(games[i], width: width)
                            .scaleEffect(1 - 0.14 * distance)
                            // Opacity is far cheaper than brightness/saturation
                            // filters, which made quick swipes stutter.
                            .opacity(1.0 - 0.4 * Double(distance))
                            .offset(x: relative * stride)
                            .zIndex(-depth)
                            .onTapGesture {
                                if i == current {
                                    onLaunch(games[i].titleId)
                                } else {
                                    withAnimation(LibraryMotion.move) { focusedID = games[i].titleId }
                                }
                            }
                            .contextMenu { menu(games[i]) }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(stride: stride, current: current))
            .clipped()
        }
        .sensoryFeedback(.selection, trigger: focusedID)
        .onChange(of: focusedID) { old, new in
            if old != nil, new != nil { UISounds.shared.play(.move) }
        }
        .onAppear {
            if !games.contains(where: { $0.titleId == focusedID }) {
                focusedID = games.contains(where: { $0.titleId == initialID }) ? initialID : games.first?.titleId
            }
        }
    }

    private func dragGesture(stride: CGFloat, current: Int) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                var translation = value.translation.width
                // Rubber-band past the first and last game.
                if (current == 0 && translation > 0) || (current == games.count - 1 && translation < 0) {
                    translation *= 0.35
                }
                drag = translation
            }
            .onEnded { value in
                var steps = Int((-value.predictedEndTranslation.width / stride).rounded())
                if steps == 0, abs(value.translation.width) > 40 {
                    steps = value.translation.width < 0 ? 1 : -1
                }
                steps = max(-4, min(4, steps))
                let target = max(0, min(games.count - 1, current + steps))
                withAnimation(LibraryMotion.move) {
                    drag = 0
                    focusedID = games[target].titleId
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("game-\(game.titleId)")
    }
}
