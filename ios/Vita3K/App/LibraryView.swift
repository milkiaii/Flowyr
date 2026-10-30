import SwiftUI

struct LibraryView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var controller: CoreController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale
    let launch: (String) -> Void
    let importContent: (ImportKind) -> Void
    let enterZRIF: () -> Void
    let openSettings: () -> Void
    /// False while a sheet, the importer or a game is on screen.
    let inputEnabled: Bool
    @ObservedObject private var deviceStatus = DeviceStatus.shared
    @ObservedObject private var pad = GamepadInput.shared
    @State private var focusedID: String?
    @State private var gridWidth: CGFloat = 0
    @State private var showAdd = false
    @State private var showTrophies = false
    @State private var actionsGame: CoreController.AppInfo?
    @State private var actionFocus = 0
    /// A long press also ends with the button's tap; swallow that one.
    @State private var suppressTap = false
    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @State private var search = ""
    @State private var favoritesOnly = false
    @State private var configGame: CoreController.AppInfo?
    @State private var deleteGame: CoreController.AppInfo?
    @State private var deleteError: String?
    @AppStorage("library.favorites") private var favorites = ""
    @AppStorage("library.lastPlayed") private var lastPlayed = ""
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.sortByID") private var sortByID = false

    private var favoriteIDs: Set<String> { Set(favorites.split(separator: ",").map(String.init)) }
    private var games: [CoreController.AppInfo] {
        controller.apps.filter {
            (!favoritesOnly || favoriteIDs.contains($0.titleId)) &&
                (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.titleId.localizedCaseInsensitiveContains(search))
        }.sorted {
            (sortByID ? $0.titleId : $0.title).localizedStandardCompare(sortByID ? $1.titleId : $1.title) == .orderedAscending
        }
    }

    /// Landscape + grid mode shows the cover carousel; list mode stays a list.
    private var showsCarousel: Bool {
        !listLayout && verticalSizeClass == .compact && !games.isEmpty
    }

    var body: some View {
        ZStack {
            ThemedBackground()
            VStack(spacing: 0) {
                LibraryTopBar(status: deviceStatus, jitStatus: controller.jitStatus) {
                    Task { _ = await controller.checkJIT() }
                }
                .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
                if controller.loggingMode != .off {
                    LoggingModeBanner(mode: controller.loggingMode)
                }
                content
            }
        }
        .overlay(alignment: .bottom) {
            LibraryFloatingBar(
                layoutSymbol: listLayout ? "square.grid.2x2" : "list.bullet",
                layoutLabel: LocalizedStringKey(listLayout ? "Exibir em grade" : "Exibir em lista"),
                importDisabled: !controller.sessionInitialized || controller.isImporting,
                onLayout: { withAnimation(.snappy) { listLayout.toggle() } },
                isAddOpen: showAdd,
                onAdd: { withAnimation(addAnimation) { showAdd.toggle() } },
                onTrophies: { UISounds.shared.play(.open); showTrophies = true },
                onSettings: openSettings
            )
            .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) {
            if showAdd {
                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { withAnimation(addAnimation) { showAdd = false } }
                        .transition(.opacity)
                    AddContentPanel { action in choose(action) }
                        .padding(.bottom, 84)
                        .transition(.scale(scale: 0.88, anchor: .bottom).combined(with: .opacity))
                }
            }
        }
        .overlay {
            if let game = actionsGame {
                ActionMenuOverlay(actions: actions(for: game), focus: pad.connected ? actionFocus : nil, header: {
                    HStack(spacing: 10) {
                        GameCover(titleID: game.titleId, cornerRadius: 10).frame(width: classicIcons ? 44 : 78)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(game.title.isEmpty ? game.titleId : game.title)
                                .font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(game.titleId).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }, onSelect: { perform($0, on: game) }, onDismiss: closeActions)
                .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .onAppear { pad.start(owner: PadOwner.library) }
        .onDisappear { pad.stop(owner: PadOwner.library) }
        .onChange(of: pad.lastEvent) { _, event in
            guard inputEnabled, !showTrophies, configGame == nil, deleteGame == nil, let event else { return }
            handlePad(event.button)
        }
        .onChange(of: games.map(\.titleId)) { _, ids in
            if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        }
        .sheet(isPresented: $showTrophies) {
            TrophiesView(onClose: { showTrophies = false })
        }
        .sheet(item: $configGame) { game in
            GameConfigView(titleId: game.titleId, title: game.title, onDone: {
                controller.refreshApps()
                configGame = nil
            })
        }
        .alert("Apagar jogo?", isPresented: Binding(
            get: { deleteGame != nil }, set: { if !$0 { deleteGame = nil } }
        ), presenting: deleteGame) { game in
            Button("Cancelar", role: .cancel) { deleteGame = nil }
            Button("Apagar jogo", role: .destructive) {
                deleteGame = nil
                Task { deleteError = await controller.deleteGame(game) }
            }.accessibilityIdentifier("confirm-delete-game")
        } message: { game in
            Text("Apagar \(game.title) (\(game.titleId)) do iPhone? O jogo, atualizações, DLCs, configuração e caches de shaders serão removidos. Saves e troféus serão mantidos. Para jogar novamente, será necessário importar o jogo.")
        }
        .alert("Não foi possível apagar o jogo", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if games.isEmpty {
            ScrollView {
                VStack(spacing: 16) {
                    if !controller.apps.isEmpty { searchHeader }
                    if controller.apps.isEmpty {
                        EmptyLibraryView(canImport: controller.sessionInitialized && !controller.isImporting) { importContent(.game) }
                    } else {
                        ContentUnavailableView {
                            Label("Nenhum jogo encontrado", systemImage: "magnifyingglass")
                        } description: {
                            Text("Tente outra busca ou veja todos os jogos.")
                        }
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                }
                .padding(.horizontal, 16)
            }
            .refreshable { controller.refreshApps() }
        } else if showsCarousel {
            GameCarousel(games: games, initialID: lastPlayed, focusedID: $focusedID, onLaunch: launch,
                         onLongPress: openActions)
            .padding(.bottom, 84)
        } else if listLayout {
            listContent
        } else {
            gridContent
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Buscar jogo ou título ID", text: $search)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(palette.panel, in: Capsule())
            Button { UISounds.shared.play(.tap); favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(palette.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Favoritos"))
        }
    }

    private var listContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Eager (not lazy) so every row has its real height and scrollTo
            // lands exactly on the focused game.
            VStack(spacing: 0) {
                searchHeader.padding(.bottom, 8).id("libraryTop")
                ForEach(games) { game in
                    gameRow(game)
                    Divider()
                }
                Color.clear.frame(height: 1).id("libraryBottom")
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { controller.refreshApps() }
        .onChange(of: focusedID) { _, id in scrollTo(id, using: proxy) }
        .onAppear { restoreScroll(using: proxy) }
        }
    }

    private var gridContent: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 14) {
                searchHeader.id("libraryTop")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(games) { game in gameTile(game) }
                }
                Color.clear.frame(height: 1).id("libraryBottom")
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.top, 4, for: .scrollContent)
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { controller.refreshApps() }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
        .onChange(of: focusedID) { _, id in scrollTo(id, using: proxy) }
        .onAppear { restoreScroll(using: proxy) }
        }
    }

    /// Coming back from the carousel (or a layout switch) the new list has not
    /// scrolled to the focused game yet.
    private func restoreScroll(using proxy: ScrollViewProxy) {
        guard let id = focusedID else { return }
        // A single jump; delayed corrections would yank a list being scrolled.
        jump(to: id, using: proxy)
    }

    private func jump(to id: String, using proxy: ScrollViewProxy) {
        if id == games.first?.titleId { proxy.scrollTo("libraryTop", anchor: .top) }
        else if id == games.last?.titleId { proxy.scrollTo("libraryBottom", anchor: .bottom) }
        else { proxy.scrollTo(id, anchor: .center) }
    }

    private func scrollTo(_ id: String?, using proxy: ScrollViewProxy) {
        guard let id else { return }
        // Edge items scroll to the real top/bottom so they are never
        // left half hidden behind the top bar or the floating bar.
        withAnimation(.snappy) { jump(to: id, using: proxy) }
    }

    // MARK: - Gamepad

    private enum PadOwner { case library }

    private var addAnimation: Animation { .spring(response: 0.32, dampingFraction: 0.84) }

    private func choose(_ action: AddAction) {
        withAnimation(addAnimation) { showAdd = false }
        Task { @MainActor in
            // Let the panel finish leaving before the picker / dialog appears.
            try? await Task.sleep(for: .milliseconds(180))
            switch action {
            case .game: importContent(.game)
            case .license: importContent(.license)
            case .firmware: importContent(.firmware)
            case .zrif: enterZRIF()
            }
        }
    }

    private var gridColumns: Int {
        max(1, Int((gridWidth - 32 + 14) / (160 + 14)))
    }

    private func focusRing(_ id: String, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(Color.primary, lineWidth: 3)
            .opacity(pad.connected && focusedID == id && !showsCarousel ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func moveFocus(by delta: Int) {
        guard !games.isEmpty else { return }
        let ids = games.map(\.titleId)
        guard let current = focusedID, let index = ids.firstIndex(of: current) else {
            focusedID = ids.contains(lastPlayed) ? lastPlayed : ids.first
            return
        }
        let next = min(max(index + delta, 0), ids.count - 1)
        if showsCarousel {
            withAnimation(LibraryMotion.move) { focusedID = ids[next] }
        } else {
            if next != index { UISounds.shared.play(.move) }
            focusedID = ids[next]
        }
    }

    private func handlePad(_ button: PadButton) {
        if let game = actionsGame {
            let list = actions(for: game)
            switch button {
            case .up: actionFocus = max(0, actionFocus - 1); UISounds.shared.play(.move)
            case .down: actionFocus = min(list.count - 1, actionFocus + 1); UISounds.shared.play(.move)
            case .confirm: if list[actionFocus].enabled { UISounds.shared.play(.tap); perform(list[actionFocus], on: game) }
            case .back, .x: UISounds.shared.play(.back); closeActions()
            default: break
            }
            return
        }
        if showAdd {
            if button == .back || button == .select { withAnimation(addAnimation) { showAdd = false } }
            return
        }
        switch button {
        case .left: moveFocus(by: -1)
        case .right: moveFocus(by: 1)
        case .up: if !showsCarousel { moveFocus(by: listLayout ? -1 : -gridColumns) }
        case .down: if !showsCarousel { moveFocus(by: listLayout ? 1 : gridColumns) }
        case .confirm:
            if let id = focusedID, games.contains(where: { $0.titleId == id }) { launch(id) }
            else { moveFocus(by: 0) }
        case .x:
            if let id = focusedID, let game = games.first(where: { $0.titleId == id }) {
                openActions(game)
            }
        case .y:
            UISounds.shared.play(.tap)
            withAnimation(.snappy) { listLayout.toggle() }
        case .r1:
            UISounds.shared.play(.open)
            showTrophies = true
        case .start:
            UISounds.shared.play(.open)
            openSettings()
        case .select:
            if controller.sessionInitialized, !controller.isImporting { withAnimation(addAnimation) { showAdd = true } }
        default: break
        }
    }

    // MARK: - Game actions card

    private func actions(for game: CoreController.AppInfo) -> [MenuAction] {
        let isFavorite = favoriteIDs.contains(game.titleId)
        return [
            MenuAction(id: "favorite", title: LocalizedStringKey(isFavorite ? "Remover dos favoritos" : "Adicionar aos favoritos"),
                       symbol: isFavorite ? "star.slash.fill" : "star.fill"),
            MenuAction(id: "config", title: "Editar Config", symbol: "slider.horizontal.3"),
            MenuAction(id: "delete", title: "Apagar jogo", symbol: "trash.fill", destructive: true,
                       enabled: controller.canDeleteGame),
        ]
    }

    private func perform(_ action: MenuAction, on game: CoreController.AppInfo) {
        actionsGame = nil
        switch action.id {
        case "favorite":
            var ids = favoriteIDs
            if ids.contains(game.titleId) { ids.remove(game.titleId) } else { ids.insert(game.titleId) }
            favorites = ids.sorted().joined(separator: ",")
        case "config": configGame = game
        default: deleteGame = game
        }
    }

    private func openActions(_ game: CoreController.AppInfo) {
        suppressTap = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            suppressTap = false
        }
        actionFocus = 0
        UISounds.shared.play(.open)
        withAnimation(addAnimation) { actionsGame = game }
    }

    private func closeActions() { withAnimation(addAnimation) { actionsGame = nil } }

    private func gameTile(_ game: CoreController.AppInfo) -> some View {
        Button { if !suppressTap { launch(game.titleId) } } label: {
            VStack(alignment: .leading, spacing: 8) {
                GameCover(titleID: game.titleId, cornerRadius: 14)
                    .overlay(alignment: .topTrailing) {
                        if favoriteIDs.contains(game.titleId) {
                            Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                                .padding(6).background(.black.opacity(0.6), in: Circle()).padding(6)
                        }
                    }
                Text(game.title.isEmpty ? game.titleId : game.title)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
                Text(game.titleId).font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("game-\(game.titleId)")
        .overlay { focusRing(game.titleId, radius: 22) }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            openActions(game)
        })
        .id(game.titleId)
    }

    private func gameRow(_ game: CoreController.AppInfo) -> some View {
        Button { if !suppressTap { launch(game.titleId) } } label: {
            HStack(spacing: 14) {
                GameCover(titleID: game.titleId, cornerRadius: 12).frame(width: classicIcons ? 72 : 132)
                VStack(alignment: .leading, spacing: 5) {
                    Text(game.title.isEmpty ? game.titleId : game.title)
                        .font(.headline).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    Text(game.titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if favoriteIDs.contains(game.titleId) {
                    Image(systemName: "star.fill").font(.footnote).foregroundStyle(.yellow)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("game-\(game.titleId)")
        .overlay { focusRing(game.titleId, radius: 14) }
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            openActions(game)
        })
        .id(game.titleId)
    }
}


/// Shown when no game is installed yet: a short welcome and the first steps.
struct EmptyLibraryView: View {
    @Environment(\.palette) private var palette
    @Environment(\.verticalSizeClass) private var vSize
    let canImport: Bool
    let onImport: () -> Void

    private var compact: Bool { vSize == .compact }

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .center, spacing: 28) {
                    VStack(spacing: 14) { hero(size: 64); importButton }
                        .frame(maxWidth: 260)
                    steps
                }
                .padding(.vertical, 8).padding(.bottom, 72)
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 22) {
                    hero(size: 84)
                    steps
                    importButton
                }
                .padding(.top, 24).padding(.bottom, 100)
                .frame(maxWidth: 520).frame(maxWidth: .infinity)
            }
        }
    }

    private func hero(size: CGFloat) -> some View {
        VStack(spacing: 8) {
            Image("LogoMark").resizable().scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                .shadow(color: palette.accent.opacity(0.55), radius: 22)
            Text("Bem-vindo ao Flowyr").font(.system(size: compact ? 20 : 26, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Comece em três passos").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var steps: some View {
        VStack(spacing: 2) {
            step(1, "Instale o firmware", "Configurações → Sistema e conteúdo → Importar conteúdo.")
            step(2, "Importe seus jogos", "Arquivos VPK, ZIP, PKG e pastas são aceitos.")
            step(3, "Ative o JIT", "Abra o Flowyr pelo StikDebug com o script Universal.")
        }
        .padding(8)
        .background(palette.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var importButton: some View {
        Button(action: onImport) {
            Label("Importar jogo", systemImage: "square.and.arrow.down.fill")
                .font(.headline).padding(.horizontal, 22).padding(.vertical, 12)
                .background(palette.accent, in: Capsule()).foregroundStyle(palette.background)
        }
        .buttonStyle(.plain).disabled(!canImport).opacity(canImport ? 1 : 0.5)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(.system(size: 14, weight: .heavy, design: .rounded))
                .frame(width: 28, height: 28).background(palette.accent.opacity(0.9), in: Circle()).foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
