// Vita3K iOS shell app
// Wraps the Vita3KCore C bridge (vita3k/ios) for the SwiftUI UI.

import Foundation
import Vita3KCore

/// C-bridge accessors with typed signatures, shared by the SwiftUI UI and
/// the step 6 emulation surface.
enum Vita3KCore {
    enum LoggingMode: String {
        case off, debug, compat, performance, graphics
    }

    static func loggingMode() -> LoggingMode {
        LoggingMode(rawValue: CText.string(vita3k_ios_logging_mode())) ?? .off
    }

    static var loggingEnabled: Bool { vita3k_ios_logging_enabled() != 0 }

    /// NUL-terminated C text -> String (UTF-8), truncated at the first NUL.
    /// Replaces the deprecated String(cString:) for both raw buffers and
    /// `const char *` returns of the bridge.
    enum CText {
        static func string(_ buffer: [Int8]) -> String {
            buffer.withUnsafeBufferPointer { p in
                String(decoding: p.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }

        static func string(_ ptr: UnsafePointer<CChar>) -> String {
            var n = 0
            while ptr[n] != 0 { n += 1 }
            return ptr.withMemoryRebound(to: UInt8.self, capacity: n) { p in
                String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
            }
        }
    }

    static func startVulkanDemo(basePath: String, staticAssets: String, hasMoltenVK: Int32,
                                width: Int32, height: Int32)
        -> (Int32, String) {
        let capacity = 16384
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_vulkan_demo_start(basePath, staticAssets, hasMoltenVK,
                width, height, ptr.baseAddress!, capacity)
        }
        let text = rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
        return (rc, text)
    }

    /// Main-thread handoff of the UIKit-owned CAMetalLayer to the core
    /// (frame-host channel). Call before `startVulkanDemo`: the core stores
    /// it in the frame host and the render thread reads it lock-free.
    static func frameHostSetLayer(_ layer: UnsafeMutableRawPointer) {
        vita3k_ios_frame_host_set_layer(layer)
    }

    static func stopVulkanDemo() -> Int32 {
        vita3k_ios_vulkan_demo_stop()
    }

    static func vulkanDemoIsRunning() -> Bool {
        vita3k_ios_vulkan_demo_is_running() == 1
    }

    static func vulkanDemoReport() -> String {
        let capacity = 16384
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_vulkan_demo_report(ptr.baseAddress!, capacity)
        }
        return rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
    }

    static func frameHostSetSize(width: Int32, height: Int32) {
        vita3k_ios_frame_host_set_size(width, height)
    }

    // Step 7: session facade over the core's AppSessionController.

    /// Initialize the emulator environment (Root under `basePath`, logging,
    /// EmuEnvState, config, apps list, users). Idempotent; call once.
    static func sessionInit(basePath: String, staticAssets: String) -> Int32 {
        vita3k_ios_session_init(basePath, staticAssets)
    }

