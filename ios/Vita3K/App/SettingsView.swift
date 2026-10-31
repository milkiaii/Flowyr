import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var controller: CoreController
    let importContent: () -> Void
    @AppStorage("library.listLayout") private var listLayout = false
    @AppStorage("library.sortByID") private var sortByID = false
    @AppStorage("emulation.showControls") private var showControls = true
    @AppStorage("emulation.controlOpacity") private var controlOpacity = 0.8
    @AppStorage("emulation.showStatus") private var showStatus = false
    @AppStorage(VirtualGamepadView.dynamicSticksPreference) private var dynamicSticks = false
    @AppStorage(AppOrientation.preference) private var forceLandscape = false
    @AppStorage(EmulatorTheme.themePreference) private var themeRaw = ""
    @AppStorage(EmulatorTheme.lightModePreference) private var legacyLight = false
    private var themeIndex: Binding<Int> {
        Binding(get: { (AppTheme(rawValue: themeRaw) ?? (legacyLight ? .light : .flowyr)).index },
                set: { themeRaw = AppTheme.allCases[$0].rawValue })
    }
    @AppStorage(GameIconStyle.preference) private var classicIcons = false
    @AppStorage(UISounds.preference) private var uiSounds = true
    @AppStorage(Vita3KCore.lowMemoryPreference) private var lowMemory = false
    @AppStorage(Vita3KCore.titleProfilesPreference) private var titleProfiles = false
    @AppStorage(AppLanguage.preference) private var language = AppLanguage.english.rawValue

    @State private var showDiagnostics = false
    @State private var page: SettingsCategory?
    @State private var poppedAt = Date.distantPast
    var onClose: () -> Void = {}

    private var languageIndex: Binding<Int> {
        Binding(get: { AppLanguage.allCases.firstIndex { $0.rawValue == language } ?? 0 },
                set: { language = AppLanguage.allCases[$0].rawValue })
    }

    var body: some View {
        PadSettingsPage(sections: hubSections, isActive: page == nil && !showDiagnostics,
                        onClose: { if Date().timeIntervalSince(poppedAt) > 0.4 { onClose() } })
            .navigationTitle("Opções").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $page) { category in categoryPage(category) }
            .navigationDestination(isPresented: $showDiagnostics) { DiagnosticsView() }
    }

    // MARK: - Hub and category pages

    private var hubSections: [SettingSection] {
        func link(_ c: SettingsCategory) -> SettingItem {
            SettingItem(id: "cat-\(c.rawValue)", title: c.title, symbol: c.symbol,
                        kind: .action { page = c }, chevron: true)
        }
        return [
            SettingSection(id: "hub", title: "Configurações",
                           items: SettingsCategory.allCases.map(link),
                           footer: "CPU e Gráficos definem os padrões de todos os jogos. Para ajustar um único jogo, mantenha-o pressionado na biblioteca e escolha Editar Config."),
            SettingSection(id: "about", title: "Sobre o Flowyr", items: [
                SettingItem(id: "core", title: "Núcleo", kind: .info(controller.version.isEmpty ? L10n.text("Carregando…") : controller.version)),
                SettingItem(id: "diagnostics", title: "Diagnóstico avançado", symbol: "waveform.path.ecg",
                            kind: .action { showDiagnostics = true }, chevron: true),
            ], footer: "Emulador experimental de PlayStation Vita para iOS. Compatibilidade e desempenho variam por jogo."),
        ]
    }

    /// B on a category page returns to the list; the same press must not also close the list.
    private func closeCategory() { poppedAt = Date(); page = nil }

    @ViewBuilder private func categoryPage(_ category: SettingsCategory) -> some View {
        switch category {
        case .cpu:
            GlobalConfigPage(scope: .cpu, onClose: closeCategory)
        case .graphics:
            GlobalConfigPage(scope: .graphics, onClose: closeCategory)
        default:
            let ids: [String] = switch category {
            case .interface: ["language", "appearance", "library"]
            case .controls: ["controls"]
            case .jit: ["jit"]
            default: ["memory", "system", "cloud"]
            }
            let all = sections
            PadSettingsPage(sections: ids.compactMap { id in all.first { $0.id == id } }, onClose: closeCategory)
                .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
        }
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
                SettingItem(id: "light", title: "Tema", symbol: "paintpalette.fill",
                            kind: .choice(themeIndex, AppTheme.allCases.map { L10n.text($0.label) })),
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
            ], footer: "No iPhone, abra o Flowyr pelo StikDebug usando o script Universal. A disponibilidade do JIT é verificada ao abrir o app e antes de iniciar um jogo.",
                           accessory: AnyView(JITBadge(status: controller.jitStatus))),
            SettingSection(id: "controls", title: "Controles e tela", items: [
                SettingItem(id: "landscape", title: "Forçar rotacionamento na horizontal", detail: "Mantém a interface e os jogos na horizontal, mesmo com o aparelho em pé.", symbol: "rotate.right.fill", kind: .toggle($forceLandscape)),
                SettingItem(id: "controls", title: "Controles na tela", detail: "Ocultados automaticamente ao conectar um controle físico.", symbol: "gamecontroller.fill", kind: .toggle($showControls)),
                SettingItem(id: "dynamic", title: "Analógicos dinâmicos",
                            detail: "O analógico aparece onde você toca nas áreas livres da esquerda e da direita.", symbol: "hand.point.up.left.fill", kind: .toggle($dynamicSticks)),
                SettingItem(id: "opacity", title: "Opacidade", kind: .slider($controlOpacity, 0.25...1, 0.05, "%"), enabled: showControls),
                SettingItem(id: "overlay", title: "Performance Overlay", detail: "FPS, tempo por quadro e memória.", symbol: "speedometer", kind: .toggle($showStatus)),
            ]),
            SettingSection(id: "library", title: "Biblioteca", items: [
                SettingItem(id: "list", title: "Exibir como lista", symbol: "list.bullet", kind: .toggle($listLayout)),
                SettingItem(id: "sort", title: "Ordenar por título ID", symbol: "textformat.abc", kind: .toggle($sortByID)),
                SettingItem(id: "refresh", title: "Atualizar jogos instalados", symbol: "arrow.clockwise",
                            kind: .action { controller.refreshApps() }),
            ], footer: "Mantenha um jogo pressionado para adicioná-lo aos favoritos."),
            SettingSection(id: "cloud", title: "Saves no iCloud", items: cloud,
                           footer: "Sincroniza o progresso de todos os jogos entre aparelhos com a mesma conta do iCloud. Encerre o jogo e aguarde o envio antes de trocar de aparelho."),
            SettingSection(id: "memory", title: "Memória e perfis", items: [
                SettingItem(id: "low-memory", title: "Modo de pouca memória", symbol: "memorychip",
                            detail: "Reduz o cache de texturas e o libera quando o iOS avisa que falta memória. Evita travamentos em aparelhos com 3 GB, com possíveis engasgos.",
                            kind: .toggle(Binding(get: { lowMemory }, set: { lowMemory = $0; Vita3KCore.applyRuntimeOptions() }))),
                SettingItem(id: "profiles", title: "Perfis recomendados por jogo", symbol: "wand.and.stars",
                            detail: "Aplica ajustes prontos a jogos com problemas conhecidos (hoje: Gravity Rush limitado a 30 FPS com texturas reduzidas). Aplicado ao iniciar o jogo.",
                            kind: .toggle(Binding(get: { titleProfiles }, set: { titleProfiles = $0; Vita3KCore.applyRuntimeOptions() }))),
            ]),
            SettingSection(id: "system", title: "Sistema e conteúdo", items: [
                SettingItem(id: "audio", title: "Áudio", kind: .info("SDL · CoreAudio")),
                SettingItem(id: "gfx", title: "Gráficos", kind: .info("Vulkan · MoltenVK")),
                SettingItem(id: "firmware", title: "Firmware",
                            kind: .info(L10n.text(controller.firmwareMask == 7 ? "Instalado" : "Incompleto"))),
                SettingItem(id: "import", title: "Importar conteúdo", symbol: "square.and.arrow.down",
                            kind: .action(importContent), enabled: !controller.isImporting && controller.sessionInitialized),
            ], footer: "Importe firmware PUP ou conteúdo de jogos VPK, ZIP, PKG e pastas. Ou use o app Arquivos: abra “No Meu iPhone” → “Flowyr” — copie jogos para imports/ (instalados automaticamente) ou remova arquivos, ex. um jogo em vita/ux0/app."),
        ]
    }

    private func resolve(_ conflict: SaveConflict, revision: UUID?) {
        Task { await controller.syncSaves(resolution: SaveResolution(conflict: conflict, revision: revision)) }
    }
}

