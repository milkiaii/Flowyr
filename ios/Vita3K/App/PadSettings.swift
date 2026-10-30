// Vita3K iOS — settings screens that work with touch and a game controller.
// A page is described as data (sections of items); the page renders the rows in
// the app's card style and runs the controller navigation (focus ring, A/B,
// left/right to change values, L1/R1 to jump between sections).
import SwiftUI

struct SettingItem: Identifiable {
    enum Kind {
        case toggle(Binding<Bool>)
        case choice(Binding<Int>, [String])
        case slider(Binding<Double>, ClosedRange<Double>, Double, String)
        case action(() -> Void)
        case info(String)
    }

    let id: String
    var title: LocalizedStringKey
    var detail: LocalizedStringKey?
    var symbol: String?
    var kind: Kind
    var enabled = true
    var destructive = false
    /// Shows a disclosure chevron (the row opens another page).
    var chevron = false

    var isFocusable: Bool {
        if case .info = kind { return false }
        return enabled
    }
}

struct SettingSection: Identifiable {
    let id: String
    var title: LocalizedStringKey
    var items: [SettingItem]
    var footer: LocalizedStringKey?
    /// Shown between the title and the rows (status badges, game header…).
    var accessory: AnyView?
}

struct PadSettingsPage: View {
    @Environment(\.palette) private var palette
    let sections: [SettingSection]
    /// False while another screen is pushed on top: the pad then belongs to it.
    var isActive = true
    var status = ""
    let onClose: () -> Void

    @ObservedObject private var pad = GamepadInput.shared
    @State private var focus: String?
    @State private var owner = UUID()