    /// Staging directory (<basePath>/imports/): document picker files are
    /// copied here on a worker before installing.
    static func sessionStagingPath() -> String {
        let capacity = 1024
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_session_staging_path(ptr.baseAddress!, capacity)
        }
        return rc == 0 ? CText.string(buffer) : ""
    }

    /// Install staged content (app folder / .zip/.vpk of app content,
    /// .pkg or .pup) into the emulated Vita FS; the apps list is re-scanned.
    static func sessionInstall(stagedPath: String, replaceExisting: Bool = true) -> (Int32, String) {
        let capacity = 8192
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_session_install(stagedPath, replaceExisting ? 1 : 0, ptr.baseAddress!, capacity)
        }
        let text = rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
        return (rc, text)
    }

    /// Installs a license from a zRIF key (saved under ux0/license).
    static func sessionInstallZRIF(_ key: String) -> (Int32, String) {
        let capacity = 4096
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_session_install_zrif(key, ptr.baseAddress!, capacity)
        }
        let text = rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
        return (rc, text)
    }

    /// Installed apps as "title_id|title" lines.
    static func sessionGetApps() -> String {
        let capacity = 8192
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_session_get_apps(ptr.baseAddress!, capacity)
        }
        return rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
    }

    static func sessionScanApps() -> Int32 {
        vita3k_ios_session_scan_apps()
    }

    static func sessionDeleteApp(titleID: String) -> (Int32, String) {
        var buffer = [Int8](repeating: 0, count: 2048)
        let rc = buffer.withUnsafeMutableBufferPointer {
            vita3k_ios_session_delete_app(titleID, $0.baseAddress!, $0.count)
        }
        return (rc, CText.string(buffer))
    }

    static func sessionFirmwareMask() -> Int32 {
        vita3k_ios_session_firmware_mask()
    }

    // Per-game settings (desktop settings-dialog parity). Per-game values
    // persist in the game's custom config (applied on its next launch);
    // global values update the shared config.

    /// Settings report ("key=value" lines) for a title id.
    static func gameConfigGet(appPath: String) -> String {
        let capacity = 4096
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_game_config_get(appPath, ptr.baseAddress!, capacity)
        }
        return rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
    }

    /// Sets one setting (see the bridge docs for keys/values). Returns 0 on
    /// success, negative otherwise.
    static func gameConfigSet(appPath: String, key: String, value: String) -> Int32 {
        vita3k_ios_game_config_set(appPath, key, value)
    }

    /// Removes the per-game custom config (restores global defaults and the title profile).
    static func gameConfigReset(appPath: String) -> Int32 {
        vita3k_ios_game_config_reset(appPath)
    }

    static let lowMemoryPreference = "emulation.lowMemoryMode"
    static let titleProfilesPreference = "emulation.titleProfiles"

    /// Pushes the opt-in options (Settings > System) to the core.
    static func applyRuntimeOptions() {
        let d = UserDefaults.standard
        vita3k_ios_set_options(d.bool(forKey: lowMemoryPreference) ? 1 : 0, d.bool(forKey: titleProfilesPreference) ? 1 : 0)
    }

    /// Clears shader caches/logs for a title (empty string = every title).
    static func clearShaders(appPath: String) -> Int32 {
        vita3k_ios_clear_shaders(appPath)
    }

    /// Starts the session on a background thread (renderer init, 4 GiB
    /// reservation, app load); the CAMetalLayer must be delivered with
    /// frameHostSetLayer before the call.
    static func sessionLaunch(appPath: String, width: Int32, height: Int32) -> Int32 {
        vita3k_ios_session_launch(appPath, width, height)
    }

    static func sessionStop() -> Int32 {
        vita3k_ios_session_stop()
    }

    static func sessionIsActive() -> Bool {
        vita3k_ios_session_is_active() == 1
    }

    /// 0 Idle, 1 Starting, 2 Running, 3 Stopping, 4 Failed.
    static func sessionPhase() -> Int32 {
        vita3k_ios_session_phase()
    }

    static func sessionIsPaused() -> Bool {
        vita3k_ios_session_is_paused() == 1
    }

    static func sessionFrameCount() -> UInt64 {
        vita3k_ios_session_frame_count()
    }

    static func sessionLaunchFailed() -> Bool {
        vita3k_ios_session_launch_failed() == 1
    }

    static func sessionAppPath() -> String {
        CText.string(vita3k_ios_session_app_path())
    }

    static func sessionReport() -> String {
        let capacity = 8192
        var buffer = [Int8](repeating: 0, count: capacity)
        let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            vita3k_ios_session_report(ptr.baseAddress!, capacity)
        }
        return rc == 0 || buffer.contains(where: { $0 != 0 }) ? CText.string(buffer) : ""
    }

    // Step 9: input bridge (UIKit main thread -> running session).
    // No-ops in the core when no session is active.

    /// Front-touch event from the surface. `px`/`py` are surface PIXEL
    /// coordinates (points x contentScaleFactor); the core maps them
    /// through the renderer's letterbox viewport. `event`: 0 down, 1 move,
    /// 2 up, 3 cancelled. `fingerID` is a stable per-touch identifier.
    static func inputTouchEvent(event: Int32, fingerID: Int32, px: Int32, py: Int32) {
        vita3k_ios_input_touch_event(event, fingerID, px, py)
    }

    /// Commit UTF-16 text to the guest's active IME session.
    static func imeCommitText(_ text: String) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { ptr in
            vita3k_ios_input_ime_commit_text(ptr.baseAddress!, Int32(units.count))
        }
    }

    /// Set the IME preedit (composition) text.
    static func imePreedit(_ text: String) {
        let units = Array(text.utf16)
        units.withUnsafeBufferPointer { ptr in
            vita3k_ios_input_ime_preedit(ptr.baseAddress!, Int32(units.count))
        }
    }

    static func imeBackspace() {
        vita3k_ios_input_ime_backspace()
    }

    static func imeCursor(dir: Int32) {
        vita3k_ios_input_ime_cursor(dir)
    }

    /// 1 while the guest has an IME open (sceImeStart); the surface shows
    /// its software keyboard while this is true.
    static func imeActive() -> Bool {
        vita3k_ios_input_ime_active() == 1
    }

    static func imeSnapshot() -> GameKeyboardRequest? {
        var snapshot = Vita3KImeSnapshot()
        guard vita3k_ios_input_ime_snapshot(&snapshot) > 0 else { return nil }
        let count = Int(snapshot.text_length)
        let text = withUnsafeBytes(of: snapshot.text) {
            String(decoding: $0.bindMemory(to: UInt16.self).prefix(count), as: UTF16.self)
        }
        let title = withUnsafeBytes(of: snapshot.title) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
        }
        return GameKeyboardRequest(id: snapshot.request_id, text: text, title: title,
                                   caret: Int(snapshot.caret), maxLength: Int(snapshot.max_length),
                                   keyboardType: snapshot.keyboard_type, multiline: snapshot.multiline != 0,
                                   cancelable: snapshot.cancelable != 0)
    }

    static func imeReplace(id: UInt64, text: String, caret: UInt32) -> Bool {
        let units = Array(text.utf16)
        return units.withUnsafeBufferPointer {
            vita3k_ios_input_ime_replace(id, $0.baseAddress, Int32($0.count), caret) == 0
        }
    }

    static func imeFinish(id: UInt64, cancel: Bool) -> Bool {
        vita3k_ios_input_ime_finish(id, cancel ? 1 : 0) == 0
    }

    static func setRearTouch(_ enabled: Bool) {
        vita3k_ios_input_set_rear_touch(enabled ? 1 : 0)
    }

    /// Zero all touch/overlay-mouse state (no stuck input on focus loss).
    static func inputClear() {
        vita3k_ios_input_clear()
    }

    // On-screen (virtual) gamepad: touch controls write SCE_CTRL button
    // masks and -1..1 analogs into the core, blended with physical pads.

    static func virtualPadEnabled(_ enabled: Bool) {
        vita3k_ios_input_virtual_enabled(enabled ? 1 : 0)
    }

    /// `buttons` = non-extended SCE_CTRL mask, `buttonsExt` = extended.
    static func virtualButtons(_ buttons: UInt32, _ buttonsExt: UInt32) {
        vita3k_ios_input_virtual_buttons(buttons, buttonsExt)
    }

    static func virtualAxes(lx: Float, ly: Float, rx: Float, ry: Float) {
        vita3k_ios_input_virtual_axes(lx, ly, rx, ry)
    }

    /// Physical gamepads attached; the on-screen pad hides while one is.
    static func gamepadCount() -> Int {
        Int(vita3k_ios_input_gamepad_count())
    }

    /// JIT state probe: 0 = prepared and valid, -1 = unprepared/revoked.
    static func jitValidateAlive() -> Int32 {
        vita3k_ios_jit_validate_alive()
    }
}

