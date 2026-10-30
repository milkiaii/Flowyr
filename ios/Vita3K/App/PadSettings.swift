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

private struct RowBoundsKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
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
    @State private var picking: String?
    @State private var pickIndex = 0
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
            .overlayPreferenceValue(RowBoundsKey.self) { anchors in
                GeometryReader { geo in pickerOverlay(anchors, geo) }
            }
            .onChange(of: pad.lastEvent) { _, event in
                guard isActive, let event else { return }
                if picking != nil { handlePicker(event.button) } else { handle(event.button, proxy: proxy) }
            }
        }
        .onAppear {
            pad.start(owner: owner)
            if pad.connected, focus == nil { focus = focusable.first?.id }
        }
        .onDisappear { pad.stop(owner: owner) }
    }

    // MARK: - Dropdown

    /// A compact floating list under the value, drawn in SwiftUI (no system menu).
    @ViewBuilder private func pickerOverlay(_ anchors: [String: Anchor<CGRect>], _ geo: GeometryProxy) -> some View {
        if let id = picking, let anchor = anchors[id], let choice = pickingChoice {
            let rect = geo[anchor]
            let rowHeight: CGFloat = 44
            let width = min(210, geo.size.width - 32)
            let height = min(CGFloat(choice.options.count) * rowHeight + 12, min(geo.size.height - 24, 330))
            let below = rect.maxY + 6 + height <= geo.size.height - 8
            let y = below ? rect.maxY + 6 : max(8, rect.minY - 6 - height)
            let x = min(rect.maxX, geo.size.width - 16) - width
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { closePicker() }
                ScrollViewReader { list in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(choice.options.indices, id: \.self) { i in
                                Button {
                                    UISounds.shared.play(.tap)
                                    choice.binding.wrappedValue = i
                                    closePicker()
                                } label: {
                                    HStack {
                                        Text(verbatim: choice.options[i])
                                        Spacer(minLength: 8)
                                        if i == choice.binding.wrappedValue { Image(systemName: "checkmark").font(.footnote.weight(.bold)) }
                                    }
                                    .padding(.horizontal, 14).frame(height: rowHeight)
                                    .background(pickIndex == i ? Color.primary.opacity(0.14) : .clear,
                                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain).id(i)
                            }
                        }
                        .padding(6)
                    }
                    .onAppear { list.scrollTo(pickIndex, anchor: .center) }
                    .onChange(of: pickIndex) { _, i in withAnimation(.snappy) { list.scrollTo(i, anchor: .center) } }
                }
                .frame(width: width, height: height)
                .background(palette.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .environment(\.colorScheme, palette.scheme)
                .offset(x: x, y: y)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var pickingChoice: (binding: Binding<Int>, options: [String])? {
        guard let id = picking, let item = sections.flatMap(\.items).first(where: { $0.id == id }),
              case .choice(let binding, let options) = item.kind else { return nil }
        return (binding, options)
    }

    private func openPicker(_ item: SettingItem) {
        guard case .choice(let binding, _) = item.kind else { return }
        UISounds.shared.play(.tap)
        pickIndex = binding.wrappedValue
        withAnimation(.easeOut(duration: 0.15)) { picking = item.id }
    }

    private func closePicker() { withAnimation(.easeOut(duration: 0.12)) { picking = nil } }

    private func handlePicker(_ button: PadButton) {
        guard let choice = pickingChoice else { picking = nil; return }
        switch button {
        case .down: if pickIndex < choice.options.count - 1 { pickIndex += 1; UISounds.shared.play(.move) }
        case .up: if pickIndex > 0 { pickIndex -= 1; UISounds.shared.play(.move) }
        case .confirm: UISounds.shared.play(.tap); choice.binding.wrappedValue = pickIndex; closePicker()
        case .back: UISounds.shared.play(.back); closePicker()
        default: break
        }
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
                Button { openPicker(item) } label: {
                    line(item) {
                        HStack(spacing: 5) {
                            Text(verbatim: options.indices.contains(binding.wrappedValue) ? options[binding.wrappedValue] : "")
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .anchorPreference(key: RowBoundsKey.self, value: .bounds) { [item.id: $0] }
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
            case .choice: openPicker(item)
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
