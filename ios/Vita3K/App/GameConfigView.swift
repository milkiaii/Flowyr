// Vita3K iOS shell app
// Per-game settings screen (parity with the desktop settings dialog scope):
// long-press a game in the library -> "Editar Config". Per-game fields
// persist in the game's custom config (config/config_<TITLE>.xml) and are
// applied by the core on that game's next launch, including logging.

import SwiftUI
import Vita3KCore

struct GameConfigView: View {
    let titleId: String
    let title: String
    var onDone: () -> Void

    // Per-game (this game's custom config).
    @State private var cpuOpt = true
    @State private var forceSoftwarePageTable = false
    @State private var jitCacheMiB = 0
    @State private var jitCacheAutoMiB = 16
    @State private var highAccuracy = false
    @State private var disableSurfaceSync = false
    @State private var asyncPipeline = true
    @State private var resolutionIdx: Int = 1
    @State private var anisotropicIdx: Int = 0
    @State private var shaderCache = true
    @State private var fpsHack = false
    @State private var frameCap30 = false
    @State private var textureCache = true
    @State private var halfResTextures = false
    @State private var hasCustom = false

    @State private var logLevel: Int = 6
    @State private var logCompatWarn = false

    // Global (all games).
    @State private var showCompileHint = false
    @State private var perfOverlay: Bool = UserDefaults.standard.bool(forKey: "emulation.showStatus")

    @State private var loaded = false
    @State private var loading = false
    @State private var message = ""
    @State private var clearing = false
    @State private var confirmReset = false

