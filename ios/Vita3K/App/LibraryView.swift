import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var controller: CoreController
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale
    let launch: (String) -> Void
    let importContent: () -> Void
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: verticalSizeClass == .compact ? 12 : 24) {
                header
                if let recent = controller.apps.first(where: { $0.titleId == lastPlayed }), search.isEmpty, !favoritesOnly, verticalSizeClass != .compact {
                    Button { launch(recent.titleId) } label: {
                        HStack(spacing: 16) {
                            GameArtwork(titleID: recent.titleId).frame(width: 70, height: 70)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("JOGADO RECENTEMENTE").font(.caption2.weight(.bold)).tracking(1.4).foregroundStyle(EmulatorTheme.accent)
                                Text(recent.title).font(.headline).lineLimit(2).foregroundStyle(.primary)
                                Text("Jogar novamente").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.circle.fill").font(.title).foregroundStyle(EmulatorTheme.accent)
                        }
                        .padding(16).background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 22))
                    }.buttonStyle(.plain)
                        .contextMenu { deleteAction(recent) }
                }
                HStack {
                    Picker("Filtro da biblioteca", selection: $favoritesOnly) {
                        Text("Todos").tag(false)
                        Text("Favoritos").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 280)
                    Spacer(minLength: 8)
                    Button { listLayout.toggle() } label: {
                        Image(systemName: listLayout ? "square.grid.2x2" : "list.bullet").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text(LocalizedStringKey(listLayout ? "Exibir em grade" : "Exibir em lista")))
                }
                if games.isEmpty {
                    ContentUnavailableView {
                        Label(LocalizedStringKey(controller.apps.isEmpty ? "Sua próxima aventura" : "Nenhum jogo encontrado"),
                              systemImage: controller.apps.isEmpty ? "gamecontroller" : "magnifyingglass")
                    } description: {
                        Text(LocalizedStringKey(controller.apps.isEmpty ? "Importe seus jogos e homebrews para começar. Arquivos VPK, ZIP, PKG e pastas são aceitos." : "Tente outra busca ou veja todos os jogos."))
                    } actions: {
                        if controller.apps.isEmpty {
                            Button("Importar jogo", action: importContent).buttonStyle(.borderedProminent)
                                .disabled(!controller.sessionInitialized || controller.isImporting)
                        }
                    }
                } else if listLayout {
                    LazyVStack(spacing: 12) { ForEach(games) { game in gameRow(game) } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 18)], alignment: .leading, spacing: 24) {
                        ForEach(games) { game in gameTile(game) }
                    }
                }
            }
            .padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
        }
        .background(EmulatorTheme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            if controller.loggingMode != .off {
                LoggingModeBanner(mode: controller.loggingMode)
            }
        }
        .navigationTitle("Veeb-SE").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Buscar jogo ou título ID")
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
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Image(systemName: "gamecontroller.fill").foregroundStyle(EmulatorTheme.accent)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: importContent) { Label("Importar", systemImage: "plus") }
                    .disabled(!controller.sessionInitialized || controller.isImporting)
                    .accessibilityIdentifier("import-content")
            }
        }
        .refreshable { controller.refreshApps() }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) { heading; Spacer(); jitButton }
            VStack(alignment: .leading, spacing: 12) { heading; jitButton }
        }
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            if verticalSizeClass != .compact {
                Text("Sua biblioteca").font(.largeTitle.bold())
            }
            Text(L10n.installedGames(controller.apps.count, language: AppLanguage(rawValue: locale.identifier) ?? .english))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
    private var jitButton: some View {
        Button { Task { _ = await controller.checkJIT() } } label: { JITBadge(status: controller.jitStatus) }
            .buttonStyle(.plain).disabled(controller.jitStatus == .checking)
    }
    private func gameTile(_ game: CoreController.AppInfo) -> some View {
        Button { launch(game.titleId) } label: {
            VStack(alignment: .leading, spacing: 10) {
                GameArtwork(titleID: game.titleId).overlay(alignment: .topTrailing) {
                    if favoriteIDs.contains(game.titleId) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                            .padding(8).background(.black.opacity(0.7), in: Circle()).padding(8)
                    }
                }
                Text(game.title.isEmpty ? game.titleId : game.title).font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary).lineLimit(2).frame(height: 40, alignment: .topLeading)
                Text(game.titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("game-\(game.titleId)")
        .contextMenu {
            favoriteAction(game)
            Button { configGame = game } label: {
                Label("Editar Config", systemImage: "slider.horizontal.3")
            }.accessibilityIdentifier("edit-config")
            deleteAction(game)
        }
    }

    private func gameRow(_ game: CoreController.AppInfo) -> some View {
        Button { launch(game.titleId) } label: {
            HStack(spacing: 16) {
                GameArtwork(titleID: game.titleId).frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(game.title).font(.headline).foregroundStyle(.primary)
                    Text(game.titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: favoriteIDs.contains(game.titleId) ? "star.fill" : "play.fill").foregroundStyle(EmulatorTheme.accent)
            }.padding(14).background(EmulatorTheme.panel, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain).accessibilityIdentifier("game-\(game.titleId)")
        .contextMenu {
            favoriteAction(game)
            Button { configGame = game } label: {
                Label("Editar Config", systemImage: "slider.horizontal.3")
            }.accessibilityIdentifier("edit-config-row")
            deleteAction(game)
        }
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
