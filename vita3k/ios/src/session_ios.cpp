// Vita3K emulator project
// Copyright (C) 2026 Vita3K team
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program; if not, write to the Free Software Foundation, Inc.,
// 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

// Step 7 of the iOS port (ios-plan.md): the C facade that connects the
// UIKit/SwiftUI app to the core's AppSessionController, mirroring the
// Android bootstrap (vita3k/android/jni):
//
//   session_init  = NativeLib.init: Root from the app sandbox, logging,
//                   EmuEnvState, config, apps list, users, compat DB
//   session_launch = SDL_main's begin_launch -> initialize_renderer ->
//                   initialize_runtime -> load_and_run, run on a background
//                   thread (the app main thread must stay responsive: on
//                   device the JIT arena preparation executes the StikDebug
//                   brk protocol, which stops the whole process)
//   session_stop  = AppSessionController::stop
//   session_install = document picker staging -> app content (directory or
//                   zip of eboot.bin + sce_sys/param.sfo), .pkg, .pup
//
// Sandbox layout (Root), under the app's Documents directory (base_path):
//   base/vita/     Vita FS (ux0/app, ux0/user, vs0 firmware, ...)
//   base/logs/     core + shader/texture logs
//   base/config/   config.yml, per-app configs, apps cache
//   base/shared/   shared textures
//   base/cache/    shader/compat caches
//   base/patch/    game patches
//   base/imports/  import staging area: document picker copies, plus the
//                  drop zone of the Files app (UIFileSharingEnabled exposes
//                  the whole sandbox there) — new .zip/.vpk/.pkg/.pup are
//                  installed on the fly (app-side watcher) / at launch
// The absolute container path is never persisted as identity: the app
// re-resolves base_path on every launch and the core only stores the
// relative layout under it.

#include "ios/bridge.h"
#include "ios/diagnostics.h"
#include "ios/frame_host.h"
#include "ios/jit_memory.h"
#include <ios/ime.h>
#include <ios/import_archive.h>

#include <app/functions.h>
#include <app/session_controller.h>
#include <compat/functions.h>
#include <compat/state.h>
#include <config/functions.h>
#include <config/settings.h>
#include <ctrl/functions.h>
#include <ctrl/state.h>
#include <display/state.h>
#include <emuenv/state.h>
#include <ime/functions.h>
#include <ime/state.h>
#include <kernel/state.h>
#include <io/state.h>
#include <kernel/thread/thread_state.h>
#include <motion/event_handler.h>
#include <modules/module_parent.h>
#include <np/state.h>
#include <np/trophy/collection.h>
#include <packages/functions.h>
#include <packages/license.h>
#include <packages/pkg.h>
#include <packages/sfo.h>
#include <renderer/functions.h>
#include <renderer/state.h>
#include <touch/functions.h>
#include <touch/state.h>

#include <SDL3/SDL.h>
#include <SDL3/SDL_events.h>
#include <SDL3/SDL_gamepad.h>
#include <SDL3/SDL_sensor.h>

// The app provides its own UIApplicationMain (no SDL_main on iOS): mark
// main as ready for SDL explicitly. Declared in SDL_main.h, which must NOT
// be included here (it pulls the SDL_main shim into the dylib).
extern "C" void SDL_SetMainReady(void);

#include <spdlog/spdlog.h>

#include <util/exit_code.h>
#include <util/fs.h>
#include <util/log.h>
#include <util/diagnostics.h>

#include <sys/utsname.h>
#include <mach/mach.h>
#include <os/proc.h>

#include <sys/param.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// Two-level stringify so the gitver.h macro values are expanded before being
// turned into string literals.
#define VITA3K_STR3(x) #x
#define VITA3K_STR2(x) VITA3K_STR3(x)
#define VITA3K_STR(x) VITA3K_STR2(x)

#if __has_include("gitver.h")
#include "gitver.h"
#define VITA3K_VERSION_STRING VITA3K_STR(APP_VER_HI) "." VITA3K_STR(APP_VER_MID) "." VITA3K_STR(APP_VER_LO) "-" VITA3K_STR(APP_NUMBER)
#else
#define VITA3K_VERSION_STRING "unknown"
#endif

// Facade phase (what the UI shows); the AppSessionController's own phase is
// finer-grained and not directly queryable.
enum class FacadePhase : int {
    Idle = 0,
    Starting = 1,
    Running = 2,
    Stopping = 3,
    Failed = 4,
};

struct Session {
    std::mutex lock; // guards everything below

    bool initialized = false;
    std::string base_path;
    std::string static_assets_path;
    Root root;
    std::unique_ptr<EmuEnvState> emuenv;
    std::unique_ptr<app::AppSessionController> controller;

    // Owned by the active render session (the renderer state holds a
    // non-owning pointer into it).
    std::unique_ptr<vita::ios::IOSFrameHost> frame_host;

    // Serializes the launch thread and the stop thread on the session.
    std::mutex op_lock;
    std::atomic<bool> stop_requested{ false };
    std::atomic<bool> stop_in_flight{ false };
    std::atomic<FacadePhase> phase{ FacadePhase::Idle };
    std::atomic<bool> launch_failed{ false };
    bool background = false; // s.lock; independent of the current launch phase
    uint64_t launch_generation = 0;

    std::string launch_app_path;
    std::string last_error;
};

Session &state() {
    static Session s;
    return s;
}

void write_report_or(char *out, size_t out_size, const std::string &report, bool &fits) {
    fits = out && out_size > 0 && report.size() + 1 <= out_size;
    if (fits)
        std::snprintf(out, out_size, "%s", report.c_str());
}

std::string format_app_version() {
    return VITA3K_VERSION_STRING;
}

// Temporary install data is removed on every return/exception. Each attempt
// owns a unique directory, including when a previous process was interrupted.
struct ImportDirectory {
    fs::path path;
    explicit ImportDirectory(const fs::path &parent) {
        fs::create_directories(parent);
        std::string pattern = (parent / ".install-XXXXXX").string();
        if (!::mkdtemp(pattern.data()))
            throw std::runtime_error("Não foi possível criar a pasta temporária de importação.");
        path = pattern;
    }
    ~ImportDirectory() {
        boost::system::error_code error;
        if (!path.empty())
            fs::remove_all(path, error);
    }
};

std::vector<uint8_t> read_file_bytes(const fs::path &path, std::string &err) {
    std::vector<uint8_t> bytes;
    if (!fs_utils::read_data(path, bytes)) {
        err = "failed to read " + fs_utils::path_to_utf8(path);
        return {};
    }
    return bytes;
}

// ------------------------------------------------------------------
// App content recognition + param.sfo parsing (host side)
// ------------------------------------------------------------------

bool dir_has_app_content(const fs::path &dir) {
    return fs::exists(dir / "eboot.bin") && fs::exists(dir / "sce_sys" / "param.sfo");
}

// The archive (or picked folder) may wrap the app content in one or more
// single-child directories (e.g. "app/PCSE00064" in NoNpDRM zips, or a
// release folder); descend through them until the content root shows up.
bool find_app_content_root(const fs::path &dir, fs::path &content_root, std::string &err) {
    fs::path current = dir;
    for (int depth = 0; depth < 4; ++depth) {
        if (dir_has_app_content(current)) {
            content_root = current;
            return true;
        }

        std::vector<fs::path> subdirs;
        if (fs::exists(current)) {
            for (const auto &entry : fs::directory_iterator(current)) {
                if (entry.is_directory())
                    subdirs.push_back(entry.path());
            }
        }
        if (subdirs.size() != 1)
            break;
        current = subdirs[0];
    }

    err = "no app content found (expected eboot.bin + sce_sys/param.sfo, "
          "optionally nested in single folders like 'app/PCSE00064'): " + fs_utils::path_to_utf8(dir);
    return false;
}

bool read_sfo_app_info(const fs::path &sfo_path, std::string &title_id, std::string &category,
    std::string &title, std::string &err) {
    if (fs::file_size(sfo_path) > 16 * 1024 * 1024) {
        err = "param.sfo excede o tamanho máximo permitido";
        return false;
    }
    std::vector<uint8_t> bytes = read_file_bytes(sfo_path, err);
    if (bytes.empty()) {
        if (err.empty())
            err = "failed to read " + fs_utils::path_to_utf8(sfo_path);
        return false;
    }

    SfoFile file;
    if (!sfo::load(file, bytes)) {
        err = "failed to parse param.sfo";
        return false;
    }

    if (!sfo::get_data_by_key(title_id, file, "TITLE_ID"))
        title_id.clear();
    sfo::get_data_by_key(category, file, "CATEGORY");
    sfo::get_data_by_key(title, file, "TITLE");

    if (title_id.empty()) {
        err = "param.sfo has no TITLE_ID";
        return false;
    }
    if (!title_id.empty() && std::all_of(title_id.begin(), title_id.end(), [](unsigned char c) {
            return std::isalnum(c) || c == '_';
        })
        && title_id.size() <= 16) {
        return true;
    }

    err = "TITLE_ID is not a valid directory name: " + title_id;
    return false;
}