    private let resolutions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4]
    private let anisotropics: [Int] = [1, 2, 4, 8, 16]
    private let jitCacheSizes = Array(stride(from: 8, through: 32, by: 4))
    private let logLevels = ["Trace", "Debug", "Info", "Warning", "Error", "Critical", "Desativado"]

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    PadSettingsPage(sections: sections, status: message, onClose: onDone)
                } else {
                    ScrollView {
                        Text(message).font(.subheadline).foregroundStyle(.secondary).padding(20)
                    }.background(EmulatorTheme.background)
                }
            }
            .navigationTitle("Config do jogo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluído") { onDone() }
                }
            }
            .confirmationDialog("Remover a configuração própria deste jogo?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Remover", role: .destructive) { reset() }
            }
        }
        .onAppear { load() }
    }

    // MARK: - Items

    /// A bool setting saved to the game's config under `key`.
    private func flag(_ id: String, _ title: LocalizedStringKey, _ key: String, _ value: Binding<Bool>,
                      detail: LocalizedStringKey? = nil, enabled: Bool = true) -> SettingItem {
        SettingItem(id: id, title: title, detail: detail, kind: .toggle(Binding(
            get: { value.wrappedValue },
            set: { new in
                value.wrappedValue = new
                if !loading { set(key, new ? "1" : "0") }
            })), enabled: enabled)
    }

    /// A choice whose index maps to `values[index]` saved under `key`.
    private func pick(_ id: String, _ title: LocalizedStringKey, _ key: String, _ index: Binding<Int>,
                      labels: [String], values: [String], detail: LocalizedStringKey? = nil) -> SettingItem {
        SettingItem(id: id, title: title, detail: detail, kind: .choice(Binding(
            get: { index.wrappedValue },
            set: { new in
                if !loading, !set(key, values[new]) { return }
                index.wrappedValue = new
            }), labels))
    }

    private var jitCacheValues: [Int] {
        var values = [0] + jitCacheSizes
        // Show manually edited legacy values without silently changing them.
        if jitCacheMiB != 0, !jitCacheSizes.contains(jitCacheMiB) { values.append(jitCacheMiB) }
        return values
    }

    private var sections: [SettingSection] {
        let values = jitCacheValues
        let gameSection = SettingSection(id: "game", title: "CPU e GPU (este jogo)", items: [
            flag("cpu-opt", "Enable CPU Optimizations", "cpu_opt", $cpuOpt),
            flag("sw-pt", "Force Software Page Table", "force_software_page_table", $forceSoftwarePageTable),
            pick("jit-cache", "Cache JIT por thread", "cpu_jit_cache_mib",
                 Binding(get: { values.firstIndex(of: jitCacheMiB) ?? 0 },
                         set: { jitCacheMiB = values[$0] }),
                 labels: values.map { $0 == 0 ? L10n.text("Auto") : "\($0) MiB" },
                 values: values.map(String.init),
                 detail: LocalizedStringKey("Auto usa \(jitCacheAutoMiB) MiB para este jogo, conforme o padrão do core. Valores menores permitem mais threads, mas podem aumentar a recompilação. Aplicado ao reiniciar este jogo.")),
            pick("accuracy", "Precisão de Renderização", "high_accuracy",
                 Binding(get: { highAccuracy ? 1 : 0 }, set: { highAccuracy = $0 == 1 }),
                 labels: [L10n.text("Padrão (Standard)"), L10n.text("Alta (High)")], values: ["0", "1"],
                 detail: "Rendering Accuracy: Alta pode melhorar a precisão dos gráficos, com possível redução de desempenho."),
            flag("surface-sync", "Disable Surface Sync", "disable_surface_sync", $disableSurfaceSync),
            flag("async-pipe", "Asynchronous Pipeline Compilation", "async_pipeline_compilation", $asyncPipeline),
            pick("resolution", "Internal Resolution Upscaling", "resolution_multiplier", $resolutionIdx,
                 labels: resolutions.map { $0.formatted() + "x" }, values: resolutions.map { String($0) }),
            pick("aniso", "Anisotropic Filtering", "anisotropic_filtering", $anisotropicIdx,
                 labels: anisotropics.map { "\($0)x" }, values: anisotropics.map(String.init)),
            flag("shader-cache", "Enable Shader Cache", "shader_cache", $shaderCache),
            SettingItem(id: "clear-shaders", title: "Clear Shaders", symbol: "trash",
                        kind: .action { clearShaders() }, enabled: !clearing),
            flag("fps-hack", "FPS Hack", "fps_hack", $fpsHack),
            flag("cap30", "Limit to 30 FPS", "frame_cap_30", $frameCap30),
            flag("tex-cache", "Enable Texture Cache", "texture_cache", $textureCache),
            flag("half-res", "Half-Resolution Textures", "half_res_textures", $halfResTextures),
        ], footer: "Aplicados quando este jogo for (re)iniciado.",
        accessory: AnyView(header))

        let logSection = SettingSection(id: "logs", title: "Logs (este jogo)", items: [
            pick("log-level", "Log Level", "log_level", $logLevel,
                 labels: logLevels.map { L10n.text($0) }, values: logLevels.indices.map(String.init)),
            flag("log-compat", "Log Compatibility Warnings", "log_compat_warn", $logCompatWarn, enabled: logLevel != 6),
        ], footer: "Desativados por padrão. Aplicados ao iniciar este jogo. Os modos Compat Fix, Performance Fix e Graphics Fix ativam os logs automaticamente durante o diagnóstico.")

        let globalSection = SettingSection(id: "global", title: "Emulador (todos os jogos)", items: [
            flag("compile-hint", "Show Shader Compilation Hint", "show_compile_shaders", $showCompileHint),
            SettingItem(id: "overlay", title: "Performance Overlay",
                        detail: "FPS, tempo por quadro e memória.",
                        kind: .toggle(Binding(get: { perfOverlay },
                                              set: { perfOverlay = $0
                                                     UserDefaults.standard.set($0, forKey: "emulation.showStatus") }))),
        ], footer: "Estes itens são globais no núcleo: valem para todos os jogos.")

        var result = [gameSection, logSection, globalSection]
        if hasCustom {
            result.append(SettingSection(id: "custom", title: "Config própria", items: [
                SettingItem(id: "reset", title: "Remover config própria (restaurar padrões)", symbol: "arrow.uturn.backward",
                            kind: .action { confirmReset = true }, destructive: true)
            ]))
        }
        return result
    }

    private var header: some View {
        HStack(spacing: 12) {
            GameArtwork(titleID: titleId).frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? titleId : title).font(.headline).lineLimit(2)
                Text(titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    /// Parses the bridge report ("key=value" lines) into the controls.
    /// `loading` keeps the onAppear population from firing the persist
    /// handlers (they only apply user changes).
    private func load() {
        let report = Vita3KCore.gameConfigGet(appPath: titleId)
        var d: [String: String] = [:]
        for line in report.split(separator: "\n") {
            let p = line.split(separator: "=", maxSplits: 1)
            if p.count == 2 { d[String(p[0])] = String(p[1]) }
        }
        guard !d.isEmpty else {
            message = L10n.text("Não foi possível carregar a configuração (inicie a sessão primeiro).")
            loaded = false
            return
        }
        loaded = true
        loading = true
        defer { loading = false }
        message = ""
        hasCustom = (d["has_custom"] == "1")
        cpuOpt = (d["cpu_opt"] == "1")
        forceSoftwarePageTable = (d["force_software_page_table"] == "1")
        jitCacheMiB = Int(d["cpu_jit_cache_mib"] ?? "0") ?? 0
        jitCacheAutoMiB = Int(d["cpu_jit_cache_auto_mib"] ?? "16") ?? 16
        highAccuracy = (d["high_accuracy"] == "1")
        disableSurfaceSync = (d["disable_surface_sync"] == "1")
        asyncPipeline = (d["async_pipeline_compilation"] == "1")
        let res = Double(d["resolution_multiplier"] ?? "1") ?? 1
        resolutionIdx = resolutions.firstIndex { abs($0 - res) < 0.01 } ?? 1
        let aniso = Int(d["anisotropic_filtering"] ?? "1") ?? 1
        anisotropicIdx = anisotropics.firstIndex(of: aniso) ?? 0
        shaderCache = (d["shader_cache"] == "1")
        fpsHack = (d["fps_hack"] == "1")
        frameCap30 = (d["frame_cap_30"] == "1")
        textureCache = (d["texture_cache"] == "1")
        halfResTextures = (d["half_res_textures"] == "1")
        logLevel = min(6, max(0, Int(d["log_level"] ?? "6") ?? 6))
        logCompatWarn = (d["log_compat_warn"] == "1")
        showCompileHint = (d["show_compile_shaders"] == "1")
    }

    @discardableResult
    private func set(_ key: String, _ value: String) -> Bool {
        let rc = Vita3KCore.gameConfigSet(appPath: titleId, key: key, value: value)
        Probe.mark("game-config-set \(key)=\(value) rc=\(rc)")
        message = rc == 0 ? "" : L10n.format("Erro ao salvar %@ (código %d).", key, rc)
        if rc == 0, key != "show_compile_shaders" { hasCustom = true }
        return rc == 0
    }

    private func clearShaders() {
        clearing = true
        message = ""
        Probe.mark("game-config-clear-shaders")
        Task.detached(priority: .utility) {
            let rc = Vita3KCore.clearShaders(appPath: titleId)
            await MainActor.run {
                clearing = false
                message = rc == 0 ? L10n.text("Shader cache deste jogo limpo.") : L10n.format("Erro ao limpar o shader cache (código %d).", rc)
            }
        }
    }

    private func reset() {
        let rc = Vita3KCore.gameConfigReset(appPath: titleId)
        message = rc == 0 ? L10n.text("Config própria removida.") : L10n.format("Erro ao remover a config própria (código %d).", rc)
        load()
    }
}
