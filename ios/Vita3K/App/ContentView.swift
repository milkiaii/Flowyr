// Vita3K iOS — library, settings and launch coordination.
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.palette) private var palette
    @EnvironmentObject var controller: CoreController
    @Environment(\.scenePhase) private var scenePhase
    @State private var surfaceRequest: SurfaceRequest?
    @State private var showImporter = false
    @State private var importKind: ImportKind = .game
    @State private var showZRIF = false
    @State private var zrifText = ""
    @State private var showSettings = false
    @ObservedObject private var pad = GamepadInput.shared
    @State private var launchInFlight = false
    @State private var startupComplete = false
    @State private var showIntro = true
    @State private var wasAway = false
    @State private var launchError: String?
    @State private var toast: String?

    var body: some View {
        LibraryView(launch: launch, importContent: { kind in importKind = kind; showImporter = true },
                    enterZRIF: { zrifText = ""; showZRIF = true },
                    openSettings: { UISounds.shared.play(.open); showSettings = true },
                    inputEnabled: surfaceRequest == nil && !showSettings && !showImporter && !showZRIF && !launchInFlight)
        .disabled(controller.isImporting || controller.isDeleting || controller.isSyncingSaves || launchInFlight)
        .overlay {
            if showIntro {
                StartupIntro(jitStatus: controller.jitStatus)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .task {
            guard !startupComplete else { return }
            startupComplete = true
            let introStart = Date()
            // Start the JIT check first: it runs off the main thread, so it
            // overlaps with the (main-thread, SDL-bound) session init.
            let jit = Task { await controller.checkJIT() }
            // Let the first frame draw before the main thread blocks in init.
            try? await Task.sleep(for: .milliseconds(80))
            controller.runSessionInit()
            _ = await jit.value
            // Keep the intro up for a beat so it never flashes, then reveal the library.
            let remaining = 1.3 - Date().timeIntervalSince(introStart)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            withAnimation(.easeInOut(duration: 0.45)) { showIntro = false }
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
            Text("O JIT não está disponível nesta sessão. Abra o StikDebug, selecione o script Universal e inicie o Flowyr por ele. Você pode organizar sua biblioteca sem JIT, mas precisa ativá-lo para jogar.")
        }
        .alert("Não foi possível abrir o jogo", isPresented: Binding(
            get: { launchError != nil }, set: { if !$0 { launchError = nil } }
        )) {
            Button("OK", role: .cancel) { launchError = nil }
        } message: { Text(launchError ?? "") }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(importContent: {
                    showSettings = false
                    importKind = .game
                    showImporter = true
                }, onClose: { showSettings = false })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("OK") { UISounds.shared.play(.back); showSettings = false }
                            .accessibilityIdentifier("settings-done")
                    }
                }
            }
            .environmentObject(controller)
            .appTheme()
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { controller.importFile(url) }
            case .failure(let error):
                controller.reportImportFailure(error.localizedDescription)
            }
        }
        .alert("Chave zRIF", isPresented: $showZRIF) {
            TextField("Chave zRIF", text: $zrifText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Cancelar", role: .cancel) {}
            Button("Instalar") { controller.importZRIF(zrifText) }
        } message: {
            Text("Cole a chave zRIF do jogo. Ela será salva como licença.")
        }
        .alert("Falha na importação", isPresented: Binding(
            get: { canPresentImportResult && controller.importResult?.succeeded == false },
            set: { if !$0 { controller.importResult = nil } }
        )) {
            Button("OK", role: .cancel) { controller.importResult = nil }
        } message: { Text(controller.importResult?.message ?? "") }
        .onChange(of: controller.importResult?.id) { _, _ in showImportToast() }
        .onChange(of: canPresentImportResult) { _, _ in showImportToast() }
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
                    .padding(.bottom, 92)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityIdentifier("import-toast")
            }
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
                    ProgressView().tint(palette.accent)
                    Text(LocalizedStringKey(controller.isDeleting ? "Apagando jogo…" : (controller.isImporting ? "Importando conteúdo…" : (controller.isSyncingSaves ? "Sincronizando saves…" : "Preparando o jogo…"))))
                        .font(.subheadline.weight(.medium))
                }
                .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
                .accessibilityIdentifier("operation-progress")
            }
        }
        .appTheme()
    }

    /// File picker filter for the chosen "+" menu entry.
    private var importTypes: [UTType] {
        switch importKind {
        case .game:
            [.folder, .item, .zip,
             UTType(filenameExtension: "vpk") ?? .item,
             UTType(filenameExtension: "pkg") ?? .item]
        case .license:
            // work.bin / .rif have no registered type.
            [.item]
        case .firmware:
            [UTType(filenameExtension: "pup") ?? .item]
        }
    }

    private func showImportToast() {
        guard canPresentImportResult, let result = controller.importResult, result.succeeded else { return }
        UISounds.shared.play(.confirm)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = result.message }
        controller.importResult = nil
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            withAnimation(.easeOut(duration: 0.25)) { toast = nil }
        }
    }

    private var canPresentImportResult: Bool {
        !showImporter && !controller.isImporting && !controller.showJITAlert && surfaceRequest == nil
    }

    private func launch(_ title: String) {
        guard !launchInFlight, !controller.isImporting, !controller.isDeleting, !controller.memRunning,
              !controller.isSyncingSaves, !controller.isPreparingGame, !controller.isGamePresented,
              surfaceRequest == nil, controller.sessionInitialized else { return }
        UISounds.shared.play(.confirm)
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


/// Launch screen shown while the JIT check and core initialisation run. It only uses
/// Core Animation driven effects (opacity, scale, offset), which keep running even
/// while the main thread is busy initialising the core.
struct StartupIntro: View {
    @Environment(\.palette) private var palette
    let jitStatus: CoreController.JITStatus
    @State private var appeared = false
    @State private var glow = false
    @State private var sweep = false

    var body: some View {
        ZStack {
            ThemedBackground()
            VStack(spacing: 26) {
                Image("LogoMark")
                    .resizable().scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                    .shadow(color: palette.accent.opacity(glow ? 0.75 : 0.3), radius: glow ? 34 : 16)
                    .scaleEffect(appeared ? 1 : 0.82)
                Text(verbatim: "FLOWYR")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .tracking(8).padding(.leading, 8)
                    .foregroundStyle(.white.opacity(0.92))
                    .opacity(appeared ? 1 : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule().fill(jitStatus == .unavailable ? palette.warning : .white.opacity(0.9))
                        .frame(width: 36)
                        .offset(x: sweep ? 84 : 0)
                        .opacity(jitStatus == .checking ? 1 : 0)
                }
                .frame(width: 120, height: 3).clipShape(Capsule())
                .overlay {
                    Capsule().fill(jitStatus == .ready ? Color.green : palette.warning)
                        .opacity(jitStatus == .checking ? 0 : 1)
                }
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: jitStatus)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
        }
        .accessibilityHidden(true)
    }
}