/// Timestamped marker appended to Documents/startup-probe.txt.
/// Used to trace how far the process gets on real devices (no console there).
enum Probe {
    static func mark(_ marker: @autoclosure () -> String) {
        guard Vita3KCore.loggingEnabled else { return }
        let url: URL
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            url = dir.appendingPathComponent("startup-probe.txt")
        } else {
            return
        }
        let line = "\(Date()) \(marker())\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

@MainActor
final class CoreController: ObservableObject {
    enum JITStatus: String {
        case checking = "Verificando JIT"
        case ready = "JIT pronto"
        case unavailable = "JIT indisponível"
    }

    @Published private(set) var jitStatus: JITStatus = .checking
    @Published private(set) var loggingMode: Vita3KCore.LoggingMode = .off
    @Published var showJITAlert = false
    @Published private(set) var firmwareMask: Int32 = 0
    private var jitTask: Task<Bool, Never>?

    /// Coalesces startup, foreground and launch checks. Never infer JIT
    /// availability from CS_DEBUGGED alone: prepare the actual arena.
    func checkJIT() async -> Bool {
        if let jitTask { return await jitTask.value }
        jitStatus = .checking
        let task = Task<Bool, Never> {
            #if targetEnvironment(simulator)
            // UI regression hook, intentionally unavailable in device builds.
            if ProcessInfo.processInfo.environment["VITA3K_UI_TEST_NO_JIT"] == "1" {
                return false
            }
            #else
            // StikDebug may attach just after UIKit enters the foreground.
            // Do not run a BRK protocol unless debugging is allowed.
            if await Task.detached(operation: { Vita3KCore.jitValidateAlive() == 0 }).value {
                return true
            }
            // Runs entirely off the main actor so it overlaps with the
            // (main-thread) session init instead of waiting behind it.
            // Poll for the debugger every 100 ms (up to 3 s), then prepare
            // right away, retrying every 200 ms (up to ~3 s).
            return await Task.detached(priority: .userInitiated) {
                for _ in 0..<30 {
                    if vita3k_ios_cs_debugged() == 1 { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard vita3k_ios_cs_debugged() == 1 else { return false }
                for attempt in 0..<15 {
                    if vita3k_ios_jit_prepare() == 0 { return true }
                    if attempt < 14 { try? await Task.sleep(for: .milliseconds(200)) }
                }
                return false
            }.value
            #endif
            #if targetEnvironment(simulator)
            return await Task.detached(priority: .userInitiated) {
                vita3k_ios_jit_prepare() == 0
            }.value
            #endif
        }
        jitTask = task
        let ready = await task.value
        jitTask = nil
        jitStatus = ready ? .ready : .unavailable
        showJITAlert = !ready
        Probe.mark("jit-preflight: \(ready ? "ready" : "unavailable")")
        return ready
    }

    enum Phase: String {
        case idle = "AGUARDANDO"
        case running = "EXECUTANDO"
        case passed = "SELF-TEST OK"
        case failed = "SELF-TEST FALHOU"
    }

    @Published var phase: Phase = .idle
    @Published var version = ""
    @Published var report = ""
    @Published var failure = ""
    @Published var log = ""
    @Published var memReport = ""
    @Published var memRunning = false
    @Published var memPassed: Bool? = nil

    // Step 7: session state (AppSessionController facade).
    struct AppInfo: Identifiable, Hashable {
        let titleId: String
        let title: String
        var id: String { titleId }
    }

    @Published var apps: [AppInfo] = []
    @Published var selectedAppTitleId: String?
    @Published var sessionPhase: Int32 = 0
    @Published var sessionReport = ""
    struct ImportResult: Identifiable {
        let id = UUID()
        let succeeded: Bool
        let message: String
    }
    @Published var importResult: ImportResult?
    private var lastAutomaticImportError: String?
    @Published var isImporting = false
    @Published private(set) var isDeleting = false
    @Published var autoBootTitle: String?

    /// CLI-testable stop/switch trigger: set by the control poller from
    /// imports/ctl-stop.txt (first line = next title id, empty = just stop).
    /// ContentView dismisses the surface and, when non-empty, presents the
    /// next title — all within the same process.
    @Published var ctlNextTitle: String?

    let saveSync = CloudSaveSync()
    @Published private(set) var isSyncingSaves = false
    @Published var isPreparingGame = false
    var isGamePresented = false

    /// Only the library owns save files. A paused/background game still owns its
    /// files, as does a session whose asynchronous teardown has not finished.
    func syncSaves(resolution: SaveResolution? = nil, beforeLaunch: Bool = false) async {
        let nativePhase = Vita3KCore.sessionPhase()
        guard saveSync.enabled, sessionInitialized, !isSyncingSaves,
              !isImporting, !isDeleting, !memRunning, !isGamePresented, phase != .running,
              (!isPreparingGame || beforeLaunch), nativePhase == 0 || nativePhase == 4 else { return }
        isSyncingSaves = true
        defer { isSyncingSaves = false }
        await saveSync.synchronize(documents: URL(fileURLWithPath: basePath), resolution: resolution)
    }

    var sessionInitialized: Bool = false

    var canDeleteGame: Bool {
        sessionInitialized && !isDeleting && !isImporting && !memRunning && !isSyncingSaves && !isPreparingGame && !isGamePresented
            && (sessionPhase == 0 || sessionPhase == 4)
    }

    /// Returns an error for the alert, or nil after a successful uninstall.
    func deleteGame(_ game: AppInfo) async -> String? {
        guard canDeleteGame else { return L10n.text("Aguarde a operação em andamento e encerre a sessão antes de apagar um jogo.") }
        isDeleting = true
        let (rc, report) = await Task.detached(priority: .userInitiated) {
            Vita3KCore.sessionDeleteApp(titleID: game.titleId)
        }.value
        isDeleting = false
        refreshApps()
        guard rc == 0 else { return report.isEmpty ? L10n.format("Não foi possível apagar o jogo (código %d).", rc) : CoreMessage.localized(report) }

        let defaults = UserDefaults.standard
        let favorites = (defaults.string(forKey: "library.favorites") ?? "")
            .split(separator: ",").filter { $0 != game.titleId }
        defaults.set(favorites.joined(separator: ","), forKey: "library.favorites")
        if defaults.string(forKey: "library.lastPlayed") == game.titleId {
            defaults.removeObject(forKey: "library.lastPlayed")
        }
        // A host-created auto-boot marker must not reinstall a deleted title
        // from its retained import archive on the next app launch.
        if readAutoBootTitle() == game.titleId {
            try? FileManager.default.removeItem(atPath: (basePath as NSString).appendingPathComponent("auto-boot.txt"))
        }
        if autoBootTitle == game.titleId { autoBootTitle = nil }
        return nil
    }

    /// Step 7: initialize the emulator environment (Root under the sandbox,
    /// logging, EmuEnvState, config, apps list, users). Idempotent.
    func runSessionInit() {
        guard !sessionInitialized else { return }
        let initStart = Date()
        Vita3KCore.applyRuntimeOptions()
        let rc = Vita3KCore.sessionInit(basePath: basePath, staticAssets: Bundle.main.bundlePath)
        Probe.mark("session-init took \(Int(Date().timeIntervalSince(initStart) * 1000)) ms")
        // Host-readable probe (like app-probe.txt for the self-test).
        if Vita3KCore.loggingEnabled {
            let report = Vita3KCore.sessionReport()
            let probe = "rc=\(rc)\nreport:\n\(report)\n"
            try? probe.write(to: URL(fileURLWithPath: basePath).appendingPathComponent("session-probe-report.txt"),
                             atomically: true, encoding: .utf8)
        }
        Probe.mark("session-init rc=\(rc)")
        if rc == 0 {
            sessionInitialized = true
            // Populates `version`: the diagnostic buttons (JIT, Memória,
            // Poll StikDebug) are disabled while it is empty.
            loadVersion()
            appendLog("session init ok (v\(version))")
            refreshApps()
            provisionAndBoot()
        } else {
            appendLog("session init failed (code \(rc))")
        }
    }

    /// Installed apps, re-read from the core's apps list.
    func refreshApps() {
        guard !isDeleting, !isImporting else { return }
        refreshLoggingMode()
        let list = Vita3KCore.sessionGetApps()
        var parsed: [AppInfo] = []
        for line in list.split(separator: "\n") where !line.isEmpty {
            let parts = line.split(separator: "|", maxSplits: 1).map(String.init)
            guard let titleId = parts.first, !titleId.isEmpty else { continue }
            parsed.append(AppInfo(titleId: titleId, title: parts.count > 1 ? parts[1] : titleId))
        }
        apps = parsed
        firmwareMask = Vita3KCore.sessionFirmwareMask()
        if let sel = selectedAppTitleId, !parsed.contains(where: { $0.titleId == sel }) {
            selectedAppTitleId = nil
        }
        appendLog("apps: \(parsed.count) instalado(s)")
    }

    private func refreshLoggingMode() {
        let mode = Vita3KCore.loggingMode()
        guard mode != loggingMode else { return }
        loggingMode = mode
        Probe.mark("logging-mode: \(mode.rawValue)")
    }

    /// Startup and the Files watcher use the same queue and durable receipts.
    func provisionAndBoot() {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["VITA3K_UI_TEST"] == "1" {
            startControlPoller()
            return
        }
        #endif
        Task { @MainActor in
            defer { startControlPoller() }
            let staging = Vita3KCore.sessionStagingPath()
            guard !staging.isEmpty else { return }
            await processStagedImports(staging: staging, recoverInterrupted: true)
            guard let title = readAutoBootTitle(), apps.contains(where: { $0.titleId == title }) else { return }
            appendLog("auto-boot marker: \(title)")
            autoBootTitle = title
        }
    }

    /// Reads the unattended auto-boot title (Documents/auto-boot.txt).
    private func readAutoBootTitle() -> String? {
        let marker = (basePath as NSString).appendingPathComponent("auto-boot.txt")
        guard let raw = try? String(contentsOfFile: marker, encoding: .utf8) else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    /// Polls imports/ctl-stop.txt (1s cadence): a present file triggers a
    /// session stop; its first line (empty = just stop) names the next title
    /// to launch in the same process. Exposed via ctlNextTitle so the UI can
    /// dismiss the surface and present the new one. Also installs content
    /// dropped into imports/ from outside the app (Files app).
    private func startControlPoller() {
        Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.sessionInitialized else { return }
                // Native installation owns the core lock. Do not wait for it
                // from the main actor (including staging/logging queries).
                guard !self.isDeleting, !self.isImporting, !self.isSyncingSaves, !self.isPreparingGame else { continue }
                refreshLoggingMode()
                let staging = Vita3KCore.sessionStagingPath()
                guard !staging.isEmpty else { continue }
                // Host-driven regression run, using the same action as the
                // diagnostic button. Defer while a game owns the runtime.
                let memoryRequest = (staging as NSString).appendingPathComponent("ctl-memory-test.txt")
                if !memRunning && Vita3KCore.sessionPhase() == 0 &&
                    FileManager.default.fileExists(atPath: memoryRequest) {
                    try? FileManager.default.removeItem(atPath: memoryRequest)
                    #if targetEnvironment(simulator)
                    runMemoryTest()
                    #else
                    pollStikDebugAndRunMemoryTest()
                    #endif
                }
                // Content dropped into imports/ while the app runs (the Files
                // app can copy into the sandbox: UIFileSharingEnabled) is
                // installed on the fly using the same receipts as startup.
                if !memRunning && Vita3KCore.sessionPhase() == 0 && !isImporting {
                    #if targetEnvironment(simulator)
                    if ProcessInfo.processInfo.environment["VITA3K_UI_TEST"] != "1" {
                        await processStagedImports(staging: staging)
                    }
                    #else
                    await processStagedImports(staging: staging)
                    #endif
                }
                if saveSync.needsSync { await syncSaves() }
                let file = (staging as NSString).appendingPathComponent("ctl-stop.txt")
                guard let raw = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(atPath: file)
                let next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                Probe.mark("ctl-stop: \(next.isEmpty ? "stop" : "stop → \(next)")")
                appendLog("ctl: stop\(next.isEmpty ? "" : " → \(next)")")
                Vita3KCore.sessionStop()
                ctlNextTitle = next.isEmpty ? "" : next
            }
        }
    }

    /// Consume each source after its attempt, regardless of the result.
    /// Receipts prevent retries of retained legacy or interrupted sources.
    func processStagedImports(staging: String, recoverInterrupted: Bool = false) async {
        guard !isImporting, !isDeleting, !memRunning, !isSyncingSaves, !isPreparingGame, !isGamePresented,
              !Vita3KCore.sessionIsActive() else { return }
        var installed = false
        var messages: [String] = []
        var succeeded = true
        defer {
            isImporting = false
            if installed { refreshApps() }
            if !messages.isEmpty {
                importResult = ImportResult(succeeded: succeeded, message: messages.joined(separator: "\n\n"))
            }
        }
        do {
            let directory = URL(fileURLWithPath: staging, isDirectory: true)
            var store = try ImportStore(directory: directory)
            if recoverInterrupted {
                let interrupted = try store.recoverInterrupted()
                messages += interrupted
                if !interrupted.isEmpty { succeeded = false }
            }
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                .filter { ["zip", "vpk", "pkg", "pup", "bin", "rif"].contains($0.pathExtension.lowercased())
                    || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let candidates = try files.compactMap { url -> (URL, ImportStore.Fingerprint)? in
                let fingerprint = try ImportStore.Fingerprint(url: url)
                return store.shouldImport(url.lastPathComponent, fingerprint: fingerprint) ? (url, fingerprint) : nil
            }
            // Files may still be arriving from the Files app. Wait for a stable
            // size/mtime before handing an archive to the native reader.
            if !candidates.isEmpty {
                isImporting = true
                try await Task.sleep(for: .seconds(2))
            }
            for (url, fingerprint) in candidates {
                guard try ImportStore.Fingerprint(url: url) == fingerprint else { continue }
                let name = url.lastPathComponent
                let alreadyInstalled = apps.contains(where: { $0.titleId == url.deletingPathExtension().lastPathComponent })
                appendLog("imports: instalando \(name)…")
                installed = true
                let outcome = await Task.detached(priority: .userInitiated) {
                    ImportStaging.consume(url, in: directory) { path in
                        // Migrate old title-named archives that predate receipts.
                        if alreadyInstalled { return (0, L10n.text("O jogo já está instalado.")) }
                        return Vita3KCore.sessionInstall(stagedPath: path, replaceExisting: false)
                    }
                }.value
                messages.append(outcome.message)
                succeeded = succeeded && outcome.succeeded
                appendLog("imports: \(outcome.message)")
            }
            lastAutomaticImportError = nil
        } catch {
            let message = L10n.format("Não foi possível concluir a importação: %@", error.localizedDescription)
            if message != lastAutomaticImportError { messages.append(message) }
            lastAutomaticImportError = message
            succeeded = false
        }
    }

    func reportImportFailure(_ message: String) {
        importResult = ImportResult(succeeded: false, message: message)
    }

    /// Keep security-scoped access alive until the coordinated background copy
    /// finishes. Neither a multi-GB copy nor the core lock may block UIKit.
    func importFile(_ url: URL) {
        guard sessionInitialized, !isImporting, !isDeleting, !memRunning, !isSyncingSaves, !isPreparingGame, !isGamePresented,
              !Vita3KCore.sessionIsActive() else {
            reportImportFailure(L10n.text("Aguarde a operação em andamento e encerre o jogo antes de importar."))
            return
        }
        let staging = Vita3KCore.sessionStagingPath()
        guard !staging.isEmpty else {
            reportImportFailure(L10n.text("Não foi possível acessar a pasta de importação."))
            return
        }
        isImporting = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
                isImporting = false
                refreshApps()
            }
            do {
                let directory = URL(fileURLWithPath: staging, isDirectory: true)
                let staged = try await Task.detached(priority: .userInitiated) {
                    try ImportStaging.copy(url, into: directory)
                }.value
                let outcome = await Task.detached(priority: .userInitiated) {
                    ImportStaging.consume(staged, in: directory) { path in
                        Vita3KCore.sessionInstall(stagedPath: path)
                    }
                }.value
                importResult = ImportResult(succeeded: outcome.succeeded, message: outcome.message)
                appendLog("install: \(outcome.message)")
            } catch {
                reportImportFailure(L10n.format("Não foi possível importar %@: %@", url.lastPathComponent, error.localizedDescription))
            }
        }
    }

