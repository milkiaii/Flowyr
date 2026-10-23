// Vita3K iOS — trophies: the collection browser (library) and the
// "trophy unlocked" banner shown over the game.
import SwiftUI
import UIKit
import Vita3KCore

// MARK: - Model

enum TrophyGrade: Int, CaseIterable {
    case platinum = 1, gold, silver, bronze

    var tint: Color {
        switch self {
        case .platinum: Color(red: 0.56, green: 0.78, blue: 0.95)
        case .gold: Color(red: 1.0, green: 0.78, blue: 0.22)
        case .silver: Color(red: 0.72, green: 0.74, blue: 0.80)
        case .bronze: Color(red: 0.80, green: 0.50, blue: 0.25)
        }
    }

    var label: String {
        switch self {
        case .platinum: L10n.text("Platina")
        case .gold: L10n.text("Ouro")
        case .silver: L10n.text("Prata")
        case .bronze: L10n.text("Bronze")
        }
    }
}

struct TrophyEntry: Identifiable {
    let id: Int
    let grade: TrophyGrade
    let hidden: Bool
    let earned: Bool
    let date: Date?
    let name: String
    let detail: String
    let iconPath: String

    var isSecret: Bool { hidden && !earned }
}

struct TrophyCollection: Identifiable {
    let id: String
    let title: String
    let iconPath: String
    let total: Int
    let unlocked: Int
    /// Earned trophies per grade, in `TrophyGrade.allCases` order.
    let counts: [Int]
    var trophies: [TrophyEntry]

    var progress: Double { total == 0 ? 0 : Double(unlocked) / Double(total) }
}

struct TrophyUnlock: Identifiable {
    let id = UUID()
    let grade: TrophyGrade
    let name: String
    let detail: String
    let icon: UIImage?
}

extension Vita3KCore {
    static func sessionTrophies() -> String {
        let capacity = 4 << 20
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            vita3k_ios_session_trophies(ptr.baseAddress!, capacity)
        }
        return rc == 0 ? CText.string(buffer) : ""
    }

    /// Trophy set of the running game, if it has one yet.
    static func activeTrophyID() -> String? {
        var buffer = [Int8](repeating: 0, count: 64)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr in
            vita3k_ios_session_active_trophy_id(ptr.baseAddress!, 64)
        }
        return rc == 0 ? CText.string(buffer) : nil
    }

    static func popTrophy() -> TrophyUnlock? {
        var meta = [Int8](repeating: 0, count: 2048)
        var icon = [UInt8](repeating: 0, count: 1 << 20)
        var length = 0
        let rc = meta.withUnsafeMutableBufferPointer { m in
            icon.withUnsafeMutableBufferPointer { i in
                vita3k_ios_session_pop_trophy(m.baseAddress!, 2048, i.baseAddress!, 1 << 20, &length)
            }
        }
        guard rc == 1 else { return nil }
        let fields = CText.string(meta).split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 5 else { return nil }
        let grade = TrophyGrade(rawValue: Int(fields[2]) ?? 4) ?? .bronze
        let image = length > 0 ? UIImage(data: Data(icon.prefix(length))) : nil
        return TrophyUnlock(grade: grade, name: fields[3], detail: fields[4], icon: image)
    }
}

enum TrophyParser {
    static func parse(_ text: String) -> [TrophyCollection] {
        var result: [TrophyCollection] = []
        var current: TrophyCollection?
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if f.first == "C", f.count >= 10 {
                if let current { result.append(current) }
                current = TrophyCollection(
                    id: f[1], title: f[2], iconPath: f[3],
                    total: Int(f[4]) ?? 0, unlocked: Int(f[5]) ?? 0,
                    counts: (6...9).map { Int(f[$0]) ?? 0 }, trophies: [])
            } else if f.first == "T", f.count >= 9, current != nil {
                let stamp = UInt64(f[5]) ?? 0
                current?.trophies.append(TrophyEntry(
                    id: Int(f[1]) ?? 0, grade: TrophyGrade(rawValue: Int(f[2]) ?? 4) ?? .bronze,
                    hidden: f[3] == "1", earned: f[4] == "1",
                    date: stamp > 0 ? Date(timeIntervalSince1970: TimeInterval(stamp)) : nil,
                    name: f[6], detail: f[7], iconPath: f[8]))
            }
        }
        if let current { result.append(current) }
        // Games you have progress in first, then by title.
        return result.sorted {
            if ($0.unlocked > 0) != ($1.unlocked > 0) { return $0.unlocked > 0 }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }
}

