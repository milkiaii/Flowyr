// Vita3K iOS shell app
// In-game settings sheet, opened from the HOME menu while the game is paused.
// Changes are saved to the game's custom config; the ones marked live are also
// applied to the running game by the core, the rest apply on the next launch.

import SwiftUI
import Vita3KCore

struct InGameSettingsView: View {
    let titleId: String
    var onDone: () -> Void
    /// Stops and relaunches the game (the caller closes the sheet).
    var onRestart: () -> Void

    @State private var frameCap30 = false
    @State private var fpsHack = false
    @State private var halfResTextures = false
    @State private var disableSurfaceSync = false
    @State private var asyncPipeline = true
    @State private var anisotropicIdx = 0
    @State private var resolutionIdx = 1
    @State private var initialResolutionIdx = 1
    @State private var confirmRestart = false
    @AppStorage("emulation.showStatus") private var showStatus = false
    @AppStorage("emulation.hideHome") private var hideHome = false
    // The sheet is hosted from UIKit, so it does not inherit the app-wide
    // tint and color scheme set in ContentView: apply them here.
    @AppStorage(EmulatorTheme.lightModePreference) private var lightMode = false
    @State private var loaded = false
    @State private var loading = false
    @State private var message = ""

    private let resolutions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4]
    private let anisotropics: [Int] = [1, 2, 4, 8, 16]

    var body: some View {
        NavigationStack {
            Group {
                if loaded {
                    PadSettingsPage(sections: sections, status: message, onClose: onDone)
                } else {
                    ScrollView { Text(message.isEmpty ? "…" : message).foregroundStyle(.secondary).padding(20) }
                        .background(EmulatorTheme.background)
                }
            }
            .navigationTitle("In-Game Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { onDone() }
                        .accessibilityIdentifier("ingame-settings-done")
                }
            }
        }
        .confirmationDialog("Restart the game?", isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart", role: .destructive) { onRestart() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Unsaved progress will be lost.")
        }
        .tint(EmulatorTheme.accent)
        .preferredColorScheme(lightMode ? .light : .dark)
        .onAppear { load() }
    }

    private func flag(_ id: String, _ title: LocalizedStringKey, _ key: String, _ value: Binding<Bool>) -> SettingItem {
        SettingItem(id: id, title: title, kind: .toggle(Binding(
            get: { value.wrappedValue },
            set: { new in value.wrappedValue = new; if !loading { set(key, new ? "1" : "0") } })))
    }

    private var sections: [SettingSection] {
        var resolution = [
            SettingItem(id: "resolution", title: "Internal Resolution Upscaling", kind: .choice(Binding(
                get: { resolutionIdx },
                set: { i in
                    if !loading, !set("resolution_multiplier", String(resolutions[i])) { return }
                    resolutionIdx = i
                }), resolutions.map { $0.formatted() + "x" })),
        ]
        if resolutionIdx != initialResolutionIdx {
            resolution.append(SettingItem(id: "restart", title: "Restart game to apply", symbol: "arrow.clockwise",
                                          kind: .action { confirmRestart = true }, destructive: true))
        }
        return [
            SettingSection(id: "now", title: "Applied now", items: [
                flag("cap30", "Limit to 30 FPS", "frame_cap_30", $frameCap30),
                flag("fps-hack", "FPS Hack", "fps_hack", $fpsHack),
                flag("half-res", "Half-Resolution Textures", "half_res_textures", $halfResTextures),
                flag("surface", "Disable Surface Sync", "disable_surface_sync", $disableSurfaceSync),
                flag("async", "Asynchronous Pipeline Compilation", "async_pipeline_compilation", $asyncPipeline),
                SettingItem(id: "overlay", title: "Performance Overlay", kind: .toggle($showStatus)),
                SettingItem(id: "hide-home", title: "Hide HOME Button", kind: .toggle($hideHome)),
                SettingItem(id: "aniso", title: "Anisotropic Filtering", kind: .choice(Binding(
                    get: { anisotropicIdx },
                    set: { i in
                        if !loading, !set("anisotropic_filtering", String(anisotropics[i])) { return }
                        anisotropicIdx = i
                    }), anisotropics.map { "\($0)x" })),
            ], footer: "Half-resolution textures only affect textures loaded from now on. With the HOME button hidden, double-tap where it was (top center) to show it until you resume the game."),
            SettingSection(id: "resolution", title: "Resolution", items: resolution,
                           footer: "The resolution is applied by restarting the game. Unsaved progress is lost."),
        ]
    }

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
        loading = true
        defer { loading = false }
        loaded = true
        message = ""
        frameCap30 = (d["frame_cap_30"] == "1")
        fpsHack = (d["fps_hack"] == "1")
        halfResTextures = (d["half_res_textures"] == "1")
        disableSurfaceSync = (d["disable_surface_sync"] == "1")
        asyncPipeline = (d["async_pipeline_compilation"] == "1")
        let aniso = Int(d["anisotropic_filtering"] ?? "1") ?? 1
        anisotropicIdx = anisotropics.firstIndex(of: aniso) ?? 0
        let res = Double(d["resolution_multiplier"] ?? "1") ?? 1
        resolutionIdx = resolutions.firstIndex { abs($0 - res) < 0.01 } ?? 1
        initialResolutionIdx = resolutionIdx
    }

    @discardableResult
    private func set(_ key: String, _ value: String) -> Bool {
        let rc = Vita3KCore.gameConfigSet(appPath: titleId, key: key, value: value)
        Probe.mark("ingame-config-set \(key)=\(value) rc=\(rc)")
        message = rc == 0 ? "" : L10n.format("Erro ao salvar %@ (código %d).", key, rc)
        return rc == 0
    }
}
