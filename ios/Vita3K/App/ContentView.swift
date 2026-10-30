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
    @State private var wasAway = false
    @State private var launchError: String?
    @State private var toast: String?

    var body: some View {
        LibraryView(launch: launch, importContent: { kind in importKind = kind; showImporter = true },
                    enterZRIF: { zrifText = ""; showZRIF = true },
                    openSettings: { UISounds.shared.play(.open); showSettings = true },
                    inputEnabled: surfaceRequest == nil && !showSettings && !showImporter && !showZRIF && !launchInFlight)
        .disabled(controller.isImporting || controller.isDeleting || controller.isSyncingSaves || launchInFlight)
        .task {
            guard !startupComplete else { return }
            startupComplete = true
            let introStart = Date()
            // UIKit splash: its Core Animation layers keep animating on the render
            // server even while the main thread is blocked by core init / JIT.
            SplashWindow.shared.show()
            // Start the JIT check first: it runs off the main thread, so it
            // overlaps with the (main-thread, SDL-bound) session init.
            let jit = Task { await controller.checkJIT() }
            // Let the first frame draw before the main thread blocks in init.
            try? await Task.sleep(for: .milliseconds(80))
            controller.runSessionInit()
            let jitReady = await jit.value
            // Keep the intro up for a beat so it never flashes, then reveal the library.
            let remaining = 1.3 - Date().timeIntervalSince(introStart)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            SplashWindow.shared.finish(jitReady: jitReady)
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


/// Launch splash shown in its own window above everything. Built from CALayers so the
/// animations are driven by the render server and never stall with the main thread.
@MainActor
final class SplashWindow {
    static let shared = SplashWindow()
    private var window: UIWindow?
    private let sweep = CALayer()
    private let track = CALayer()

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let controller = SplashController(track: track, sweep: sweep)
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.rootViewController = controller
        w.isHidden = false
        window = w
    }

    func finish(jitReady: Bool) {
        guard let w = window else { return }
        sweep.removeAllAnimations()
        track.backgroundColor = (jitReady ? UIColor.systemGreen : UIColor(red: 1, green: 0.54, blue: 0.5, alpha: 1)).cgColor
        sweep.opacity = 0
        UIView.animate(withDuration: 0.45, delay: 0.15, options: .curveEaseInOut) {
            w.alpha = 0
        } completion: { _ in
            w.isHidden = true
            self.window = nil
        }
    }
}

private final class SplashController: UIViewController {
    private let track: CALayer
    private let sweep: CALayer
    private let gradient = CAGradientLayer()

    init(track: CALayer, sweep: CALayer) {
        self.track = track
        self.sweep = sweep
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Fixed Flowyr colors, independent of the selected theme.
        gradient.colors = [UIColor(red: 0x2A / 255, green: 0x22 / 255, blue: 0x84 / 255, alpha: 1).cgColor,
                           UIColor(red: 0x56 / 255, green: 0x48 / 255, blue: 0xC2 / 255, alpha: 1).cgColor,
                           UIColor(red: 0x9C / 255, green: 0x8E / 255, blue: 0xE8 / 255, alpha: 1).cgColor]
        view.layer.addSublayer(gradient)

        let logo = UIImageView(image: UIImage(named: "LogoMark"))
        logo.contentMode = .scaleAspectFit
        logo.layer.cornerRadius = 23
        logo.layer.cornerCurve = .continuous
        logo.clipsToBounds = true
        let glowHost = UIView()
        glowHost.layer.shadowColor = UIColor(red: 0xDA / 255, green: 0xD3 / 255, blue: 0xFF / 255, alpha: 1).cgColor
        glowHost.layer.shadowOpacity = 0.5
        glowHost.layer.shadowRadius = 18
        glowHost.layer.shadowOffset = .zero
        glowHost.addSubview(logo)
        logo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logo.leadingAnchor.constraint(equalTo: glowHost.leadingAnchor), logo.trailingAnchor.constraint(equalTo: glowHost.trailingAnchor),
            logo.topAnchor.constraint(equalTo: glowHost.topAnchor), logo.bottomAnchor.constraint(equalTo: glowHost.bottomAnchor),
            glowHost.widthAnchor.constraint(equalToConstant: 96), glowHost.heightAnchor.constraint(equalToConstant: 96),
        ])
        glowHost.layer.shadowPath = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 96, height: 96), cornerRadius: 23).cgPath

        let glow = CABasicAnimation(keyPath: "shadowRadius")
        glow.fromValue = 14; glow.toValue = 34
        glow.duration = 1.6; glow.autoreverses = true; glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glowHost.layer.add(glow, forKey: "glow")
        let pop = CABasicAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.82; pop.toValue = 1; pop.duration = 0.6
        pop.timingFunction = CAMediaTimingFunction(name: .easeOut)
        glowHost.layer.add(pop, forKey: "pop")

        let label = UILabel()
        label.attributedText = NSAttributedString(string: "FLOWYR", attributes: [
            .font: UIFont.systemFont(ofSize: 20, weight: .semibold),
            .kern: 8, .foregroundColor: UIColor.white.withAlphaComponent(0.92)])

        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([bar.widthAnchor.constraint(equalToConstant: 120), bar.heightAnchor.constraint(equalToConstant: 3)])
        bar.layer.cornerRadius = 1.5
        bar.clipsToBounds = true
        track.frame = CGRect(x: 0, y: 0, width: 120, height: 3)
        track.backgroundColor = UIColor.white.withAlphaComponent(0.16).cgColor
        sweep.frame = CGRect(x: 0, y: 0, width: 36, height: 3)
        sweep.backgroundColor = UIColor.white.withAlphaComponent(0.9).cgColor
        sweep.cornerRadius = 1.5
        bar.layer.addSublayer(track)
        track.addSublayer(sweep)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = 18; move.toValue = 102
        move.duration = 0.9; move.autoreverses = true; move.repeatCount = .infinity
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(move, forKey: "sweep")

        let stack = UIStackView(arrangedSubviews: [glowHost, label, bar])
        stack.axis = .vertical; stack.alignment = .center; stack.spacing = 26
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradient.frame = view.bounds
    }
}
