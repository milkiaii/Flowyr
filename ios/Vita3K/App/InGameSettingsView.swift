// Vita3K iOS shell app
// In-game settings sheet, opened from the HOME menu while the game is paused.
// Changes are saved to the game's custom config; the ones marked live are also
// applied to the running game by the core, the rest apply on the next launch.

import SwiftUI
import Vita3KCore

struct InGameSettingsView: View {
    let titleId: String
    var onDone: () -> Void

    @State private var frameCap30 = false
    @State private var fpsHack = false
    @State private var halfResTextures = false
    @State private var disableSurfaceSync = false
    @State private var asyncPipeline = true
    @State private var anisotropicIdx = 0
    @State private var resolutionIdx = 1
    @State private var loaded = false
    @State private var loading = false
    @State private var message = ""

    private let resolutions: [Double] = [0.5, 1, 1.5, 2, 2.5, 3, 4]
    private let anisotropics: [Int] = [1, 2, 4, 8, 16]

    var body: some View {
        NavigationStack {
            Form {
                if loaded {
                    Section {
                        Toggle("Limit to 30 FPS", isOn: $frameCap30)
                            .onChange(of: frameCap30) { _, on in guard !loading else { return }; set("frame_cap_30", on ? "1" : "0") }
                        Toggle("FPS Hack", isOn: $fpsHack)
                            .onChange(of: fpsHack) { _, on in guard !loading else { return }; set("fps_hack", on ? "1" : "0") }
                        Toggle("Half-Resolution Textures", isOn: $halfResTextures)
                            .onChange(of: halfResTextures) { _, on in guard !loading else { return }; set("half_res_textures", on ? "1" : "0") }
                        Toggle("Disable Surface Sync", isOn: $disableSurfaceSync)
                            .onChange(of: disableSurfaceSync) { _, on in guard !loading else { return }; set("disable_surface_sync", on ? "1" : "0") }
                        Toggle("Asynchronous Pipeline Compilation", isOn: $asyncPipeline)
                            .onChange(of: asyncPipeline) { _, on in guard !loading else { return }; set("async_pipeline_compilation", on ? "1" : "0") }
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
                    } header: {
                        Text("Applied now")
                    } footer: {
                        Text("Half-resolution textures only affect textures loaded from now on.")
                    }
                    Section {
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
                    } header: {
                        Text("Applied on next launch")
                    } footer: {
                        Text("Exit to the library and start the game again to use the new resolution.")
                    }
                } else {
                    Section { Text(message.isEmpty ? "…" : message).foregroundStyle(.secondary) }
                }
                if loaded, !message.isEmpty {
                    Section { Text(message).foregroundStyle(.red) }
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
        .onAppear { load() }
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
    }

    @discardableResult
    private func set(_ key: String, _ value: String) -> Bool {
        let rc = Vita3KCore.gameConfigSet(appPath: titleId, key: key, value: value)
        Probe.mark("ingame-config-set \(key)=\(value) rc=\(rc)")
        message = rc == 0 ? "" : L10n.format("Erro ao salvar %@ (código %d).", key, rc)
        return rc == 0
    }
}