size_t dir_size_bytes(const fs::path &dir) {
    size_t total = 0;
    if (!fs::exists(dir))
        return 0;
    for (auto it = fs::recursive_directory_iterator(dir); it != fs::recursive_directory_iterator(); ++it) {
        if (it->is_regular_file()) {
            try {
                total += static_cast<size_t>(fs::file_size(it->path()));
            } catch (const std::exception &) {
                // Unreadable file: treat as zero, the copy below reports it.
            }
        }
    }
    return total;
}

bool install_app_content(EmuEnvState &emuenv, const fs::path &content_root, bool replace_existing, std::string &report) {
    std::string title_id, category, title, err;
    if (!read_sfo_app_info(content_root / "sce_sys" / "param.sfo", title_id, category, title, err)) {
        report += "sfo: " + err + "\n";
        return false;
    }
    // The core lists and launches every directory under ux0/app regardless of
    // the param.sfo CATEGORY (gp retail, gd homebrew, ...), so we accept any
    // app content and just record the category for the report.
    if (category.empty())
        report += "sfo: no CATEGORY in param.sfo (assuming app)\n";

    const fs::path vita_fs = emuenv.vita_fs_path / "";
    const fs::path dest = vita_fs / "ux0" / "app" / title_id;

    if (!replace_existing && dir_has_app_content(dest)) {
        report += "Jogo já instalado: " + title_id + ". Conteúdo preservado.\n";
        return true;
    }
    const size_t content_size = dir_size_bytes(content_root);
    const size_t free_space = fs::space(vita_fs).available;
    if (content_size > free_space) {
        report += fmt::format("space: need {} bytes, only {} available\n", content_size, free_space);
        return false;
    }

    ImportDirectory pending(vita_fs / "ux0" / ".imports");
    const auto prepared = pending.path / "content";
    fs::create_directories(prepared);
    if (!fs_utils::copy_directory_contents(content_root, prepared, fs::copy_options::overwrite_existing)) {
        report += "Falha ao copiar o conteúdo do jogo. Verifique o espaço disponível.\n";
        return false;
    }

    // NoNpDRM content ships the klicensee (work.bin) under sce_sys/package/
    // (regardless of the param.sfo category). The raw-copy path skips the
    // pkg pipeline, so run the same f00d decryption it uses: eboot.bin
    // becomes plaintext on disk and the app loads without a PSN license.
    const fs::path work_bin = prepared / "sce_sys" / "package" / "work.bin";
    if (fs::exists(work_bin)) {
        emuenv.app_info.app_title_id = title_id;
        emuenv.app_info.app_content_id = title_id;
        emuenv.app_info.app_category = category;
        LOG_INFO("iOS install: NoNpDRM content for {}, decrypting", title_id);
        if (!decrypt_install_nonpdrm(emuenv, work_bin, prepared)) {
            report += "nonpdrm: decryption failed for " + title_id + "\n";
            return false;
        }
        report += "nonpdrm: decrypted " + title_id + "\n";
    }

    // Keep any installed copy intact until validation, copy and decryption
    // have succeeded. Roll back if committing the replacement fails.
    fs::create_directories(dest.parent_path());
    const auto previous = pending.path / "previous";
    const bool replacing = fs::exists(dest);
    if (replacing)
        fs::rename(dest, previous);
    try {
        fs::rename(prepared, dest);
    } catch (...) {
        if (replacing) {
            boost::system::error_code error;
            fs::rename(previous, dest, error);
            if (error) {
                report += "A cópia anterior foi preservada em " + previous.string() + "\n";
                pending.path.clear();
            }
        }
        throw;
    }

    report += fmt::format("installed {} ('{}', category {}) to ux0/app/{} ({} bytes)\n", title_id, title, category, title_id, content_size);
    LOG_INFO("iOS install: {} ('{}', category {}) -> ux0/app/{}", title_id, title, category, title_id);
    return true;
}

// ------------------------------------------------------------------
// Launch thread
// ------------------------------------------------------------------

// Logs the process memory footprint every few seconds while a game runs, so a
// jetsam (out-of-memory) kill can be traced in vita3k.log: how much RAM the
// app uses in total, how much of it is guest memory, and how much headroom iOS
// still reports.
void log_memory_usage(EmuEnvState &emuenv) {
    using clock = std::chrono::steady_clock;
    static clock::time_point last{};
    const auto now = clock::now();
    if (last != clock::time_point{} && now - last < std::chrono::seconds(3))
        return;
    last = now;

    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS)
        footprint = info.phys_footprint;

    uint64_t guest_bytes = 0;
    size_t guest_regions = 0;
    {
        const std::lock_guard lock(emuenv.mem.protect_mutex);
        for (const auto &entry : emuenv.mem.backing_regions)
            guest_bytes += entry.second.size;
        guest_regions = emuenv.mem.backing_regions.size();
    }

    uint64_t gpu_blocks = 0;
    uint64_t gpu_used = 0;
    if (emuenv.renderer)
        emuenv.renderer->get_memory_stats(gpu_blocks, gpu_used);

    constexpr double mib = 1024.0 * 1024.0;
    LOG_INFO("[mem] footprint={:.0f} MiB, ios_available={:.0f} MiB, guest_reserved={:.0f} MiB in {} regions, gpu_blocks={:.0f} MiB, gpu_used={:.0f} MiB",
        footprint / mib, os_proc_available_memory() / mib, guest_bytes / mib, guest_regions, gpu_blocks / mib, gpu_used / mib);
}