    /// Saves a license from a pasted zRIF key (needed by retail PKGs).
    func importZRIF(_ text: String) {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard sessionInitialized, !isImporting, !isDeleting, !memRunning, !isSyncingSaves, !isPreparingGame, !isGamePresented,
              !Vita3KCore.sessionIsActive() else {
            reportImportFailure(L10n.text("Aguarde a operação em andamento e encerre o jogo antes de importar."))
            return
        }
        isImporting = true
        Task { @MainActor in
            defer { isImporting = false }
            let (rc, report) = await Task.detached(priority: .userInitiated) {
                Vita3KCore.sessionInstallZRIF(key)
            }.value
            let message = ImportReport.message(rc: rc, report: report)
            importResult = ImportResult(succeeded: rc == 0, message: message)
            appendLog("zRIF: \(message)")
        }
    }

    var coreVersion: String {
        Vita3KCore.CText.string(vita3k_ios_version())
    }

    var jitReport: String {
        Vita3KCore.CText.string(vita3k_ios_jit_report())
    }

    /// Base directory the core uses for its Root (vita/ logs/ config/ ...).
    var basePath: String {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.path
        }
        return FileManager.default.currentDirectoryPath
    }

    func loadVersion() {
        Probe.mark("before-version-call")
        version = coreVersion
        Probe.mark("after-version-call: \(version)")
    }

