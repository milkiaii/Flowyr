// Vita3K iOS — the app's floating action card: a few big rows (resume,
// settings, favourite, delete…). Used by the game long-press menu in the
// library and by the in-game pause menu, with touch and controller focus.
import SwiftUI

struct MenuAction: Identifiable {
    let id: String
    var title: LocalizedStringKey
    var symbol: String
    var destructive = false
    var enabled = true
}

struct ActionMenuCard<Header: View>: View {
    @Environment(\.palette) private var palette
    let actions: [MenuAction]
    /// Index with the controller highlight, or nil when no pad is in use.
    var focus: Int?
    @ViewBuilder let header: Header
    let onSelect: (MenuAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.padding(.horizontal, 6).padding(.top, 2)
            VStack(spacing: 4) {
                ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                    row(action, focused: focus == index)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(palette.backdrop?.menuTint.opacity(0.55) ?? .clear,
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 22, y: 10)
        .padding(.horizontal, 16)
    }

    private func row(_ action: MenuAction, focused: Bool) -> some View {
        Button {
            UISounds.shared.play(.tap)
            onSelect(action)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.primary.opacity(0.08), in: Circle())
                Text(action.title).font(.body.weight(.medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(action.destructive ? palette.warning : .primary)
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? Color.primary.opacity(0.10) : palette.panel.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(focused ? 0.55 : 0), lineWidth: 2))
            .contentShape(Rectangle())
            .opacity(action.enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!action.enabled)
        .accessibilityIdentifier("menu-\(action.id)")
    }
}

/// Dimmed backdrop + centred card; tapping outside dismisses.
struct ActionMenuOverlay<Header: View>: View {
    let actions: [MenuAction]
    var focus: Int?
    @ViewBuilder let header: Header
    let onSelect: (MenuAction) -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture(perform: onDismiss)
            ActionMenuCard(actions: actions, focus: focus, header: { header }, onSelect: onSelect)
        }
    }
}

// MARK: - In-game pause menu

@MainActor
final class GameMenuModel: ObservableObject {
    @Published var focus: Int?
}

struct GameMenuView: View {
    @ObservedObject var model: GameMenuModel
    let onResume: () -> Void
    let onSettings: () -> Void
    let onTrophies: () -> Void
    let onControls: () -> Void
    let onExit: () -> Void

    static let actions: [MenuAction] = [
        MenuAction(id: "resume", title: "Continuar", symbol: "play.fill"),
        MenuAction(id: "settings", title: "Configurações", symbol: "slider.horizontal.3"),
        MenuAction(id: "controls", title: "Editar controles", symbol: "gamecontroller.fill"),
        MenuAction(id: "trophies", title: "Troféus", symbol: "trophy.fill"),
        MenuAction(id: "exit", title: "Voltar à biblioteca", symbol: "rectangle.portrait.and.arrow.right"),
    ]

    var body: some View {
        ActionMenuOverlay(actions: Self.actions, focus: model.focus, header: {
            Text("Pausado")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(1.2).textCase(.uppercase).foregroundStyle(.secondary)
        }, onSelect: { action in
            switch action.id {
            case "resume": onResume()
            case "settings": onSettings()
            case "controls": onControls()
            case "trophies": onTrophies()
            default: onExit()
            }
        }, onDismiss: onResume)
        .appTheme()
    }
}