@MainActor
final class TrophyStore: ObservableObject {
    @Published var collections: [TrophyCollection] = []
    @Published var loaded = false

    func reload() async {
        let text = await Task.detached(priority: .userInitiated) { Vita3KCore.sessionTrophies() }.value
        collections = TrophyParser.parse(text)
        loaded = true
    }
}

// MARK: - Images

enum TrophyImageLoader {
    nonisolated(unsafe) private static let cache = NSCache<NSString, UIImage>()

    static func load(_ path: String) -> UIImage? {
        if let hit = cache.object(forKey: path as NSString) { return hit }
        guard let image = UIImage(contentsOfFile: path) else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}

struct TrophyImage: View {
    let path: String
    var radius: CGFloat = 12
    @State private var image: UIImage?

    var body: some View {
        // The image is an overlay so its fill size never changes the layout
        // size (a wide icon used to push the text underneath it).
        Rectangle().fill(EmulatorTheme.artworkBackground)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: "trophy.fill").foregroundStyle(.secondary)
                }
            }
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .task(id: path) {
            let p = path
            image = await Task.detached { TrophyImageLoader.load(p) }.value
        }
    }
}

struct GradeCounts: View {
    let counts: [Int]
    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(TrophyGrade.allCases.enumerated()), id: \.offset) { index, grade in
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill").foregroundStyle(grade.tint)
                    Text(verbatim: "\(counts.indices.contains(index) ? counts[index] : 0)")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
    }
}

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule().fill(Color.primary.opacity(0.75)).frame(width: max(6, proxy.size.width * value))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Browser