// The worker holds op_lock for its whole life, so a concurrent
// vita3k_ios_session_stop() either runs fully before the launch (session
// inactive: no-op) or waits for the launch to finish, after which the
// launch applies the pending stop itself (stop_requested, set before the
// stop thread blocks on the lock).
void launch_worker(Session &s, const std::string &app_path, int width, int height) {
    std::unique_lock<std::mutex> op(s.op_lock);
    diagnostics::begin_game(app_path);
    s.launch_failed.store(false);
    {
        std::lock_guard<std::mutex> lock(s.lock);
        s.last_error.clear();
    }

    void *metal_layer = vita::ios::take_pending_metal_layer();
    if (!metal_layer) {
        std::lock_guard<std::mutex> lock(s.lock);
        s.last_error = "launch: CAMetalLayer not delivered — call vita3k_ios_frame_host_set_layer on the main thread before starting";
        s.launch_failed.store(true);
        LOG_ERROR("{}", s.last_error);
        s.phase.store(FacadePhase::Failed);
        diagnostics::stage("launch_failed_no_layer");
        logging::set_level(spdlog::level::off);
        return;
    }

    {
        std::lock_guard<std::mutex> lock(s.lock);
        s.frame_host = std::make_unique<vita::ios::IOSFrameHost>(metal_layer, width, height);
    }
    vita::ios::register_active_frame_host(s.frame_host.get());
    vita::ios::IOSFrameHost *const frame_host_ptr = s.frame_host.get();

    std::string error;
    bool session_started = false; // controller has an active session to tear down

    try {
        {
            // Enable this title's logs before launch metadata/license loading.
            std::lock_guard<std::mutex> lock(s.lock);
            Config cfg{};
            cfg = s.emuenv->cfg;
            config::set_current_config(cfg, s.root.get_config_path(), app_path);
            logging::set_level(static_cast<spdlog::level::level_enum>(cfg.current_config.ios_log_level));
        }
        if (!s.controller->begin_launch(AppLaunchRequest{ .app_path = app_path })) {
            error = "launch: app '" + app_path + "' not found in the apps list (install it first)";
        } else {
            session_started = true;
            LOG_INFO("Booting game '{}'", app_path);
            if (diagnostics::enabled()) {
                const auto &cfg = s.emuenv->cfg;
                const auto &cc = cfg.current_config;
                diagnostics::event("effective_config", fmt::format("cpu_opt={} resolution={} surface_sync_disabled={} async_pipeline={} shader_cache={} texture_cache={} fps_hack={} anisotropic={} log_active_shaders={} log_uniforms={} export_textures={}",
                    cc.cpu_opt, cc.resolution_multiplier, cc.disable_surface_sync, cc.async_pipeline_compilation,
                    cc.shader_cache, cc.texture_cache, cc.fps_hack, cc.anisotropic_filtering,
                    cfg.log_active_shaders, cfg.log_uniforms, cfg.export_textures));
                LOG_INFO("Diagnostic game={} mode={} capture={}", app_path, diagnostics::mode_name(), diagnostics::capture_path());
            }

            // SDL runs without its video driver (UIKit owns the screen).
            // Audio was initialized on the main thread in session_init;
            // the adapter opens its output device during late init below.
            // AUDIO also initializes EVENTS, so test for *all* input flags,
            // not just any flag, and avoid accumulating subsystem references
            // each time a title is started.
            constexpr SDL_InitFlags input_flags = SDL_INIT_EVENTS | SDL_INIT_GAMEPAD | SDL_INIT_SENSOR | SDL_INIT_HAPTIC;
            const SDL_InitFlags missing_input_flags = input_flags & ~SDL_WasInit(input_flags);
            if (missing_input_flags) {
                if (!SDL_InitSubSystem(missing_input_flags)) {
                    LOG_ERROR("SDL input subsystems failed: {} (touch and IME still work; gamepads/sensors may be unavailable)", SDL_GetError());
                }
            }

            if (!s.controller->initialize_renderer(*s.frame_host)) {
                error = "launch: renderer (Vulkan/MoltenVK) initialization failed — see vita3k.log";
            } else if (!s.controller->initialize_runtime()) {
                error = "launch: late initialization failed (memory/audio/ngs) — see vita3k.log";
            } else if (!s.controller->load_and_run()) {
                error = "launch: the app failed to load or start (CPU/JIT/modules) — see vita3k.log";
            } else {
                error.clear();
                {
                    std::lock_guard<std::mutex> lock(s.lock);
                    s.controller->set_pause_reason(app::AppSessionPauseReason::Background, s.background);
                    s.phase.store(FacadePhase::Running);
                }
                diagnostics::stage("running");
                if (diagnostics::enabled())
                    diagnostics::event("game_info", fmt::format("title={} title_id={} version={} gpu={} mapping={}",
                        s.emuenv->current_app_title, s.emuenv->io.title_id, s.emuenv->app_info.app_version,
                        s.emuenv->renderer->get_gpu_name(), static_cast<int>(s.emuenv->renderer->mapping_method)));
                LOG_INFO("Game started: {} ({})", s.emuenv ? s.emuenv->current_app_title : "?", app_path);

                // Step 9: pump SDL input events (gamepad, touchpad,
                // sensors) until a stop is requested. Touch and IME input
                // arrives through the vita3k_ios_input_* bridge (main
                // thread) and is consumed by the core directly. The stop
                // thread is blocked on op_lock (held by this worker) until
                // the loop exits on stop_requested, then it runs
                // controller->stop().
                SDL_Event event;
                while (!s.stop_requested.load(std::memory_order_relaxed) &&
                       s.phase.load() == FacadePhase::Running &&
                       s.controller->has_active_session()) {
                    log_memory_usage(*s.emuenv);
                    if (SDL_WaitEventTimeout(&event, 50) <= 0)
                        continue;
                    switch (event.type) {
                    case SDL_EVENT_GAMEPAD_ADDED:
                    case SDL_EVENT_GAMEPAD_REMOVED:
                        refresh_controllers(s.emuenv->ctrl, *s.emuenv);
                        break;
                    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
                        if (event.gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE)
                            s.controller->set_pause_reason(app::AppSessionPauseReason::Menu, true);
                        break;
                    case SDL_EVENT_GAMEPAD_TOUCHPAD_DOWN:
                    case SDL_EVENT_GAMEPAD_TOUCHPAD_MOTION:
                    case SDL_EVENT_GAMEPAD_TOUCHPAD_UP:
                        handle_touchpad_event(s.emuenv->touch, event.gtouchpad);
                        break;
                    case SDL_EVENT_GAMEPAD_SENSOR_UPDATE:
                        handle_motion_event(*s.emuenv, event.gsensor.sensor, event.gsensor);
                        break;
                    case SDL_EVENT_SENSOR_UPDATE:
                        handle_motion_event(*s.emuenv, static_cast<int32_t>(SDL_GetSensorTypeForID(event.sensor.which)), event.sensor);
                        break;
                    default:
                        break;
                    }
                }
            }
        }
    } catch (const std::exception &e) {
        error = std::string("launch: exception during session start: ") + e.what();
    }

    // A stop may have been requested while the launch was in flight (the
    // stop thread set it before blocking on op_lock): apply it here, on
    // this thread, before releasing the lock.
    const bool stop_was_requested = s.stop_requested.exchange(false);

    // Tear down whatever was started (stop() walks back renderer/runtime/
    // app state depending on how far the launch got).
    if (!error.empty() || stop_was_requested) {
        diagnostics::stage(error.empty() ? "stopping" : "launch_failed");
        if (!error.empty()) diagnostics::event("error", error);
        if (session_started) {
            s.controller->stop(error.empty()
                ? app::AppSessionStopReason::UserRequest
                : app::AppSessionStopReason::LaunchFailure);
        }
        diagnostics::stage("ended");
        if (!error.empty()) {
            std::lock_guard<std::mutex> lock(s.lock);
            s.last_error = error;
            LOG_ERROR("{}", error);
            s.phase.store(FacadePhase::Failed);
            s.launch_failed.store(true);
        }
    }

    // On success the session keeps running: the render thread dereferences
    // state->frame (== *s.frame_host) on every frame, and the stop path
    // (vita3k_ios_session_stop) tears the host down only after stop() has
    // joined the render thread. Keep it alive and registered in that case;
    // only drop it here when the session does not continue (launch failure
    // or a stop requested in flight — both already ran controller->stop()).
    if (error.empty() && !stop_was_requested)
        return;

    logging::set_level(spdlog::level::off);

    {
        std::lock_guard<std::mutex> lock(s.lock);
        if (s.frame_host) {
            vita::ios::unregister_active_frame_host(frame_host_ptr);
            s.frame_host.reset();
        }
    }

    if (s.phase.load() != FacadePhase::Running)
        s.phase.store(FacadePhase::Idle);
}

} // namespace

