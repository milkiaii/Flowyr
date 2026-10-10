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
    @State private var textureCache = true
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
            Form {
                header
                if loaded {
                    perGameSection
                    loggingSection
                    globalSection
                    customSection
                } else if !message.isEmpty {
                    Section {
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Config do jogo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Concluído") { onDone() }
                }
            }
        }
        .onAppear { load() }
    }

    // MARK: - Sections

    private var header: some View {
        Section {
            HStack(spacing: 12) {
                GameArtwork(titleID: titleId)
                    .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title.isEmpty ? titleId : title).font(.headline).lineLimit(2)
                    Text(titleId).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var perGameSection: some View {
        Section {
            Toggle("Enable CPU Optimizations", isOn: $cpuOpt)
                .onChange(of: cpuOpt) { _, on in guard !loading else { return }; set("cpu_opt", on ? "1" : "0") }
            Toggle("Force Software Page Table", isOn: $forceSoftwarePageTable)
                .onChange(of: forceSoftwarePageTable) { _, on in guard !loading else { return }; set("force_software_page_table", on ? "1" : "0") }
            Picker("Cache JIT por thread", selection: Binding(
                get: { jitCacheMiB },
                set: { size in
                    if set("cpu_jit_cache_mib", String(size)) { jitCacheMiB = size }
                }
            )) {
                Text("Auto").tag(0)
                ForEach(jitCacheSizes, id: \.self) { size in
                    Text("\(size) MiB").tag(size)
                }
                // Display manually edited legacy values without silently
                // changing the saved budget just by opening this screen.
                if jitCacheMiB != 0, !jitCacheSizes.contains(jitCacheMiB) {
                    Text("\(jitCacheMiB) MiB (atual)").tag(jitCacheMiB).disabled(true)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("game-jit-cache")
            Text("Auto usa \(jitCacheAutoMiB) MiB para este jogo, conforme o padrão do core. Valores menores permitem mais threads na memória JIT disponível, mas podem aumentar a recompilação de código. Aplicado ao reiniciar este jogo.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Precisão de Renderização", selection: Binding(
                get: { highAccuracy },
                set: { high in
                    if set("high_accuracy", high ? "1" : "0") { highAccuracy = high }
                }
            )) {
                Text("Padrão (Standard)").tag(false)
                Text("Alta (High)").tag(true)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("game-rendering-accuracy")
            Text("Rendering Accuracy: Alta pode melhorar a precisão dos gráficos, com possível redução de desempenho.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Disable Surface Sync", isOn: $disableSurfaceSync)
                .onChange(of: disableSurfaceSync) { _, on in guard !loading else { return }; set("disable_surface_sync", on ? "1" : "0") }
            Toggle("Asynchronous Pipeline Compilation", isOn: $asyncPipeline)
                .onChange(of: asyncPipeline) { _, on in guard !loading else { return }; set("async_pipeline_compilation", on ? "1" : "0") }
            Picker("Internal Resolution Upscaling", selection: $resolutionIdx) {
                ForEach(resolutions.indices, id: \.self) { i in
                    Text(resolutions[i].formatted() + "x").tag(i)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: resolutionIdx) { _, i in
                guard !loading else { return }
                set("resolution_multiplier", String(resolutions[i]))
            }
            Picker("Anisotropic Filtering", selection: $anisotropicIdx) {
                ForEach(anisotropics.indices, id: \.self) { i in
                    Text("\(anisotropics[i])x").tag(i)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: anisotropicIdx) { _, i in
                guard !loading else { return }
                set("anisotropic_filtering", String(anisotropics[i]))
            }
            Toggle("Enable Shader Cache", isOn: $shaderCache)
                .onChange(of: shaderCache) { _, on in guard !loading else { return }; set("shader_cache", on ? "1" : "0") }
            Button {
                clearShaders()
            } label: {
                HStack {
                    Label("Clear Shaders", systemImage: "trash")
                    Spacer()
                    if clearing { ProgressView() }
                }
            }
            .disabled(clearing)
            Toggle("FPS Hack", isOn: $fpsHack)
                .onChange(of: fpsHack) { _, on in guard !loading else { return }; set("fps_hack", on ? "1" : "0") }
            Toggle("Enable Texture Cache", isOn: $textureCache)
                .onChange(of: textureCache) { _, on in guard !loading else { return }; set("texture_cache", on ? "1" : "0") }
        } header: {
            Text("CPU e GPU (este jogo)")
        } footer: {
            Text("Aplicados quando este jogo for (re)iniciado.")
        }
    }

    private var loggingSection: some View {
        Section {
            Picker("Log Level", selection: $logLevel) {
                ForEach(0..<logLevels.count, id: \.self) { i in
                    Text(LocalizedStringKey(logLevels[i])).tag(i)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: logLevel) { _, lvl in
                guard !loading else { return }
                set("log_level", String(lvl))
            }
            .accessibilityIdentifier("game-log-level")
            Toggle("Log Compatibility Warnings", isOn: $logCompatWarn)
                .onChange(of: logCompatWarn) { _, on in guard !loading else { return }; set("log_compat_warn", on ? "1" : "0") }
                .disabled(logLevel == 6)
        } header: {
            Text("Logs (este jogo)")
        } footer: {
            Text("Desativados por padrão. Aplicados ao iniciar este jogo. Os modos Compat Fix, Performance Fix e Graphics Fix ativam os logs automaticamente durante o diagnóstico.")
        }
    }

    private var globalSection: some View {
        Section {
            Toggle("Show Shader Compilation Hint", isOn: $showCompileHint)
                .onChange(of: showCompileHint) { _, on in guard !loading else { return }; set("show_compile_shaders", on ? "1" : "0") }
            Toggle("Performance Overlay", isOn: $perfOverlay)
                .accessibilityIdentifier("performance-overlay-toggle")
                .onChange(of: perfOverlay) { _, on in
                    guard !loading else { return }
                    UserDefaults.standard.set(on, forKey: "emulation.showStatus")
                }
            Text("FPS, tempo por quadro e memória. No iPhone, CPU e GPU compartilham RAM; as alocações da GPU são mostradas separadamente, sem somar ao total.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Emulador (todos os jogos)")
        } footer: {
            Text("Estes itens são globais no núcleo: valem para todos os jogos.")
        }
    }

    private var customSection: some View {
        Section {
            if hasCustom {
                Button("Remover config própria (restaurar padrões)", role: .destructive) {
                    confirmReset = true
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .confirmationDialog("Remover a configuração própria deste jogo?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Remover", role: .destructive) { reset() }
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
        textureCache = (d["texture_cache"] == "1")
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