struct DiagnosticsView: View {
    @Environment(\.palette) private var palette
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
        .background { ThemedBackground() }
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


enum SettingsCategory: String, CaseIterable, Hashable, Identifiable {
    case interface, controls, cpu, graphics, system, jit
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .interface: "Interface"
        case .controls: "Controles e tela"
        case .cpu: "CPU"
        case .graphics: "Gráficos"
        case .system: "Sistema e conteúdo"
        case .jit: "Pronto para jogar"
        }
    }
    var symbol: String {
        switch self {
        case .interface: "paintpalette.fill"
        case .controls: "gamecontroller.fill"
        case .cpu: "cpu"
        case .graphics: "display"
        case .system: "externaldrive.fill"
        case .jit: "bolt.fill"
        }
    }
}

/// Global CPU / graphics defaults (the config games use unless they have their own).
struct GlobalConfigPage: View {
    enum Scope { case cpu, graphics }
    let scope: Scope
    var onClose: () -> Void

    @State private var values: [String: String] = [:]
    @State private var loaded = false
    @State private var message = ""
    @State private var clearing = false

    private let resolutions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4]
    private let anisotropics: [Int] = [1, 2, 4, 8, 16]
    private let jitCacheSizes = Array(stride(from: 8, through: 32, by: 4))

    var body: some View {
        Group {
            if loaded {
                PadSettingsPage(sections: sections, status: message, onClose: onClose)
            } else {
                PadSettingsPage(sections: [], status: message, onClose: onClose)
            }
        }
        .navigationTitle(scope == .cpu ? "CPU" : "Gráficos").navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: load)
    }

    private func flag(_ id: String, _ title: LocalizedStringKey, _ key: String, detail: LocalizedStringKey? = nil) -> SettingItem {
        SettingItem(id: id, title: title, detail: detail, kind: .toggle(Binding(
            get: { values[key] == "1" },
            set: { if save(key, $0 ? "1" : "0") { values[key] = $0 ? "1" : "0" } })))
    }

    private func pick(_ id: String, _ title: LocalizedStringKey, _ key: String, current: Int, labels: [String],
                      raw: [String], detail: LocalizedStringKey? = nil) -> SettingItem {
        SettingItem(id: id, title: title, detail: detail, kind: .choice(Binding(
            get: { current },
            set: { if save(key, raw[$0]) { values[key] = raw[$0] } }), labels))
    }

    private var sections: [SettingSection] {
        let footer: LocalizedStringKey = "Padrões para todos os jogos. Jogos com config própria (Editar Config) mantêm os valores deles. Aplicados quando o jogo for (re)iniciado."
        switch scope {
        case .cpu:
            let current = Int(values["cpu_jit_cache_mib"] ?? "0") ?? 0
            var sizes = [0] + jitCacheSizes
            if current != 0, !sizes.contains(current) { sizes.append(current) }
            return [SettingSection(id: "cpu", title: "CPU", items: [
                flag("cpu-opt", "Enable CPU Optimizations", "cpu_opt"),
                flag("sw-pt", "Force Software Page Table", "force_software_page_table"),
                pick("jit-cache", "Cache JIT por thread", "cpu_jit_cache_mib", current: sizes.firstIndex(of: current) ?? 0,
                     labels: sizes.map { $0 == 0 ? L10n.text("Auto") : "\($0) MiB" }, raw: sizes.map(String.init),
                     detail: "Auto escolhe o tamanho conforme o perfil de cada jogo. Valores menores permitem mais threads, mas podem aumentar a recompilação."),
            ], footer: footer)]
        case .graphics:
            let res = Double(values["resolution_multiplier"] ?? "1") ?? 1
            let aniso = Int(values["anisotropic_filtering"] ?? "1") ?? 1
            return [
                SettingSection(id: "gfx", title: "Gráficos", items: [
                    pick("accuracy", "Precisão de Renderização", "high_accuracy", current: values["high_accuracy"] == "1" ? 1 : 0,
                         labels: [L10n.text("Padrão (Standard)"), L10n.text("Alta (High)")], raw: ["0", "1"],
                         detail: "Rendering Accuracy: Alta pode melhorar a precisão dos gráficos, com possível redução de desempenho."),
                    pick("resolution", "Internal Resolution Upscaling", "resolution_multiplier",
                         current: resolutions.firstIndex { abs($0 - res) < 0.01 } ?? 1,
                         labels: resolutions.map { $0.formatted() + "x" }, raw: resolutions.map { String($0) }),
                    pick("aniso", "Anisotropic Filtering", "anisotropic_filtering", current: anisotropics.firstIndex(of: aniso) ?? 0,
                         labels: anisotropics.map { "\($0)x" }, raw: anisotropics.map(String.init)),
                    flag("fps-hack", "FPS Hack", "fps_hack"),
                    flag("cap30", "Limit to 30 FPS", "frame_cap_30"),
                    flag("half-res", "Half-Resolution Textures", "half_res_textures"),
                    flag("surface-sync", "Disable Surface Sync", "disable_surface_sync"),
                    flag("async-pipe", "Asynchronous Pipeline Compilation", "async_pipeline_compilation"),
                ], footer: footer),
                SettingSection(id: "cache", title: "Cache", items: [
                    flag("shader-cache", "Enable Shader Cache", "shader_cache"),
                    flag("tex-cache", "Enable Texture Cache", "texture_cache"),
                    flag("compile-hint", "Show Shader Compilation Hint", "show_compile_shaders"),
                    SettingItem(id: "clear-shaders", title: "Clear Shaders", symbol: "trash",
                                kind: .action { clearShaders() }, enabled: !clearing),
                ]),
            ]
        }
    }

    private func load() {
        let report = Vita3KCore.gameConfigGet(appPath: "")
        var d: [String: String] = [:]
        for line in report.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1)
            if p.count == 2 { d[String(p[0])] = String(p[1]) }
        }
        guard !d.isEmpty else {
            message = L10n.text("Não foi possível carregar a configuração (inicie a sessão primeiro).")
            return
        }
        values = d
        loaded = true
        message = ""
    }

    private func save(_ key: String, _ value: String) -> Bool {
        let rc = Vita3KCore.gameConfigSet(appPath: "", key: key, value: value)
        message = rc == 0 ? "" : L10n.format("Erro ao salvar %@ (código %d).", key, rc)
        return rc == 0
    }

    private func clearShaders() {
        clearing = true
        message = ""
        Task.detached(priority: .utility) {
            let rc = Vita3KCore.clearShaders(appPath: "")
            await MainActor.run {
                clearing = false
                message = rc == 0 ? L10n.text("Shader cache limpo.") : L10n.format("Erro ao limpar o shader cache (código %d).", rc)
            }
        }
    }
}