extern "C" {

int vita3k_ios_session_init(const char *base_path, const char *static_assets_path) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);

    if (s.initialized)
        return 0;
    if (!base_path || !static_assets_path)
        return -1;

    // The app provides its own UIApplicationMain: tell SDL that main is
    // ready (main thread) so SDL_Init/SDL_InitSubSystem work. Idempotent.
    SDL_SetMainReady();

    const fs::path base{ base_path };
    const fs::path vita_path = base / "vita" / "";

    s.root.set_static_assets_path(static_assets_path);
    s.root.set_vita_fs_path(vita_path);
    s.root.set_log_path(base / "logs");
    s.root.set_config_path(base / "config");
    s.root.set_shared_path(base / "shared");
    s.root.set_cache_path(base / "cache" / "");
    s.root.set_patch_path(base / "patch" / "");

    try {
        if (!fs::exists(vita_path))
            fs::create_directories(vita_path);
        fs::create_directories(s.root.get_config_path());
        fs::create_directories(s.root.get_cache_path());
        fs::create_directories(s.root.get_log_path() / "shaderlog");
        fs::create_directories(s.root.get_log_path() / "texturelog");
        fs::create_directories(s.root.get_patch_path());
        fs::create_directories(s.root.get_shared_path() / "textures");
        fs::create_directories(base / "imports");
    } catch (const std::exception &e) {
        LOG_ERROR("iOS session init: could not create sandbox layout under '{}': {}", base_path, e.what());
        return -1;
    }

    try {
        diagnostics::initialize(base_path, format_app_version());
    } catch (const std::exception &e) {
        // A full disk must not prevent ordinary emulation.
        std::fprintf(stderr, "Diagnostic initialization failed: %s\n", e.what());
    }
    if (logging::init(s.root, /*use_stdout=*/false) != Success) {
        return -2;
    }
    logging::set_level(spdlog::level::off);
    LOG_INFO("Vita3K iOS session init (version {}, base {})", format_app_version(), base_path);

    // This entry point is called by CoreController on the main actor.
    // SDL_OpenAudioDevice does not initialize the audio subsystem itself.
    // Keep AUDIO alive across game sessions, just like the input subsystems;
    // the core owns the output device/streams, not SDL's process-wide lifetime.
    if (!SDL_WasInit(SDL_INIT_AUDIO) && !SDL_InitSubSystem(SDL_INIT_AUDIO)) {
        LOG_ERROR("iOS SDL audio subsystem initialization failed: {}", SDL_GetError());
    } else {
        LOG_INFO("iOS SDL audio subsystem ready (driver: {})", SDL_GetCurrentAudioDriver());
    }

    s.emuenv = std::make_unique<EmuEnvState>();

    Config cfg{};
    char arg0[] = "vita3k";
    char *argv[] = { arg0, nullptr };
    if (config::init_config(cfg, 1, argv, s.root, false) != Success) {
        LOG_ERROR("iOS session init: failed to initialise config.");
        s.emuenv.reset();
        return -3;
    }

    // A previously persisted config.yml may pin the Vita FS to a stale
    // path (e.g. a previous simulator data container). The iOS sandbox has
    // exactly one location, so always force the fresh root.
    cfg.set_vita_fs_path(vita_path);

    fs::create_directories(cfg.get_vita_fs_path());

    if (!app::init(*s.emuenv, cfg, s.root)) {
        LOG_ERROR("iOS session init: failed to initialise emulated environment.");
        s.emuenv.reset();
        return -4;
    }

    if (diagnostics::enabled()) {
        // Runtime only. No config::serialize_config or custom config writes.
        s.emuenv->compat.log_compat_warn = diagnostics::mode() == diagnostics::Mode::Compat;
    }

    // vulkan_device_info (GPU/mapping info for the settings UI) is only
    // populated by the desktop frontends; the renderer enumerates the
    // MoltenVK device itself at session start.
    if (s.emuenv->cfg.controller_binds.empty() || s.emuenv->cfg.controller_binds.size() != 15
        || s.emuenv->cfg.controller_axis_binds.empty() || s.emuenv->cfg.controller_axis_binds.size() != 6) {
        app::reset_controller_binding(*s.emuenv);
    }

    init_libraries(*s.emuenv);

    if (!app::init_apps_list(*s.emuenv))
        LOG_ERROR("iOS session init: failed to initialise apps list.");

    app::load_users(*s.emuenv);
    if (!app::ensure_current_user(*s.emuenv)) {
        LOG_ERROR("iOS session init: failed to initialize active user.");
        s.emuenv.reset();
        return -5;
    }

    compat::load_from_disk(s.emuenv->compat, std::filesystem::path(s.emuenv->cache_path.string()));

    s.base_path = base_path;
    s.static_assets_path = static_assets_path;
    s.initialized = true;
    s.controller = std::make_unique<app::AppSessionController>(*s.emuenv);

    if (diagnostics::enabled()) {
        struct utsname host{};
        uname(&host);
        diagnostics::event("host", fmt::format("machine={} system={} release={} jit_prepared={}",
            host.machine, host.sysname, host.release, vita::ios::JitMemory::instance().is_prepared()));
        diagnostics::start_sampler([&s] {
            std::string report = fmt::format("facade_phase={} paused={} {}",
                static_cast<int>(s.phase.load()), s.controller->is_paused(), vita::ios::diagnostic_host_snapshot());
            if (diagnostics::mode() != diagnostics::Mode::Compat) return report;
            std::vector<ThreadStatePtr> threads;
            {
                std::unique_lock kernel_lock(s.emuenv->kernel.mutex, std::try_to_lock);
                if (!kernel_lock.owns_lock()) return report + " kernel_snapshot=busy";
                report += fmt::format(" threads_total={}", s.emuenv->kernel.threads.size());
                for (const auto &[id, thread] : s.emuenv->kernel.threads) {
                    if (threads.size() == 64) break;
                    threads.push_back(thread);
                }
            }
            for (const auto &thread : threads) {
                const auto registers = thread->diagnostic_pc_lr.load(std::memory_order_relaxed);
                const auto state = thread->diagnostic_stage_nid.load(std::memory_order_relaxed);
                std::unique_lock thread_lock(thread->mutex, std::try_to_lock);
                report += fmt::format(" [tid={} status={} stage={} pc={:08x} lr={:08x} nid={:08x} progress={}]",
                    thread->id, thread_lock.owns_lock() ? static_cast<int>(thread->status) : -1,
                    state >> 32, registers >> 32, uint32_t(registers), uint32_t(state), thread->diagnostic_progress.load(std::memory_order_relaxed));
            }
            return report;
        });
    }

    LOG_INFO("Vita3K iOS session initialised.");
    return 0;
}

int vita3k_ios_session_deinit(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized)
        return 0;
    if (s.controller && s.controller->has_active_session())
        return -1;

    diagnostics::stop_sampler();
    s.controller.reset();
    if (s.frame_host) {
        // No active session (checked above) means the render thread is gone.
        vita::ios::unregister_active_frame_host(s.frame_host.get());
        s.frame_host.reset();
    }
    s.emuenv.reset();
    s.initialized = false;
    s.phase.store(FacadePhase::Idle);
    return 0;
}

int vita3k_ios_session_staging_path(char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized)
        return -1;

    const fs::path staging = fs::path(s.base_path) / "imports" / "";
    try {
        fs::create_directories(staging);
    } catch (const std::exception &e) {
        LOG_ERROR("iOS staging: could not create '{}': {}", fs_utils::path_to_utf8(staging), e.what());
        return -1;
    }

    const std::string report = fs_utils::path_to_utf8(staging);
    bool fits = false;
    write_report_or(out, out_size, report, fits);
    return fits ? 0 : -4;
}

int vita3k_ios_session_install(const char *staged_path, int replace_existing, char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    std::string report;
    auto fail = [&](int code, const std::string &detail) -> int {
        report += detail + "\n";
        LOG_ERROR("iOS install: {}", detail);
        bool fits = false;
        write_report_or(out, out_size, report, fits);
        return fits ? code : -5;
    };
    if (!s.initialized || !s.emuenv || !staged_path)
        return fail(-1, "O emulador não está pronto para importar conteúdo.");
    if (s.phase.load() != FacadePhase::Idle && s.phase.load() != FacadePhase::Failed)
        return fail(-1, "Encerre o jogo antes de importar conteúdo.");

    // Never unwind a C++ filesystem/decompression exception through Swift.
    try {
        const fs::path source{ staged_path };
        if (!fs::exists(source))
            return fail(-2, "Arquivo de importação não encontrado: " + source.string());
        std::string ext = source.extension().string();
        std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
        fs::path content_dir;
        std::unique_ptr<ImportDirectory> extraction;
        if (fs::is_directory(source)) {
            content_dir = source;
        } else if (ext == ".zip" || ext == ".vpk") {
            extraction = std::make_unique<ImportDirectory>(fs::path(s.base_path) / "imports");
            std::string error;
            if (!ios::import::extract_zip(source.string(), extraction->path.string(), error))
                return fail(-3, error);
            content_dir = extraction->path;
        } else if (ext == ".pkg") {
            // Retail packages are encrypted: they need the license (work.bin /
            // zRIF) imported beforehand. Homebrew packages need none.
            std::string zrif = find_pkg_zrif(source, s.emuenv->vita_fs_path);
            if (zrif.empty()) {
                const std::string content_id = read_pkg_content_id(source);
                if (content_id.size() < 16)
                    return fail(-2, "Arquivo PKG inválido ou corrompido.");
                if (content_id.substr(7, 9).starts_with("PCS"))
                    return fail(-6, "Este PKG precisa de uma licença (" + content_id + "). Toque em + e escolha \"Importar licença (work.bin)\" ou \"Inserir chave zRIF\"; depois importe o PKG de novo.");
            }
            if (!install_pkg(source, *s.emuenv, zrif, [](float) {}))
                return fail(-4, "Não foi possível instalar o PKG. Verifique o arquivo e a licença.");
            report += "PKG instalado: " + source.filename().string() + "\n";
        } else if (ext == ".bin" || ext == ".rif") {
            // NoNpDrm work.bin / .rif license: stored under ux0/license so
            // packages and installed games can find it.
            if (fs::file_size(source) < sizeof(SceNpDrmLicense))
                return fail(-2, "Arquivo de licença inválido (tamanho incorreto).");
            if (!copy_license(*s.emuenv, source) || s.emuenv->license_content_id.size() < 16)
                return fail(-4, "Não foi possível instalar a licença. O arquivo pode estar corrompido.");
            report += "Licença instalada: " + s.emuenv->license_content_id + "\n";
        } else if (ext == ".pup") {
            const auto version = install_pup(fs::path(s.emuenv->vita_fs_path), source);
            if (version.empty())
                return fail(-4, "Não foi possível instalar o firmware PUP.");
            report += "Firmware instalado: " + version + "\n";
        } else {
            return fail(-2, "Formato não suportado. Selecione uma pasta de jogo, ZIP, VPK, PKG, PUP ou uma licença (work.bin).");
        }
        if (!content_dir.empty()) {
            fs::path root;
            std::string error;
            if (!find_app_content_root(content_dir, root, error))
                return fail(-2, error);
            if (!install_app_content(*s.emuenv, root, replace_existing != 0, report))
                return fail(-4, "Não foi possível instalar o conteúdo do jogo.");
        }
        if (!app::scan_apps(*s.emuenv))
            LOG_WARN("iOS install: apps rescan after install failed.");
        bool fits = false;
        write_report_or(out, out_size, report, fits);
        return fits ? 0 : -5;
    } catch (const std::exception &error) {
        return fail(-4, std::string("Falha na importação: ") + error.what());
    } catch (...) {
        return fail(-4, "Falha inesperada na importação.");
    }
}

