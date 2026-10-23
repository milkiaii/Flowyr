import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: CoreController
    let importContent: () -> Void
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.sortByID") private var sortByID = false
    @AppStorage("emulation.showControls") private var showControls = true
    @AppStorage("emulation.controlOpacity") private var controlOpacity = 0.8
    @AppStorage("emulation.showStatus") private var showStatus = false
    @AppStorage(AppOrientation.preference) private var forceLandscape = false
    @AppStorage(EmulatorTheme.lightModePreference) private var lightMode = false
    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @AppStorage(UISounds.preference) private var uiSounds = true
    @AppStorage(AppLanguage.preference) private var language = AppLanguage.english.rawValue

    @State private var showDiagnostics = false
    var onClose: () -> Void = {}

    private var languageIndex: Binding<Int> {
        Binding(get: { AppLanguage.allCases.firstIndex { $0.rawValue == language } ?? 0 },
                set: { language = AppLanguage.allCases[$0].rawValue })
    }

    var body: some View {
        PadSettingsPage(sections: sections, isActive: !showDiagnostics, onClose: onClose)
            .navigationTitle("Opções").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView() }
    }

    private var sections: [SettingSection] {
        let sync = controller.saveSync
        var cloud: [SettingItem] = [
            SettingItem(id: "cloud-enabled", title: "Sincronizar todos os saves", symbol: "icloud.fill",
                        kind: .toggle(Binding(get: { sync.enabled },
                                              set: { sync.setEnabled($0); Task { await controller.syncSaves() } })),
                        enabled: !controller.isSyncingSaves)
        ]
        if sync.enabled {
            cloud.append(SettingItem(id: "cloud-now", title: "Sincronizar agora", symbol: "arrow.triangle.2.circlepath",
                                     kind: .action { sync.requestSync(); Task { await controller.syncSaves() } },
                                     enabled: !controller.isSyncingSaves))
            for conflict in sync.conflicts {
                if conflict.localDigest != nil {
                    cloud.append(SettingItem(id: "conflict-\(conflict.id)-local", title: "Usar save deste aparelho",
                                             detail: LocalizedStringKey("\(conflict.key.game) · Usuário \(conflict.key.user)"),
                                             kind: .action { resolve(conflict, revision: nil) }))
                }
                for version in conflict.versions {
                    cloud.append(SettingItem(id: "conflict-\(conflict.id)-\(version.id)",
                                             title: LocalizedStringKey("Usar iCloud · \(version.device)"),
                                             detail: LocalizedStringKey("\(conflict.key.game) · \(version.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))"),
                                             kind: .action { resolve(conflict, revision: version.id) }))
                }
            }
        }
        cloud.append(SettingItem(id: "cloud-status", title: LocalizedStringKey(sync.status), kind: .info("")))

        return [
            SettingSection(id: "language", title: "Idioma", items: [
                SettingItem(id: "language", title: "Idioma da interface", symbol: "globe",
                            kind: .choice(languageIndex, AppLanguage.allCases.map(\.name)))
            ], footer: "A alteração é aplicada imediatamente e fica salva para a próxima abertura. O idioma dos jogos não é alterado."),
            SettingSection(id: "appearance", title: "Aparência", items: [
                SettingItem(id: "light", title: "Tema claro", symbol: "sun.max.fill", kind: .toggle($lightMode)),
                SettingItem(id: "sounds", title: "Sons da interface", symbol: "speaker.wave.2.fill", kind: .toggle($uiSounds)),
                SettingItem(id: "icons", title: "Ícones dos jogos", detail: "Arte larga usa a imagem de fundo do jogo. Ícone clássico usa o ícone quadrado do jogo.",
                            symbol: "square.grid.2x2.fill",
                            kind: .choice(Binding(get: { classicIcons ? 1 : 0 }, set: { classicIcons = $0 == 1 }),
                                          [L10n.text("Arte larga"), L10n.text("Ícone clássico")])),
            ]),
            SettingSection(id: "jit", title: "Pronto para jogar", items: [
                SettingItem(id: "jit-check", title: "Verificar JIT agora", symbol: "bolt.fill",
                            kind: .action { Task { _ = await controller.checkJIT() } },
                            enabled: controller.jitStatus != .checking)
            ], footer: "No iPhone, abra o Veeb pelo StikDebug usando o script Universal. A disponibilidade do JIT é verificada ao abrir o app e antes de iniciar um jogo.",
                           accessory: AnyView(JITBadge(status: controller.jitStatus))),
            SettingSection(id: "controls", title: "Controles e tela", items: [
                SettingItem(id: "landscape", title: "Forçar rotacionamento na horizontal", symbol: "rotate.right.fill",
                            detail: "Mantém a interface e os jogos na horizontal, mesmo com o aparelho em pé.", kind: .toggle($forceLandscape)),
                SettingItem(id: "controls", title: "Controles na tela", symbol: "gamecontroller.fill",
                            detail: "Ocultados automaticamente ao conectar um controle físico.", kind: .toggle($showControls)),
                SettingItem(id: "opacity", title: "Opacidade", kind: .slider($controlOpacity, 0.25...1, 0.05, "%"), enabled: showControls),
                SettingItem(id: "overlay", title: "Performance Overlay", symbol: "speedometer",
                            detail: "FPS, tempo por quadro e memória.", kind: .toggle($showStatus)),
            ]),
            SettingSection(id: "library", title: "Biblioteca", items: [
                SettingItem(id: "list", title: "Exibir como lista", symbol: "list.bullet", kind: .toggle($listLayout)),
                SettingItem(id: "sort", title: "Ordenar por título ID", symbol: "textformat.abc", kind: .toggle($sortByID)),
                SettingItem(id: "refresh", title: "Atualizar jogos instalados", symbol: "arrow.clockwise",
                            kind: .action { controller.refreshApps() }),
            ], footer: "Mantenha um jogo pressionado para adicioná-lo aos favoritos."),
            SettingSection(id: "cloud", title: "Saves no iCloud", items: cloud,
                           footer: "Sincroniza o progresso de todos os jogos entre aparelhos com a mesma conta do iCloud. Encerre o jogo e aguarde o envio antes de trocar de aparelho."),
            SettingSection(id: "system", title: "Sistema e conteúdo", items: [
                SettingItem(id: "audio", title: "Áudio", kind: .info("SDL · CoreAudio")),
                SettingItem(id: "gfx", title: "Gráficos", kind: .info("Vulkan · MoltenVK")),
                SettingItem(id: "firmware", title: "Firmware",
                            kind: .info(L10n.text(controller.firmwareMask == 7 ? "Instalado" : "Incompleto"))),
                SettingItem(id: "import", title: "Importar conteúdo", symbol: "square.and.arrow.down",
                            kind: .action(importContent), enabled: !controller.isImporting && controller.sessionInitialized),
            ], footer: "Importe firmware PUP ou conteúdo de jogos VPK, ZIP, PKG e pastas. Ou use o app Arquivos: abra “No Meu iPhone” → “Veeb” — copie jogos para imports/ (instalados automaticamente) ou remova arquivos, ex. um jogo em vita/ux0/app."),
            SettingSection(id: "about", title: "Sobre o Veeb", items: [
                SettingItem(id: "core", title: "Núcleo", kind: .info(controller.version.isEmpty ? L10n.text("Carregando…") : controller.version)),
                SettingItem(id: "diagnostics", title: "Diagnóstico avançado", symbol: "waveform.path.ecg",
                            kind: .action { showDiagnostics = true }),
            ], footer: "Vita is for Weebs · Emulador experimental de PlayStation Vita para iOS. Compatibilidade e desempenho variam por jogo."),
        ]
    }

    private func resolve(_ conflict: SaveConflict, revision: UUID?) {
        Task { await controller.syncSaves(resolution: SaveResolution(conflict: conflict, revision: revision)) }
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var controller: CoreController
    @State private var jitDetails = ""
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var pad = GamepadInput.shared
    @State private var padOwner = UUID()
    private var busy: Bool { controller.jitStatus == .checking || controller.memRunning || controller.phase == .running || controller.isImporting }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                EmulatorCard(title: "Ferramentas de desenvolvimento") {
                    Text("Estes testes são opcionais. Não são necessários para abrir jogos e devem ser executados sem uma sessão ativa.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { testButtons }
                        VStack(alignment: .leading, spacing: 12) { testButtons }
                    }.buttonStyle(.bordered).disabled(busy)
                }
                reportCard("JIT", jitDetails)
                reportCard("Teste do núcleo", controller.report.isEmpty ? controller.failure : controller.report)
                reportCard("Memória", controller.memReport)
                reportCard("Log", controller.log)
            }.padding(20).frame(maxWidth: 1000).frame(maxWidth: .infinity)
        }
        .background(EmulatorTheme.background)
        .navigationTitle("Diagnóstico").navigationBarTitleDisplayMode(.inline)
        .onAppear { pad.start(owner: padOwner) }
        .onDisappear { pad.stop(owner: padOwner) }
        .onChange(of: pad.lastEvent) { _, event in
            if event?.button == .back { UISounds.shared.play(.back); dismiss() }
        }
    }

    @ViewBuilder private var testButtons: some View {
        Button("Núcleo") { controller.runSelfTest() }
        Button("Estado do JIT") { jitDetails = controller.jitReport }
        Button("Memória") { controller.runMemoryTest() }.disabled(controller.jitStatus != .ready)
    }

    @ViewBuilder private func reportCard(_ title: LocalizedStringKey, _ report: String) -> some View {
        if !report.isEmpty {
            EmulatorCard(title: title) {
                Text(report).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