struct TrophiesView: View {
    /// Opens straight into this trophy set (the running game).
    var openID: String?
    let onClose: () -> Void
    @StateObject private var store = TrophyStore()
    @ObservedObject private var pad = GamepadInput.shared
    @AppStorage(EmulatorTheme.lightModePreference) private var lightMode = false
    @State private var selected: TrophyCollection?
    @State private var focus = 0
    @State private var detailFocus = 0
    @State private var owner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                if let selected {
                    detail(selected)
                } else if !store.loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.collections.isEmpty {
                    empty
                } else {
                    list
                }
            }
        }
        .background(EmulatorTheme.background)
        .tint(EmulatorTheme.accent)
        .preferredColorScheme(lightMode ? .light : .dark)
        .task {
            await store.reload()
            if let openID, let match = store.collections.first(where: { $0.id == openID }) {
                selected = match
            }
        }
        .onAppear { pad.start(owner: owner) }
        .onDisappear { pad.stop(owner: owner) }
        .onChange(of: pad.lastEvent) { _, event in
            guard let event else { return }
            handle(event.button)
        }
    }

    private var header: some View {
        HStack {
            if selected != nil {
                Button { back() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityIdentifier("trophies-back")
            }
            Text(selected?.title ?? L10n.text("Troféus"))
                .font(.headline).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: selected == nil ? .center : .leading)
            Button(L10n.text("Concluído")) { UISounds.shared.play(.back); onClose() }
                .accessibilityIdentifier("trophies-done")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "trophy.fill").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Nenhum troféu ainda").font(.headline)
            Text("Jogue um jogo com troféus para vê-los aqui.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Collections

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Array(store.collections.enumerated()), id: \.element.id) { index, collection in
                        Button { open(collection) } label: { card(collection) }
                            .buttonStyle(.plain)
                            .overlay { ring(pad.connected && focus == index, radius: 22) }
                            .id(collection.id)
                    }
                }
                .padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .onChange(of: focus) { _, index in
                guard store.collections.indices.contains(index) else { return }
                withAnimation(.snappy) { proxy.scrollTo(store.collections[index].id, anchor: .center) }
            }
        }
    }

    private func card(_ c: TrophyCollection) -> some View {
        HStack(spacing: 14) {
            TrophyImage(path: c.iconPath, radius: 14).frame(width: 112, height: 63)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(c.title.isEmpty ? c.id : c.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(verbatim: "\(c.unlocked)/\(c.total)")
                        .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                }
                ProgressBar(value: c.progress)
                GradeCounts(counts: c.counts)
            }
        }
        .padding(12)
        .background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
    }

    private func ring(_ on: Bool, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.primary.opacity(on ? 0.55 : 0), lineWidth: 2)
            .animation(.easeOut(duration: 0.12), value: on)
    }

    // MARK: Detail

    private func detail(_ c: TrophyCollection) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 10) {
                    VStack(spacing: 12) {
                        HStack(spacing: 14) {
                            TrophyImage(path: c.iconPath, radius: 16).frame(width: 128, height: 72)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: "\(Int((c.progress * 100).rounded()))%")
                                    .font(.system(size: 28, weight: .bold, design: .rounded))
                                Text(verbatim: L10n.format("%d de %d", c.unlocked, c.total))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        ProgressBar(value: c.progress)
                        GradeCounts(counts: c.counts).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    .background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    ForEach(Array(c.trophies.enumerated()), id: \.element.id) { index, trophy in
                        row(trophy)
                            .overlay { ring(pad.connected && detailFocus == index, radius: 18) }
                            .id(trophy.id)
                    }
                }
                .padding(16).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .onChange(of: detailFocus) { _, index in
                guard c.trophies.indices.contains(index) else { return }
                withAnimation(.snappy) { proxy.scrollTo(c.trophies[index].id, anchor: .center) }
            }
        }
    }

    private func row(_ t: TrophyEntry) -> some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                if t.isSecret {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EmulatorTheme.artworkBackground)
                        .overlay(Image(systemName: "questionmark").foregroundStyle(.secondary))
                } else {
                    TrophyImage(path: t.iconPath, radius: 12)
                }
                Image(systemName: "trophy.fill").font(.system(size: 11))
                    .foregroundStyle(t.grade.tint)
                    .padding(4).background(.regularMaterial, in: Circle()).offset(x: 5, y: 5)
            }
            .frame(width: 52, height: 52)
            .opacity(t.earned ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.isSecret ? L10n.text("Troféu oculto") : t.name).font(.subheadline.weight(.semibold))
                Text(t.isSecret ? L10n.text("Continue jogando para revelar.") : t.detail)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if t.earned, let date = t.date {
                    Text(verbatim: L10n.format("Conquistado em %@", date.formatted(.dateTime.day().month(.abbreviated).year())))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !t.earned { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.tertiary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EmulatorTheme.panel.opacity(t.earned ? 1 : 0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: Navigation

    private func open(_ collection: TrophyCollection) {
        UISounds.shared.play(.tap)
        detailFocus = 0
        withAnimation(.snappy) { selected = collection }
    }

    private func back() {
        UISounds.shared.play(.back)
        withAnimation(.snappy) { selected = nil }
    }

    private func handle(_ button: PadButton) {
        if let selected {
            switch button {
            case .down: detailFocus = min(detailFocus + 1, selected.trophies.count - 1); UISounds.shared.play(.move)
            case .up: detailFocus = max(detailFocus - 1, 0); UISounds.shared.play(.move)
            case .back: back()
            default: break
            }
            return
        }
        switch button {
        case .down: focus = min(focus + 1, store.collections.count - 1); UISounds.shared.play(.move)
        case .up: focus = max(focus - 1, 0); UISounds.shared.play(.move)
        case .confirm: if store.collections.indices.contains(focus) { open(store.collections[focus]) }
        case .back, .r1:
            UISounds.shared.play(.back)
            onClose()
        default: break
        }
    }
}

// MARK: - Unlock banner (over the game)

@MainActor
final class TrophyBannerModel: ObservableObject {
    @Published var current: TrophyUnlock?
    private var queue: [TrophyUnlock] = []
    private var showing = false

    func enqueue(_ unlock: TrophyUnlock) {
        queue.append(unlock)
        if !showing { Task { await run() } }
    }

    func reset() {
        queue.removeAll()
        current = nil
        showing = false
    }

    private func run() async {
        showing = true
        while !queue.isEmpty {
            let next = queue.removeFirst()
            UISounds.shared.play(.trophy)
            withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { current = next }
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeIn(duration: 0.3)) { current = nil }
            try? await Task.sleep(for: .milliseconds(450))
        }
        showing = false
    }
}

struct TrophyBannerView: View {
    @ObservedObject var model: TrophyBannerModel

    var body: some View {
        ZStack {
            if let unlock = model.current {
                HStack(spacing: 12) {
                    ZStack {
                        if let icon = unlock.icon {
                            Image(uiImage: icon).resizable().scaledToFill()
                        } else {
                            Rectangle().fill(EmulatorTheme.artworkBackground)
                            Image(systemName: "trophy.fill").foregroundStyle(unlock.grade.tint)
                        }
                    }
                    .frame(width: 46, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: "trophy.fill").foregroundStyle(unlock.grade.tint)
                            Text("Troféu desbloqueado")
                                .textCase(.uppercase).tracking(0.8)
                        }
                        .font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                        Text(unlock.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: 340)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
    }
}