int vita3k_ios_session_install_zrif(const char *zrif, char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    std::string report;
    auto fail = [&](int code, const std::string &detail) -> int {
        report += detail + "\n";
        LOG_ERROR("iOS zRIF install: {}", detail);
        bool fits = false;
        write_report_or(out, out_size, report, fits);
        return fits ? code : -5;
    };
    if (!s.initialized || !s.emuenv || !zrif)
        return fail(-1, "O emulador não está pronto para importar conteúdo.");
    try {
        std::string key(zrif);
        key.erase(std::remove_if(key.begin(), key.end(), [](unsigned char c) { return std::isspace(c); }), key.end());
        if (!validate_zrif(key))
            return fail(-2, "Chave zRIF inválida.");
        if (!create_license(*s.emuenv, key))
            return fail(-4, "Não foi possível instalar a licença a partir da chave zRIF.");
        report += "Licença instalada a partir da chave zRIF.\n";
        bool fits = false;
        write_report_or(out, out_size, report, fits);
        return fits ? 0 : -5;
    } catch (const std::exception &error) {
        return fail(-4, std::string("Falha na importação: ") + error.what());
    } catch (...) {
        return fail(-4, "Falha inesperada na importação.");
    }
}

int vita3k_ios_session_get_apps(char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv)
        return -1;

    std::string report;
    for (const auto &app : app::get_apps(*s.emuenv)) {
        report += app.title_id + "|" + app.title + "\n";
    }

    bool fits = false;
    write_report_or(out, out_size, report, fits);
    return fits ? 0 : -4;
}

namespace {
std::string clean_field(std::string text) {
    for (char &c : text)
        if (c == '\t' || c == '\n' || c == '\r')
            c = ' ';
    return text;
}
} // namespace

int vita3k_ios_session_trophies(char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv)
        return -1;

    np::trophy::CollectionSource source;
    source.io = &s.emuenv->io;
    source.vita_fs_path = s.emuenv->vita_fs_path;
    source.user_id = s.emuenv->io.user_id;
    source.lang = static_cast<uint32_t>(s.emuenv->cfg.sys_lang);

    std::string report;
    try {
        for (const auto &id : np::trophy::list_collection_ids(source)) {
            np::trophy::CollectionSnapshot snap;
            if (!np::trophy::load_collection(source, id, snap))
                continue;
            report += fmt::format("C\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n", id, clean_field(snap.title), snap.icon_path,
                snap.total, snap.unlocked, snap.grade_unlocked[1], snap.grade_unlocked[2], snap.grade_unlocked[3], snap.grade_unlocked[4]);
            for (const auto &t : snap.trophies) {
                report += fmt::format("T\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n", t.id, t.grade, t.hidden ? 1 : 0, t.earned ? 1 : 0,
                    t.timestamp, clean_field(t.name), clean_field(t.detail), t.icon_path);
            }
        }
    } catch (const std::exception &error) {
        LOG_ERROR("iOS trophies: {}", error.what());
    }

    bool fits = false;
    write_report_or(out, out_size, report, fits);
    return fits ? 0 : -4;
}

int vita3k_ios_session_active_trophy_id(char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv)
        return -1;
    std::string id;
    {
        auto &trophies = s.emuenv->np.trophy_state;
        std::lock_guard<std::mutex> trophy_lock(trophies.access_mutex);
        for (const auto &context : trophies.contexts) {
            if (!context.valid)
                continue;
            id = fmt::format("{}_{:0>2d}", std::string(context.comm_id.data, 9), context.comm_id.num);
            break;
        }
    }
    if (id.empty())
        return 1;
    bool fits = false;
    write_report_or(out, out_size, id, fits);
    return fits ? 0 : -4;
}

int vita3k_ios_session_pop_trophy(char *meta, size_t meta_size, uint8_t *icon, size_t icon_size, size_t *icon_len) {
    app::PendingTrophy trophy;
    if (!app::pop_pending_trophy(trophy))
        return 0;
    const std::string line = fmt::format("{}\t{}\t{}\t{}\t{}", clean_field(trophy.np_com_id), clean_field(trophy.trophy_id),
        trophy.grade, clean_field(trophy.name), clean_field(trophy.detail));
    if (meta && meta_size > 0)
        std::snprintf(meta, meta_size, "%s", line.c_str());
    size_t copied = 0;
    if (icon && icon_len) {
        copied = std::min(icon_size, trophy.icon.size());
        std::memcpy(icon, trophy.icon.data(), copied);
        *icon_len = copied;
    }
    return 1;
}

int vita3k_ios_session_scan_apps(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv)
        return -1;
    return app::scan_apps(*s.emuenv) ? 0 : -1;
}

int vita3k_ios_session_firmware_mask(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv)
        return 0;

    const auto state = app::get_firmware_state(*s.emuenv);
    int mask = 0;
    if (state.preinstalled_package)
        mask |= 1 << 0;
    if (state.main_firmware)
        mask |= 1 << 1;
    if (state.font_package)
        mask |= 1 << 2;
    return mask;
}

int vita3k_ios_session_delete_app(const char *title_id, char *out, size_t out_size) {
    auto fail = [&](int code, const char *message) {
        if (out && out_size)
            std::snprintf(out, out_size, "%s", message);
        return code;
    };
    if (out && out_size)
        out[0] = '\0';
    auto &s = state();
    // Same lock order as the session worker. Never wait for a running game
    // or an install and then silently delete after it finishes.
    std::unique_lock<std::mutex> op(s.op_lock, std::try_to_lock);
    if (!op.owns_lock())
        return fail(-3, "Encerre a sessão antes de apagar um jogo.");
    std::unique_lock<std::mutex> lock(s.lock, std::try_to_lock);
    if (!lock.owns_lock())
        return fail(-3, "Aguarde a operação em andamento e tente novamente.");
    if (!s.initialized || !s.emuenv || !s.controller)
        return fail(-1, "A biblioteca ainda não foi inicializada.");
    if (s.controller->has_active_session() || s.stop_in_flight.load()
        || (s.phase.load() != FacadePhase::Idle && s.phase.load() != FacadePhase::Failed))
        return fail(-3, "Encerre a sessão antes de apagar um jogo.");

    const auto valid_component = [](const std::string &value) {
        return !value.empty() && value != "." && value != ".."
            && value.find_first_of("/\\:") == std::string::npos;
    };
    if (!title_id || !valid_component(title_id))
        return fail(-2, "Identificador de jogo inválido.");
    const auto apps = app::get_apps(*s.emuenv);
    const auto entry = std::find_if(apps.begin(), apps.end(), [&](const auto &app) { return app.title_id == title_id; });
    if (entry == apps.end() || !valid_component(entry->path)
        || (!entry->addcont.empty() && !valid_component(entry->addcont)))
        return fail(-2, "O jogo não foi encontrado ou tem um caminho inválido. Atualize a biblioteca.");

    try {
        const auto &env = *s.emuenv;
        std::vector<fs::path> paths{
            env.vita_fs_path / "ux0/patch" / title_id,
            env.vita_fs_path / "ux0/license" / title_id,
            env.config_path / "config" / fmt::format("config_{}.xml", entry->path),
            env.cache_path / "shaders" / title_id,
            env.cache_path / "shaderlog" / title_id,
            env.log_path / "shaderlog" / title_id,
        };
        // A DLC directory can be shared by multiple editions of a game.
        if (!entry->addcont.empty() && std::none_of(apps.begin(), apps.end(), [&](const auto &other) {
                return other.path != entry->path && other.addcont == entry->addcont;
            }))
            paths.push_back(env.vita_fs_path / "ux0/addcont" / entry->addcont);
        // Remove the app last: a cleanup failure leaves it available for retry.
        paths.push_back(env.vita_fs_path / "ux0/app" / entry->path);

        // Files is allowed to edit the sandbox. Reject linked parent folders
        // before deleting anything; remove_all itself does not follow a leaf
        // symlink. Do not traverse above Documents (e.g. the OS /var symlink).
        for (const auto &path : paths) {
            for (auto parent = path.parent_path(); parent != fs::path(s.base_path); parent = parent.parent_path()) {
                if (parent.empty() || parent == parent.parent_path() || fs::is_symlink(parent))
                    return fail(-4, "Uma pasta do jogo usa um caminho inválido. Verifique os arquivos e tente novamente.");
            }
        }
        for (const auto &path : paths)
            fs::remove_all(path);

        auto &list = s.emuenv->app.apps_list;
        {
            std::lock_guard<std::mutex> apps_lock(list.mutex);
            std::erase_if(list.apps, [&](const auto &app) { return app.path == entry->path; });
            for (auto &[user, times] : list.app_times)
                std::erase_if(times, [&](const auto &time) { return time.app_path == entry->path; });
            app::save_app_times(*s.emuenv);
        }
        app::save_apps_cache(*s.emuenv);
        return 0;
    } catch (const std::exception &e) {
        LOG_ERROR("iOS delete '{}': {}", title_id, e.what());
        return fail(-4, "Não foi possível remover todos os arquivos do jogo. Verifique o armazenamento e tente novamente.");
    }
}

