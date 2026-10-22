import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var controller: CoreController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale
    let launch: (String) -> Void
    let importContent: () -> Void
    let openSettings: () -> Void
    @ObservedObject private var deviceStatus = DeviceStatus.shared
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
            EmulatorTheme.background.ignoresSafeArea()
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
                onImport: importContent,
                onSettings: openSettings
            )
            .padding(.bottom, 10)
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
                    ContentUnavailableView {
                        Label(LocalizedStringKey(controller.apps.isEmpty ? "Sua próxima aventura" : "Nenhum jogo encontrado"),
                              systemImage: controller.apps.isEmpty ? "gamecontroller" : "magnifyingglass")
                    } description: {
                        Text(LocalizedStringKey(controller.apps.isEmpty ? "Importe seus jogos e homebrews para começar. Arquivos VPK, ZIP, PKG e pastas são aceitos." : "Tente outra busca ou veja todos os jogos."))
                    } actions: {
                        if controller.apps.isEmpty {
                            Button("Importar jogo", action: importContent)
                                .buttonStyle(.bordered)
                                .disabled(!controller.sessionInitialized || controller.isImporting)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
                .padding(.horizontal, 16)
            }
            .refreshable { controller.refreshApps() }
        } else if showsCarousel {
            GameCarousel(games: games, initialID: lastPlayed, onLaunch: launch) { game in
                gameMenu(game)
            }
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
            .background(EmulatorTheme.panel, in: Capsule())
            Button { favoritesOnly.toggle() } label: {
                Image(systemName: favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(EmulatorTheme.panel, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Favoritos"))
        }
    }

    private var listContent: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                searchHeader.padding(.bottom, 8)
                ForEach(games) { game in
                    gameRow(game)
                    Divider()
                }
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { controller.refreshApps() }
    }

    private var gridContent: some View {
        ScrollView {
            VStack(spacing: 14) {
                searchHeader
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 280), spacing: 14)], spacing: 14) {
                    ForEach(games) { game in gameTile(game) }
                }
            }
            .padding(.horizontal, 16)
        }
        .contentMargins(.bottom, 96, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .refreshable { controller.refreshApps() }
    }

    @ViewBuilder
    private func gameMenu(_ game: CoreController.AppInfo) -> some View {
        favoriteAction(game)
        Button { configGame = game } label: {
            Label("Editar Config", systemImage: "slider.horizontal.3")
        }.accessibilityIdentifier("edit-config")
        deleteAction(game)
    }

    private func gameTile(_ game: CoreController.AppInfo) -> some View {
        Button { launch(game.titleId) } label: {
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
            .background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("game-\(game.titleId)")
        .contextMenu { gameMenu(game) }
    }

    private func gameRow(_ game: CoreController.AppInfo) -> some View {
        Button { launch(game.titleId) } label: {
            HStack(spacing: 14) {
                GameCover(titleID: game.titleId, cornerRadius: 12).frame(width: 132)
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
        .contextMenu { gameMenu(game) }
    }

    private func deleteAction(_ game: CoreController.AppInfo) -> some View {
        Button(role: .destructive) { deleteGame = game } label: {
            Label("Apagar jogo", systemImage: "trash")
        }
        .disabled(!controller.canDeleteGame)
        .accessibilityIdentifier("delete-game")
    }

    private func favoriteAction(_ game: CoreController.AppInfo) -> some View {
        Button {
            var ids = favoriteIDs
            if ids.contains(game.titleId) { ids.remove(game.titleId) } else { ids.insert(game.titleId) }
            favorites = ids.sorted().joined(separator: ",")
        } label: {
            Label(LocalizedStringKey(favoriteIDs.contains(game.titleId) ? "Remover dos favoritos" : "Adicionar aos favoritos"), systemImage: "star")
        }
    }
}
