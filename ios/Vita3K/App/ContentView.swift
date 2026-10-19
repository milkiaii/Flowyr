// Vita3K iOS — library, settings and launch coordination.
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var controller: CoreController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(EmulatorTheme.lightModePreference) private var lightMode = false
    @State private var surfaceRequest: SurfaceRequest?
    @State private var showImporter = false
    @State private var launchInFlight = false
    @State private var startupComplete = false
    @State private var wasAway = false
    @State private var launchError: String?

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView(launch: launch, importContent: { showImporter = true })
            }
            .tabItem { Label("Biblioteca", systemImage: "square.grid.2x2.fill") }
            NavigationStack {
                SettingsView(importContent: { showImporter = true })
            }
            .tabItem { Label("Opções", systemImage: "slider.horizontal.3") }
        }
        .disabled(controller.isImporting || controller.isDeleting || controller.isSyncingSaves || launchInFlight)
        .task {
            guard !startupComplete else { return }
            startupComplete = true
            // Start the JIT check first: it runs off the main thread, so it
            // overlaps with the (main-thread, SDL-bound) session init.
            let jit = Task { await controller.checkJIT() }
            // Let the first frame draw before the main thread blocks in init.
            try? await Task.sleep(for: .milliseconds(80))
            controller.runSessionInit()
            _ = await jit.value
            // The launch sync is armed by CloudSaveSync (needsSync) and run
            // once by the control poller; an explicit call here would sync
            // again right after the JIT check.
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                wasAway = true
            case .active:
                // The cold-start activation must not re-arm the launch sync.
                guard wasAway, startupComplete, surfaceRequest == nil else { return }
                wasAway = false
                controller.saveSync.requestSync()
                Task { _ = await controller.checkJIT() }
            @unknown default:
                break
            }
        }
        .onChange(of: controller.autoBootTitle) { _, title in
            guard let title else { return }
            controller.autoBootTitle = nil
            bootWhenReady(title)
        }
        .onChange(of: controller.ctlNextTitle) { _, next in
            guard let next else { return }
            controller.ctlNextTitle = nil
            surfaceRequest = nil
            guard !next.isEmpty else { return }
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                bootWhenReady(next)
            }
        }
        .alert("Abra pelo StikDebug", isPresented: $controller.showJITAlert) {
            Button("Verificar novamente") { Task { _ = await controller.checkJIT() } }
            Button("Continuar na biblioteca", role: .cancel) {}
        } message: {
            Text("O JIT não está disponível nesta sessão. Abra o StikDebug, selecione o script Universal e inicie o Veeb por ele. Você pode organizar sua biblioteca sem JIT, mas precisa ativá-lo para jogar.")
        }
        .alert("Não foi possível abrir o jogo", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: { Text(launchError ?? "") }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .item, .zip,
                        UTType(filenameExtension: "vpk") ?? .item,
                        UTType(filenameExtension: "pkg") ?? .item,
                        UTType(filenameExtension: "pup") ?? .item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { controller.importFile(url) }
            case .failure(let error):
                controller.reportImportFailure(error.localizedDescription)
            }
        }
        .sheet(item: Binding(
            get: { canPresentImportResult ? controller.importResult : nil },
            set: { if canPresentImportResult { controller.importResult = $0 } }
        )) { result in
            NavigationStack {
                ScrollView {
                    Text(result.message)
                        .font(.callout.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .background(EmulatorTheme.background)
                .navigationTitle(LocalizedStringKey(result.succeeded ? "Importação concluída" : "Falha na importação"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Concluir") { controller.importResult = nil } }
            }
            .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $surfaceRequest, onDismiss: {
            controller.isGamePresented = false
            controller.refreshApps()
            // The poller waits for native teardown before reading any saves.
            controller.saveSync.requestSync()
        }) { request in
            EmulationSurfaceView(appPath: request.appPath) { surfaceRequest = nil }
                .ignoresSafeArea()
        }
        .overlay {
            if controller.isImporting || controller.isDeleting || controller.isSyncingSaves || launchInFlight {
                VStack(spacing: 12) {
                    ProgressView().tint(EmulatorTheme.accent)
                    Text(LocalizedStringKey(controller.isDeleting ? "Apagando jogo…" : (controller.isImporting ? "Importando conteúdo…" : (controller.isSyncingSaves ? "Sincronizando saves…" : "Preparando o jogo…"))))
                        .font(.subheadline.weight(.medium))
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("operation-progress")
            }
        }
        .tint(EmulatorTheme.accent)
        .preferredColorScheme(lightMode ? .light : .dark)
    }

    private var canPresentImportResult: Bool {
        !showImporter && !controller.isImporting && !controller.showJITAlert && surfaceRequest == nil
    }

    private func launch(_ title: String) {
        guard !launchInFlight, !controller.isImporting, !controller.isDeleting, !controller.memRunning,
              !controller.isSyncingSaves, !controller.isPreparingGame, !controller.isGamePresented,
              surfaceRequest == nil, controller.sessionInitialized else { return }
        launchInFlight = true
        controller.isPreparingGame = true
        Task {
            defer { launchInFlight = false; controller.isPreparingGame = false }
            guard await controller.checkJIT() else { return }
            await controller.syncSaves(beforeLaunch: true)
            if controller.saveSync.enabled, !controller.saveSync.conflicts.isEmpty {
                launchError = L10n.text("Há saves com versões diferentes. Abra Opções → Saves no iCloud e escolha o progresso que deseja usar.")
                return
            }
            guard !controller.isDeleting, !controller.isImporting else { return }
            guard controller.apps.contains(where: { $0.titleId == title }) else {
                launchError = L10n.text("Este jogo não está mais na biblioteca. Atualize a lista ou importe-o novamente.")
                return
            }
            guard scenePhase == .active else { return }
            controller.selectedAppTitleId = title
            UserDefaults.standard.set(title, forKey: "library.lastPlayed")
            controller.importResult = nil
            controller.isGamePresented = true
            surfaceRequest = SurfaceRequest(appPath: title)
        }
    }

    /// Host-driven boots use the same JIT gate as a tap on a game.
    private func bootWhenReady(_ title: String) {
        Task {
            let deadline = Date().addingTimeInterval(90)
            while Date() < deadline,
                  !controller.apps.contains(where: { $0.titleId == title }) || controller.isSyncingSaves
                    || controller.isImporting || controller.isDeleting || controller.isGamePresented {
                try? await Task.sleep(for: .seconds(1))
            }
            let marker = URL(fileURLWithPath: controller.basePath).appendingPathComponent("imports/boot-delay.txt")
            let raw = ProcessInfo.processInfo.environment["VITA3K_BOOT_DELAY"]
                ?? (try? String(contentsOf: marker, encoding: .utf8)) ?? "0"
            if let delay = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            launch(title)
        }
    }
}

struct SurfaceRequest: Identifiable {
    let id = UUID()
    let appPath: String?
}