// ------------------------------------------------------------------
// Per-game settings (parity with the desktop settings dialog scope).
// Per-app keys are persisted through the core's custom config
// (config/config_<APP>.xml) and are loaded on every launch of that
// game (setup_game_launch); global keys update the shared config.yml.
// ------------------------------------------------------------------

static bool parse_bool(const char *value) {
    const std::string v = value;
    return v == "1" || v == "true" || v == "True" || v == "yes" || v == "on";
}

int vita3k_ios_game_config_get(const char *app_path, char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv || !app_path || app_path[0] == '\0')
        return -1;

    Config tmp{};
    tmp = s.emuenv->cfg;
    config::set_current_config(tmp, s.root.get_config_path(), app_path);
    const auto &cc = tmp.current_config;

    std::string report;
    report += "title=" + std::string(app_path) + "\n";
    report += fmt::format("has_custom={}\n", config::has_custom_config(s.root.get_config_path(), app_path) ? 1 : 0);
    report += fmt::format("cpu_opt={}\n", cc.cpu_opt ? 1 : 0);
    report += fmt::format("cpu_jit_cache_mib={}\n", cc.cpu_jit_cache_mib);
    report += fmt::format("cpu_jit_cache_auto_mib={}\n", config::get_default_cpu_jit_cache_mib(tmp, app_path));
    report += fmt::format("force_software_page_table={}\n", cc.force_software_page_table ? 1 : 0);
    report += fmt::format("high_accuracy={}\n", cc.high_accuracy ? 1 : 0);
    report += fmt::format("disable_surface_sync={}\n", cc.disable_surface_sync ? 1 : 0);
    report += fmt::format("async_pipeline_compilation={}\n", cc.async_pipeline_compilation ? 1 : 0);
    report += fmt::format("resolution_multiplier={:.2f}\n", cc.resolution_multiplier);
    report += fmt::format("anisotropic_filtering={}\n", cc.anisotropic_filtering);
    report += fmt::format("shader_cache={}\n", cc.shader_cache ? 1 : 0);
    report += fmt::format("fps_hack={}\n", cc.fps_hack ? 1 : 0);
    report += fmt::format("frame_cap_30={}\n", cc.frame_cap_30 ? 1 : 0);
    report += fmt::format("texture_cache={}\n", cc.texture_cache ? 1 : 0);
    report += fmt::format("half_res_textures={}\n", cc.half_res_textures ? 1 : 0);
    report += fmt::format("log_level={}\n", cc.ios_log_level);
    report += fmt::format("log_compat_warn={}\n", cc.ios_log_compat_warn ? 1 : 0);
    report += fmt::format("show_compile_shaders={}\n", tmp.show_compile_shaders ? 1 : 0);

    bool fits = false;
    write_report_or(out, out_size, report, fits);
    return fits ? 0 : -4;
}

int vita3k_ios_game_config_set(const char *app_path, const char *key, const char *value) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv || !key || !value)
        return -1;

    const std::string k = key;
    const bool b = parse_bool(value);

    // Per-game keys: persist to this game's custom config (applied on its
    // next launch by the core's set_current_config).
    if (k == "cpu_opt" || k == "cpu_jit_cache_mib" || k == "force_software_page_table" || k == "high_accuracy" || k == "disable_surface_sync" || k == "async_pipeline_compilation" ||
        k == "resolution_multiplier" || k == "anisotropic_filtering" || k == "shader_cache" ||
        k == "fps_hack" || k == "frame_cap_30" || k == "texture_cache" || k == "half_res_textures" || k == "log_level" || k == "log_compat_warn") {
        if (!app_path || app_path[0] == '\0')
            return -1;
        Config tmp{};
        tmp = s.emuenv->cfg;
        config::set_current_config(tmp, s.root.get_config_path(), app_path);
        auto &cc = tmp.current_config;
        try {
            if (k == "cpu_opt")
                cc.cpu_opt = b;
            else if (k == "force_software_page_table")
                cc.force_software_page_table = b;
            else if (k == "cpu_jit_cache_mib") {
                const std::string cache = value;
                const int mib = std::stoi(cache);
                if (cache != std::to_string(mib) || (mib != 0 && (mib < 8 || mib > 32 || mib % 4 != 0)))
                    return -2;
                cc.cpu_jit_cache_mib = mib;
            } else if (k == "high_accuracy")
                cc.high_accuracy = b;
            else if (k == "disable_surface_sync")
                cc.disable_surface_sync = b;
            else if (k == "async_pipeline_compilation")
                cc.async_pipeline_compilation = b;
            else if (k == "resolution_multiplier")
                cc.resolution_multiplier = std::stof(value);
            else if (k == "anisotropic_filtering")
                cc.anisotropic_filtering = std::atoi(value);
            else if (k == "shader_cache")
                cc.shader_cache = b;
            else if (k == "fps_hack")
                cc.fps_hack = b;
            else if (k == "frame_cap_30")
                cc.frame_cap_30 = b;
            else if (k == "log_level") {
                // Reject malformed values instead of atoi's fallback to Trace.
                const std::string level = value;
                if (level.size() != 1 || level[0] < '0' || level[0] > '6')
                    return -2;
                cc.ios_log_level = level[0] - '0';
            } else if (k == "log_compat_warn")
                cc.ios_log_compat_warn = b;
            else if (k == "half_res_textures")
                cc.half_res_textures = b;
            else
                cc.texture_cache = b;
        } catch (const std::exception &) {
            return -2;
        }
        if (!config::save_custom_config(cc, s.root.get_config_path(), app_path)) {
            LOG_ERROR("iOS game config: could not save custom config for '{}'", app_path);
            return -3;
        }
        // The in-game settings menu changes these while the game is paused: also apply them to the
        // running game (everything else is picked up on the next launch).
        if (s.controller->has_active_session() && s.launch_app_path == app_path) {
            auto &live = s.emuenv->cfg.current_config;
            bool applied = true;
            if (k == "fps_hack")
                live.fps_hack = cc.fps_hack;
            else if (k == "frame_cap_30")
                live.frame_cap_30 = cc.frame_cap_30;
            else if (k == "anisotropic_filtering")
                live.anisotropic_filtering = cc.anisotropic_filtering;
            else if (k == "half_res_textures")
                live.half_res_textures = cc.half_res_textures;
            else if (k == "disable_surface_sync")
                live.disable_surface_sync = cc.disable_surface_sync;
            else if (k == "async_pipeline_compilation")
                live.async_pipeline_compilation = cc.async_pipeline_compilation;
            else
                applied = false;
            if (applied) {
                app::apply_runtime_settings(*s.emuenv);
                LOG_INFO("iOS game config: {} applied to the running game", k);
            }
        }
        LOG_INFO("iOS game config: {} = {} for {}", k, value, app_path);
        return 0;
    }

    // Global keys: update the shared config (all games) and apply live where
    // the core supports it.
    if (k == "show_compile_shaders") {
        s.emuenv->cfg.show_compile_shaders = b;
    } else {
        return -2;
    }
    if (config::serialize_config(s.emuenv->cfg, s.root.get_config_path()) != Success) {
        LOG_ERROR("iOS game config: could not save the global config");
        return -3;
    }
    LOG_INFO("iOS game config (global): {} = {}", k, value);
    return 0;
}