    func runSelfTest() {
        guard phase != .running, !isSyncingSaves, !isPreparingGame, !isGamePresented else { return }
        phase = .running
        failure = ""
        report = ""
        Probe.mark("before-selftest base=\(basePath)")

        // Runs on a background thread: on device the self-test can observe
        // a process suspended by the debugger (StikDebug brk protocol);
        // the main thread must stay responsive (like runMemoryTest).
        let basePath = self.basePath
        Task.detached(priority: .userInitiated) { [weak self] in
            let capacity = 8192
            var buffer = [Int8](repeating: 0, count: capacity)
            let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                vita3k_ios_self_test(basePath, ptr.baseAddress!, capacity)
            }

            await MainActor.run {
                guard let self else { return }
                if rc == 0 {
                    self.report = Vita3KCore.CText.string(buffer)
                    self.phase = .passed
                } else {
                    self.failure = L10n.format("código %d (%@)", rc, self.explain(rc))
                    if buffer.contains(where: { $0 != 0 }) {
                        self.report = Vita3KCore.CText.string(buffer)
                    }
                    self.phase = .failed
                }

                // Host-readable probe (step 4 smoke test): mirrors the UI state.
                let probe = "rc=\(rc)\nversion: \(self.coreVersion)\nfailure: \(self.failure)\nreport:\n\(self.report)\n"
                try? probe.write(to: URL(fileURLWithPath: basePath).appendingPathComponent("app-probe.txt"),
                                 atomically: true, encoding: .utf8)

                self.appendLog("self_test rc=\(rc) base=\(basePath)")
                if let logFile = self.lastLogLine() {
                    self.appendLog("log file: \(logFile)")
                }
            }
        }
    }

    func refreshJitReport() {
        report = jitReport
        appendLog("jit_report: \(jitReport.split(separator: "\n").first ?? "")")
    }

    /// Step 5: memory-model validation (4 GiB reservation, 4K-on-16K guest
    /// pages, fault policy, pressure, dual-map JIT arena bootstrap).
    /// Runs on a background queue: on device `prepare()` executes the
    /// StikDebug `brk` protocol, which stops the whole process — the main
    /// thread must stay responsive.
    func runMemoryTest() {
        guard !memRunning, !isSyncingSaves, !isPreparingGame, !isGamePresented else { return }
        memRunning = true
        memReport = ""
        memPassed = nil
        Probe.mark("before-memorytest base=\(basePath)")
        let basePath = self.basePath
        Task.detached(priority: .userInitiated) { [weak self] in
            let capacity = 16384
            var buffer = [Int8](repeating: 0, count: capacity)
            let rc = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
                vita3k_ios_memory_test(basePath, ptr.baseAddress!, capacity)
            }
            let text = rc == 0 || buffer.contains(where: { $0 != 0 })
                ? Vita3KCore.CText.string(buffer)
                : ""
            let ok = rc == 0
            Probe.mark("memorytest-done rc=\(rc)")
            // Host-readable probe, like app-probe.txt for the self-test.
            let probe = "rc=\(rc)\nreport:\n\(text)\n"
            try? probe.write(to: URL(fileURLWithPath: basePath).appendingPathComponent("memory-probe-report.txt"),
                             atomically: true, encoding: .utf8)
            await MainActor.run {
                guard let self else { return }
                self.memRunning = false
                self.memReport = text
                self.memPassed = ok
                self.appendLog("memory_test rc=\(rc)")
            }
        }
    }

    /// Same flow as JitDynTest's "Poll StikDebug": waits up to 60 s for a
    /// StikDebug session to attach (CS_DEBUGGED=1), then runs the memory
    /// test. Handles the attach-after-launch race on device.
    func pollStikDebugAndRunMemoryTest() {
        guard !memRunning else { return }
        memRunning = true
        memReport = ""
        memPassed = nil
        appendLog("polling CS_DEBUGGED (até 60s) — app em 1º plano…")
        Task.detached(priority: .userInitiated) { [weak self] in
            let deadline = Date().addingTimeInterval(60)
            var seen: Int32 = -1
            while Date() < deadline {
                seen = Int32(vita3k_ios_cs_debugged())
                if seen == 1 { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            if seen == 1 {
                // Grace period: CS_DEBUGGED is set by the debugger before
                // the StikDebug script has hooked the JIT26 protocol; give
                // the script a moment to arm.
                try? await Task.sleep(for: .seconds(3))
            }
            await MainActor.run {
                guard let self else { return }
                if seen == 1 {
                    self.appendLog("CS_DEBUGGED=1 — rodando memory test…")
                    self.memRunning = false
                    self.runMemoryTest()
                } else {
                    self.memRunning = false
                    self.memPassed = false
                    self.memReport = L10n.text("CS_DEBUGGED não ficou 1 em 60s (sessão não anexou a este processo). Anexe o StikDebug (universal.js) ao Flowyr com o app em 1º plano e tente de novo.")
                }
            }
        }
    }

    private func explain(_ rc: Int32) -> String {
        switch rc {
        case -1: return L10n.text("logging não inicializou")
        case -2: return L10n.text("log file não foi criado")
        case -3: return L10n.text("buffer de relatório pequeno demais")
        default: return L10n.text("erro desconhecido")
        }
    }

    private func lastLogLine() -> String? {
        let logsDir = (basePath as NSString).appendingPathComponent("logs")
        let url = URL(fileURLWithPath: logsDir).appendingPathComponent("vita3k.log")
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = contents.split(separator: "\n").map(String.init)
        return lines.last
    }

    private func appendLog(_ line: String) {
        log += line + "\n"
    }
}