    private var focusable: [SettingItem] { sections.flatMap(\.items).filter(\.isFocusable) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    ForEach(sections) { section in sectionCard(section) }
                    if !status.isEmpty {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    }
                    if pad.connected { legend }
                    Color.clear.frame(height: 1).id("settingsBottom")
                }
                .padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            }
            .background { ThemedBackground() }
            .onChange(of: pad.lastEvent) { _, event in
                guard isActive, let event else { return }
                handle(event.button, proxy: proxy)
            }
        }
        .onAppear {
            pad.start(owner: owner)
            if pad.connected, focus == nil { focus = focusable.first?.id }
        }
        .onDisappear { pad.stop(owner: owner) }
    }

    // MARK: - Layout

    private func sectionCard(_ section: SettingSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.1).textCase(.uppercase)
                .foregroundStyle(.secondary).padding(.leading, 6)
            if let accessory = section.accessory { accessory.padding(.horizontal, 6) }
            VStack(spacing: 2) {
                ForEach(section.items) { item in row(item).id(item.id) }
            }
            .padding(6)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            if let footer = section.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            hint("A", "Selecionar"); hint("B", "Voltar"); hint("L1 R1", "Seção")
        }
        .font(.caption2).foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: key).font(.system(size: 10, weight: .heavy, design: .rounded))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.primary.opacity(0.12), in: Capsule())
            Text(label)
        }
    }

    @ViewBuilder private func row(_ item: SettingItem) -> some View {
        let focused = pad.connected && focus == item.id
        Group {
            switch item.kind {
            case .toggle(let binding):
                Button { toggle(binding) } label: {
                    line(item) { Toggle("", isOn: binding).labelsHidden().allowsHitTesting(false) }
                }
                .buttonStyle(.plain)
            case .choice(let binding, let options):
                line(item) {
                    Menu {
                        ForEach(options.indices, id: \.self) { i in
                            Button(options[i]) { UISounds.shared.play(.tap); binding.wrappedValue = i }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(verbatim: options.indices.contains(binding.wrappedValue) ? options[binding.wrappedValue] : "")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                    .disabled(!item.enabled)
                }
            case .slider(let binding, let range, let step, let unit):
                VStack(spacing: 6) {
                    line(item) { Text(verbatim: formatted(binding.wrappedValue, unit)).foregroundStyle(.secondary).font(.subheadline.monospacedDigit()) }
                    Slider(value: binding, in: range, step: step).padding(.horizontal, 14).padding(.bottom, 8)
                        .disabled(!item.enabled)
                }
            case .action(let run):
                Button { UISounds.shared.play(.tap); run() } label: {
                    line(item) {
                        if item.chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary) }
                    }
                }
                .buttonStyle(.plain)
            case .info(let value):
                line(item) { Text(verbatim: value).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
        .opacity(item.enabled ? 1 : 0.45)
        .disabled(!item.enabled)
        .background(focused ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(focused ? 0.55 : 0), lineWidth: 2))
        .animation(.easeOut(duration: 0.12), value: focused)
    }

    private func line<Trailing: View>(_ item: SettingItem, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            if let symbol = item.symbol {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    .frame(width: 30, height: 30).background(Color.primary.opacity(0.08), in: Circle())
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body)
                    .foregroundStyle(item.destructive ? palette.warning : .primary)
                if let detail = item.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func formatted(_ value: Double, _ unit: String) -> String {
        unit == "%" ? "\(Int((value * 100).rounded()))%" : value.formatted() + unit
    }

    private func toggle(_ binding: Binding<Bool>) {
        UISounds.shared.play(.tap)
        binding.wrappedValue.toggle()
    }

    // MARK: - Controller

    private func handle(_ button: PadButton, proxy: ScrollViewProxy) {
        let items = focusable
        guard !items.isEmpty else { if button == .back { onClose() }; return }
        let index = items.firstIndex { $0.id == focus }
        switch button {
        case .down: move(to: min((index ?? -1) + 1, items.count - 1), in: items, proxy: proxy)
        case .up: move(to: max((index ?? items.count) - 1, 0), in: items, proxy: proxy)
        case .r1, .l1:
            let ids = sections.map { $0.items.first(where: \.isFocusable)?.id }
            let current = sections.firstIndex { $0.items.contains { $0.id == focus } } ?? 0
            let next = button == .r1 ? min(current + 1, sections.count - 1) : max(current - 1, 0)
            if let id = ids[next], let i = items.firstIndex(where: { $0.id == id }) { move(to: i, in: items, proxy: proxy) }
        case .confirm:
            guard let item = index.map({ items[$0] }) else { focus = items.first?.id; return }
            switch item.kind {
            case .toggle(let b): toggle(b)
            case .choice(let b, let options): UISounds.shared.play(.tap); b.wrappedValue = (b.wrappedValue + 1) % options.count
            case .action(let run): UISounds.shared.play(.confirm); run()
            default: break
            }
        case .left, .right:
            guard let item = index.map({ items[$0] }) else { return }
            let delta = button == .right ? 1 : -1
            switch item.kind {
            case .toggle(let b): if b.wrappedValue != (delta > 0) { toggle(b) }
            case .choice(let b, let options):
                let next = b.wrappedValue + delta
                if options.indices.contains(next) { UISounds.shared.play(.move); b.wrappedValue = next }
            case .slider(let b, let range, let step, _):
                let next = min(max(b.wrappedValue + Double(delta) * step, range.lowerBound), range.upperBound)
                if next != b.wrappedValue { UISounds.shared.play(.move); b.wrappedValue = next }
            default: break
            }
        case .back:
            UISounds.shared.play(.back)
            onClose()
        default: break
        }
    }

    private func move(to index: Int, in items: [SettingItem], proxy: ScrollViewProxy) {
        let id = items[index].id
        guard id != focus else { return }
        focus = id
        UISounds.shared.play(.move)
        withAnimation(.snappy) {
            if index == 0 { proxy.scrollTo(sections.first?.id ?? id, anchor: .top) }
            else if index == items.count - 1 { proxy.scrollTo("settingsBottom", anchor: .bottom) }
            else { proxy.scrollTo(id, anchor: .center) }
        }
    }
}