int vita3k_ios_game_config_reset(const char *app_path) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized || !s.emuenv || !app_path || app_path[0] == '\0')
        return -1;
    if (config::delete_custom_config(s.root.get_config_path(), app_path))
        LOG_INFO("iOS game config: removed custom config for '{}'", app_path);
    return 0;
}

int vita3k_ios_clear_shaders(const char *app_path) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.initialized)
        return -1;
    try {
        const fs::path cache = s.root.get_cache_path();
        const fs::path logs = s.root.get_log_path();
        if (app_path && app_path[0] != '\0') {
            fs::remove_all(cache / "shaders" / app_path);
            fs::remove_all(cache / "shaderlog" / app_path);
            fs::remove_all(logs / "shaderlog" / app_path);
        } else {
            fs::remove_all(cache / "shaders");
            fs::remove_all(cache / "shaderlog");
            fs::remove_all(logs / "shaderlog");
        }
    } catch (const std::exception &e) {
        LOG_ERROR("iOS clear shaders: {}", e.what());
        return -3;
    }
    return 0;
}

int vita3k_ios_session_launch(const char *app_path, int width, int height) {
    auto &s = state();

    {
        std::lock_guard<std::mutex> lock(s.lock);
        if (!s.initialized || !s.emuenv || !s.controller || !app_path || app_path[0] == '\0' || width <= 0 || height <= 0)
            return -1;
        if (s.controller->has_active_session() || s.phase.load() == FacadePhase::Starting || s.stop_in_flight.load())
            return -2;
        s.launch_app_path = app_path;
        ++s.launch_generation;
        s.launch_failed.store(false);
        s.stop_requested.store(false);
        s.phase.store(FacadePhase::Starting);
    }

    // The launch runs on its own thread: renderer init (Vulkan device +
    // shader compilation), late init (4 GiB reservation, audio, ngs) and
    // the app load can take seconds to minutes, and on device the JIT arena
    // preparation (StikDebug brk protocol) stops the whole process — the
    // main thread must keep running.
    try {
        std::thread worker(&launch_worker, std::ref(s), std::string(app_path), width, height);
        worker.detach();
    } catch (const std::system_error &e) {
        s.last_error = std::string("launch: could not start the launch thread: ") + e.what();
        s.phase.store(FacadePhase::Failed);
        s.launch_failed.store(true);
        return -1;
    }

    return 0;
}

int vita3k_ios_session_stop(void) {
    auto &s = state();

    if (s.phase.load() == FacadePhase::Idle)
        return -1;
    if (s.stop_in_flight.exchange(true)) {
        return -2;
    }

    s.stop_requested.store(true);

    std::thread([](Session &s) {
        // Set the flag before blocking on the lock: if a launch is still in
        // flight it will apply the stop itself before releasing the lock.
        diagnostics::stage("stop_requested");
        std::unique_lock<std::mutex> op(s.op_lock);

        std::lock_guard<std::mutex> lock(s.lock);
        if (s.controller && s.controller->has_active_session())
            s.controller->stop(app::AppSessionStopReason::UserRequest);
        if (s.frame_host) {
            // controller->stop() joined the render thread, so no thread reads
            // the host anymore: safe to unregister and release it.
            vita::ios::unregister_active_frame_host(s.frame_host.get());
            s.frame_host.reset();
        }

        s.stop_requested.store(false);
        s.phase.store(FacadePhase::Idle);
        diagnostics::stage("ended");
        s.stop_in_flight.store(false);
        logging::set_level(spdlog::level::off);
    }, std::ref(s)).detach();

    return 0;
}

int vita3k_ios_session_is_active(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    return (s.controller && s.controller->has_active_session()) ? 1 : 0;
}

int vita3k_ios_session_phase(void) {
    return static_cast<int>(state().phase.load());
}

int vita3k_ios_session_is_paused(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    return (s.controller && s.controller->is_running() && s.controller->is_paused()) ? 1 : 0;
}

uint64_t vita3k_ios_session_frame_count(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    return s.emuenv ? s.emuenv->display.submitted_frame_count.load(std::memory_order_relaxed) : 0;
}

int vita3k_ios_session_launch_failed(void) {
    return state().launch_failed.load() ? 1 : 0;
}

const char *vita3k_ios_session_app_path(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    return s.launch_app_path.c_str();
}

int vita3k_ios_session_report(char *out, size_t out_size) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);

    std::string report;
    report += "phase: ";
    switch (s.phase.load()) {
    case FacadePhase::Idle: report += "Idle"; break;
    case FacadePhase::Starting: report += "Starting"; break;
    case FacadePhase::Running: report += "Running"; break;
    case FacadePhase::Stopping: report += "Stopping"; break;
    case FacadePhase::Failed: report += "Failed"; break;
    }
    report += "\n";

    // Inline the firmware state (this function already holds s.lock).
    if (s.emuenv) {
        const auto fw = app::get_firmware_state(*s.emuenv);
        report += fmt::format("firmware: pd0={} vs0={} sa0={}\n",
            fw.preinstalled_package ? "yes" : "no", fw.main_firmware ? "yes" : "no", fw.font_package ? "yes" : "no");
    }
    report += "app: " + (s.launch_app_path.empty() ? std::string("—") : s.launch_app_path) + "\n";
    if (s.emuenv && !s.emuenv->current_app_title.empty())
        report += "title: " + s.emuenv->current_app_title + "\n";
    report += "paused: " + std::string((s.controller && s.controller->is_running() && s.controller->is_paused()) ? "yes" : "no") + "\n";
    report += fmt::format("lifecycle: generation={} background={} frames={}\n", s.launch_generation, s.background,
        s.emuenv ? s.emuenv->display.submitted_frame_count.load(std::memory_order_relaxed) : 0);
    if (s.emuenv) {
        const int rear = s.emuenv->touch.touchscreen_port == SCE_TOUCH_PORT_BACK ? 1 : 0;
        std::lock_guard<std::mutex> pad_lock(s.emuenv->ctrl.mutex);
        const auto &pad = s.emuenv->ctrl.virtual_pad;
        report += fmt::format("input: touch_fingers={} rear_touch={} ime={} gamepads={} vpad={} vpad_buttons=0x{:08x} vpad_buttons_ext=0x{:08x} vpad_axes={:.2f},{:.2f},{:.2f},{:.2f}\n",
            static_cast<int>(s.emuenv->touch.finger_count), rear, s.emuenv->ime.state ? "on" : "off",
            s.emuenv->ctrl.controllers_num, pad.active ? "on" : "off",
            pad.buttons, pad.buttons_ext, pad.axes[0], pad.axes[1], pad.axes[2], pad.axes[3]);
    }
    report += "jit_arena: " + std::string(vita::ios::JitMemory::instance().is_prepared() ? "prepared" : "not prepared") + "\n";
    if (s.launch_failed.load() && !s.last_error.empty())
        report += "error: " + s.last_error + "\n";
    report += "version: " + format_app_version() + "\n";
    report += "diagnostics: " + std::string(diagnostics::mode_name()) + "\n";
    report += "capture: " + diagnostics::capture_path() + "\n";

    bool fits = false;
    write_report_or(out, out_size, report, fits);
    return fits ? 0 : -4;
}

int vita3k_ios_session_set_pause(int reason, int enabled) {
    app::AppSessionPauseReason pause_reason;
    switch (reason) {
    case 1: pause_reason = app::AppSessionPauseReason::User; break;
    case 2: pause_reason = app::AppSessionPauseReason::Menu; break;
    case 4: pause_reason = app::AppSessionPauseReason::Background; break;
    default: return -1;
    }

    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.controller || !s.controller->is_running())
        return -1;
    return s.controller->set_pause_reason(pause_reason, enabled != 0) ? 0 : -1;
}

void vita3k_ios_session_set_background(int background) {
    const bool suspended = background != 0;
    // On foreground let the renderer run before waking any guest thread
    // waiting for it. On background stop guest producers before draining GPU.
    if (!suspended)
        vita::ios::set_rendering_suspended(false);
    auto &s = state();
    {
        std::lock_guard<std::mutex> lock(s.lock);
        s.background = suspended;
        // Startup owns the controller mutex for potentially slow JIT work.
        // Do not wait for that mutex on UIKit; the launch worker applies the
        // pending reason before publishing Running. Newly registered frame
        // hosts inherit the rendering gate even if no renderer exists yet.
        if (s.phase.load() == FacadePhase::Running && s.controller && !s.stop_in_flight.load())
            s.controller->set_pause_reason(app::AppSessionPauseReason::Background, suspended);
    }
    if (suspended)
        vita::ios::set_rendering_suspended(true);
    diagnostics::event("lifecycle", suspended ? "background: session retained, GPU idle" : "foreground: session resumed");
}

// ==================================================================
// Step 9: input bridge (UIKit main thread -> running session)
// ==================================================================

void vita3k_ios_input_touch_event(int event, int32_t finger_id, int32_t px, int32_t py) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;

    SDL_EventType type;
    bool pressed;
    switch (event) {
    case 0: type = SDL_EVENT_FINGER_DOWN; pressed = true; break;
    case 1: type = SDL_EVENT_FINGER_MOTION; pressed = true; break;
    case 2: type = SDL_EVENT_FINGER_UP; pressed = false; break;
    default: type = SDL_EVENT_FINGER_CANCELED; pressed = false; break;
    }

    // Store 0..1 across the whole drawable (Android's semantics); the
    // core applies the renderer's letterbox viewport when it converts to
    // Vita touch coordinates (touch::recover_touch_events).
    const auto &disp = s.emuenv->display;
    float nx = 0.0f, ny = 0.0f;
    if (disp.viewport_drawable_w > 0 && disp.viewport_drawable_h > 0) {
        nx = static_cast<float>(px) / disp.viewport_drawable_w;
        ny = static_cast<float>(py) / disp.viewport_drawable_h;
    }
    nx = std::clamp(nx, 0.0f, 1.0f);
    ny = std::clamp(ny, 0.0f, 1.0f);

    SDL_TouchFingerEvent finger{};
    finger.type = type;
    finger.touchID = 0;
    finger.fingerID = static_cast<SDL_FingerID>(finger_id);
    finger.x = nx;
    finger.y = ny;
    finger.pressure = (type == SDL_EVENT_FINGER_DOWN || type == SDL_EVENT_FINGER_MOTION) ? 1.0f : 0.0f;
    handle_touch_event(s.emuenv->touch, finger);

    auto &mouse = s.emuenv->ctrl.overlay_mouse;
    mouse.x.store(nx * static_cast<float>(DEFAULT_RES_WIDTH), std::memory_order_relaxed);
    mouse.y.store(ny * static_cast<float>(DEFAULT_RES_HEIGHT), std::memory_order_relaxed);
    mouse.pressed.store(pressed, std::memory_order_relaxed);
}

void vita3k_ios_input_ime_commit_text(const uint16_t *text, int32_t count) {
    if (!text || count <= 0)
        return;
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;
    ime_commit_text(s.emuenv->ime,
        std::u16string(reinterpret_cast<const char16_t *>(text), reinterpret_cast<const char16_t *>(text) + count));
}

void vita3k_ios_input_ime_preedit(const uint16_t *text, int32_t count) {
    if (!text || count <= 0)
        return;
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;
    ime_set_preedit(s.emuenv->ime,
        std::u16string(reinterpret_cast<const char16_t *>(text), reinterpret_cast<const char16_t *>(text) + count));
}

void vita3k_ios_input_ime_backspace(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;
    ime_backspace(s.emuenv->ime);
}

void vita3k_ios_input_ime_cursor(int dir) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;
    if (dir < 0)
        ime_cursor_left(s.emuenv->ime);
    else
        ime_cursor_right(s.emuenv->ime);
}

int vita3k_ios_input_ime_active(void) {
    Vita3KImeSnapshot snapshot{};
    return vita3k_ios_input_ime_snapshot(&snapshot) > 0 ? 1 : 0;
}

int vita3k_ios_input_ime_snapshot(Vita3KImeSnapshot *out) {
    if (!out) return 0;
    *out = {};
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || s.phase.load() != FacadePhase::Running || s.stop_in_flight.load()) return 0;
    return vita::ios::ime_snapshot(s.emuenv->ime, s.emuenv->common_dialog, *out);
}

int vita3k_ios_input_ime_replace(uint64_t request_id, const uint16_t *text, int32_t count, uint32_t caret) {
    if (count < 0 || count > SCE_IME_MAX_TEXT_LENGTH || (!text && count)) return -2;
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || s.phase.load() != FacadePhase::Running || s.stop_in_flight.load()) return -1;
    const auto value = count ? std::u16string_view(reinterpret_cast<const char16_t *>(text), count) : std::u16string_view{};
    return vita::ios::ime_replace(s.emuenv->ime, s.emuenv->common_dialog, request_id, value, caret);
}

int vita3k_ios_input_ime_finish(uint64_t request_id, int cancel) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || s.phase.load() != FacadePhase::Running || s.stop_in_flight.load()) return -1;
    return vita::ios::ime_finish(s.emuenv->ime, s.emuenv->common_dialog, request_id, cancel != 0);
}

void vita3k_ios_input_set_rear_touch(int enabled) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv || !s.controller || !s.controller->has_active_session())
        return;
    // Select the active touchscreen port (same as the Android
    // set_rear_touchscreen, which the header only exposes there).
    s.emuenv->touch.touchscreen_port = enabled ? SCE_TOUCH_PORT_BACK : SCE_TOUCH_PORT_FRONT;
}

void vita3k_ios_input_clear(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv)
        return;
    // Lift every finger and drop the overlay mouse without touching the
    // controllers (gamepads keep their state across focus changes).
    auto &touch = s.emuenv->touch;
    std::fill_n(touch.finger_buffer, 8, SDL_TouchFingerEvent{});
    touch.finger_count = 0;
    touch.is_touched[0] = false;
    touch.is_touched[1] = false;
    auto &mouse = s.emuenv->ctrl.overlay_mouse;
    mouse.x.store(0.f, std::memory_order_relaxed);
    mouse.y.store(0.f, std::memory_order_relaxed);
    mouse.pressed.store(false, std::memory_order_relaxed);
    {
        std::lock_guard<std::mutex> pad_lock(s.emuenv->ctrl.mutex);
        // Rotation clears held input, but the visible pad remains enabled.
        // Only virtual_enabled() (or full runtime teardown) changes that.
        auto &pad = s.emuenv->ctrl.virtual_pad;
        pad.buttons = 0;
        pad.buttons_ext = 0;
        std::fill_n(pad.axes, 4, 0.f);
    }
}

void vita3k_ios_input_virtual_enabled(int enabled) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv)
        return;
    std::lock_guard<std::mutex> pad_lock(s.emuenv->ctrl.mutex);
    s.emuenv->ctrl.virtual_pad.active = enabled != 0;
}

/// Set the virtual gamepad's button masks (SCE_CTRL bits; `buttons` for the
/// non-extended set, `buttons_ext` for the extended one). Replaces the
/// previous state entirely (the UI recomputes the full mask on each touch).
void vita3k_ios_input_virtual_buttons(uint32_t buttons, uint32_t buttons_ext) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv)
        return;
    std::lock_guard<std::mutex> pad_lock(s.emuenv->ctrl.mutex);
    s.emuenv->ctrl.virtual_pad.buttons = buttons;
    s.emuenv->ctrl.virtual_pad.buttons_ext = buttons_ext;
}

/// Virtual analogs: LX,LY,RX,RY in the -1..1 range (the same convention
/// the SDL gamepad path uses before the Vita 0..255 mapping).
void vita3k_ios_input_virtual_axes(float lx, float ly, float rx, float ry) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv)
        return;
    std::lock_guard<std::mutex> pad_lock(s.emuenv->ctrl.mutex);
    auto &axes = s.emuenv->ctrl.virtual_pad.axes;
    axes[0] = std::clamp(lx, -1.f, 1.f);
    axes[1] = std::clamp(ly, -1.f, 1.f);
    axes[2] = std::clamp(rx, -1.f, 1.f);
    axes[3] = std::clamp(ry, -1.f, 1.f);
}

/// Number of physical gamepads currently attached (the app hides its
/// on-screen pad while one is connected). Returns -1 when the environment
/// is not initialized.
int vita3k_ios_input_gamepad_count(void) {
    auto &s = state();
    std::lock_guard<std::mutex> lock(s.lock);
    if (!s.emuenv)
        return -1;
    return s.emuenv->ctrl.controllers_num;
}

} // extern "C"
