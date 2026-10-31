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

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Version identifier of the linked Vita3K core ("x.y.z" + git revision).
/// The returned pointer is valid until the next call.
const char *vita3k_ios_version(void);

/// Active logging mode: off, debug, compat, performance or graphics.
/// Reads the current process state, not the marker for the next launch.
/// Specific captures take priority; debug means the logger is at Debug/Trace.
/// Returns a static string. Independent of debugger attachment/JIT readiness.
const char *vita3k_ios_logging_mode(void);
/// Whether automatic logging/probes are enabled in the running process.
/// False before initialization and in normal sessions without a title opt-in.
int vita3k_ios_logging_enabled(void);

/// Smoke test of the linked core without booting the emulator.
///
/// Initializes the core logging to `<base_path>/logs`, exercises a few
/// cross-platform primitives (fmt, boost::filesystem, page size) and reports
/// the state of the process-wide JIT arena. The report is written to `out`
/// (NUL-terminated, truncated when too small).
///
/// Returns 0 on success, or a negative code:
///   -1  logging could not be initialized
///   -2  the log file was not created
///   -3  report buffer too small
int vita3k_ios_self_test(const char *base_path, char *out, size_t out_size);

/// Returns CS_DEBUGGED (not proof that a debugger is still attached):
///   1  debugging allowed; the flag may survive debugger detachment
///   0  debugging not allowed
///  -1  could not be queried (csops error / not an iOS process)
int vita3k_ios_cs_debugged(void);

/// Prepare/reuse the process-wide 512 MiB JIT arena used by the emulator.
/// Runs the StikDebug protocol on device; call on a background thread, never
/// the UI thread. Returns 0 only after successful preparation/validation.
/// Does not allocate guest RAM or run the diagnostic memory test.
int vita3k_ios_jit_prepare(void);

/// Multi-line report of the process-wide JIT arena (reservation, slices).
/// The returned pointer is valid until the next call.
const char *vita3k_ios_jit_report(void);

/// Checks arena preparation and debugging status without modifying code.
/// Returns 0 when prepared and valid, -1 when unprepared or revoked.
/// This does not prove debugger attachment or guarantee future access.
int vita3k_ios_jit_validate_alive(void);

/// Step 5 of the iOS port: validate the Vita3K memory model on the target.
///
/// Exercises the production code paths end to end:
///   - the 4 GiB contiguous guest reservation (mem::init), host page size
///     (16 KiB on iOS 26) and the process virtual-address ceiling;
///   - 4 KiB guest pages on top of 16 KiB host pages (two blocks sharing a
///     physical page, partial release, reuse, write-protect + SIGBUS fault
///     handler + ProtectCallback);
///   - page_table mode (use_page_table=true);
///   - alloc/free pressure without footprint growth;
///   - the dual-map RX/RW JIT arena (StikDebug on device) plus a bootstrap
///     that emits code through the RW alias, executes it from the RX view,
///     and reads/writes guest pages of the 4 GiB reservation.
///
/// The report is written to `out` (NUL-terminated, truncated when too
/// small). When the JIT arena is not prepared (device without an active
/// StikDebug session) the JIT section is reported as skipped, not failed.
///
/// Returns 0 when every executed case passed, or a negative code:
///   -3  report buffer too small
///   -4  one or more memory-model cases failed
int vita3k_ios_memory_test(const char *base_path, char *out, size_t out_size);

/// Step 6 of the iOS port: present a Vulkan/MoltenVK scene on the app's
/// CAMetalLayer through the production render path (VK_EXT_metal_surface,
/// swapchain over the pixel drawable size, the screen filter pipeline that
/// macOS uses, an animated 960x544 test pattern uploaded from guest memory).
///
///   base_path           app sandbox directory for logs/config/state (Root)
///   static_assets_path  app bundle directory holding shaders-builtin/ and
///                       icons/ (immutable core resources)
///   has_moltenvk        1 when this build links the MoltenVK XCFramework
///                       (device flavor); the simulator flavor links none
///   width/height        current pixel drawable size of the layer
///
/// The CAMetalLayer itself is not an argument of this call: the app
/// (main/UIKit thread) delivers it through
/// vita3k_ios_frame_host_set_layer before calling this function, and the
/// session stores it in the frame host. The render thread then reads only
/// lock-free frame-host state — no UIKit object or pointer ever crosses
/// into its arguments.
///
/// The render loop runs on its own thread until vita3k_ios_vulkan_demo_stop
/// is called; size changes are applied from the main thread through
/// vita3k_ios_frame_host_set_size (lock-free).
///
/// Returns 0 when the scene is presenting, or a negative code:
///   -1  invalid arguments (or the layer was not delivered beforehand)
///   -2  renderer (Vulkan) initialization or render thread failure
///   -3  the guest memory model (step 5) could not be initialized
///   -4  report buffer too small
///   -5  MoltenVK is not linked into this build (simulator flavor)
///   -6  a demo session is already running
///   -7  the memory-model test is still running; retry when it finishes
int vita3k_ios_vulkan_demo_start(const char *base_path, const char *static_assets_path,
    int has_moltenvk, int width, int height, char *out, size_t out_size);

/// Stops the demo session (render thread, Vulkan device/instance, guest
/// memory) and tears everything down cleanly.
/// Returns 0 on success, -1 when no session is running.
int vita3k_ios_vulkan_demo_stop(void);

/// 1 when a demo session is presenting, 0 otherwise.
int vita3k_ios_vulkan_demo_is_running(void);

/// Live report: running state, frames presented, fps, current swapchain
/// extent, plus the init report (GPU/driver, surface format and present
/// mode, extensions, limits, memory layout).
/// Returns 0 on success, -4 when the buffer is too small.
int vita3k_ios_vulkan_demo_report(char *out, size_t out_size);

/// Main-thread (UIKit) callback: the app's CAMetalLayer (opaque pointer).
/// Must be called before vita3k_ios_vulkan_demo_start or
/// vita3k_ios_session_launch: the session consumes it when it creates the
/// frame host, and the render thread reads it lock-free when building the
/// VK_EXT_metal_surface.
void vita3k_ios_frame_host_set_layer(void *metal_layer);

/// Main-thread (UIKit) callback: new pixel drawable size of the
/// CAMetalLayer (rotation/resize). Active sessions (Vulkan demo or game
/// session) read it lock-free and rebuild the swapchain on the next frame.
void vita3k_ios_frame_host_set_size(int width, int height);

// ==================================================================
// Step 7 of the iOS port: session facade over AppSessionController
// ==================================================================
//
// The C facade mirrors the Android bootstrap (native_bootstrap.cpp,
// main_android.cpp): init builds the environment (Root from the sandbox,
// EmuEnvState, config, apps list, users), launch drives
// begin_launch -> initialize_renderer -> initialize_runtime -> load_and_run
// on a background thread (the app's main thread must stay responsive; on
// device the JIT arena preparation can stop the whole process via the
// StikDebug brk protocol), stop tears the session down.
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
//                  the whole sandbox there) — new files are installed on the
//                  fly (app-side watcher) / at launch
// The absolute container path is never persisted as identity: the app
// re-resolves base_path on every launch and the core only stores relative
// layout under it.

/// Initialize the emulator environment (once per process). Idempotent.
/// Call on the main thread (also initializes SDL's audio subsystem).
///
///   base_path            app sandbox directory (Documents), writable
///   static_assets_path   app bundle directory (shaders-builtin/, icons/)
///
/// Returns 0 on success, or a negative code:
///   -1  invalid arguments or the sandbox could not be created
///   -2  core logging could not be initialized
///   -3  config could not be initialized
///   -4  emulated environment (app::init) could not be initialized
///   -5  no user could be ensured (Vita FS user area failed)
int vita3k_ios_session_init(const char *base_path, const char *static_assets_path);

/// Tear the environment down. Only valid when no session is active.
/// Returns 0 on success, -1 when a session is still active.
int vita3k_ios_session_deinit(void);

/// The staging directory (<base_path>/imports/, created on demand). The app
/// copies the document picker's files here on a worker while holding the
/// security-scoped access, then calls vita3k_ios_session_install with a path
/// inside it. ZIP/VPK extraction streams to disk using bounded buffers.
/// The path is written to `out` (NUL-terminated, truncated when too small).
/// Returns 0 on success, -1 when the environment is not initialized, -4
/// when the buffer is too small.
int vita3k_ios_session_staging_path(char *out, size_t out_size);

/// Install staged content into the emulated Vita FS, re-scanning the apps
/// list on success. `staged_path` is inside the staging directory: a
/// document-picker copy, or a file the user copied there through the Files
/// app (the sandbox is visible there via UIFileSharingEnabled). Accepted
/// content (by file name / type):
///   - a directory or a .zip/.vpk archive holding app content
///     (eboot.bin + sce_sys/param.sfo), optionally wrapped in a single
///     top-level folder; the title ID and category come from param.sfo and
///     the content is installed to <vita>/ux0/app/<TITLE_ID>/
///   - a .pkg file (install_pkg; homebrew packages are unencrypted)
///   - a .pup file (firmware: vs0/pd0/sa0)
/// Free space is checked before copying; on failure nothing is left behind
/// (the staged copy stays in the staging area for inspection).
/// The report is written to `out` (NUL-terminated, truncated when too
/// small). Returns 0 on success, or a negative code:
///   -1  invalid arguments or the environment is not initialized
///   -2  the content could not be recognized (not an app/pkg/pup)
///   -3  the archive could not be read/extracted
///   -4  the content could not be installed (license, space, write error)
///   -5  report buffer too small
/// `replace_existing` is 0 for automatic ZIP/VPK/folder imports: an app
/// already installed under the archive's TITLE_ID is preserved. Explicit
/// picker imports pass 1 to allow a user-requested reinstall.
int vita3k_ios_session_install(const char *staged_path, int replace_existing, char *out, size_t out_size);

/// Installs a license from a zRIF key (base64 text) into ux0/license.
/// Returns 0 on success, otherwise a negative code with a message in `out`.
int vita3k_ios_session_install_zrif(const char *zrif, char *out, size_t out_size);

/// List the installed apps, one line each: "title_id|title".
/// Returns 0 on success, -1 when the environment is not initialized,
/// -4 when the buffer is too small.
int vita3k_ios_session_get_apps(char *out, size_t out_size);

/// Every trophy collection (one per game with trophy data), as text:
///   C\t<np_com_id>\t<title>\t<icon path>\t<total>\t<unlocked>\t<plat>\t<gold>\t<silver>\t<bronze>
///   T\t<id>\t<grade 1-4>\t<hidden 0/1>\t<earned 0/1>\t<unix time>\t<name>\t<detail>\t<icon path>
/// (T lines belong to the preceding C line). 0 on success, -1 when not
/// initialized, -4 when the buffer is too small.
int vita3k_ios_session_trophies(char *out, size_t out_size);

/// Trophy set id ("NPWR00000_00") of the running game, once it has created
/// its trophy context. 0 with the id in `out`, 1 when there is none yet,
/// -1 when not initialized, -4 when the buffer is too small.
int vita3k_ios_session_active_trophy_id(char *out, size_t out_size);

/// Pops the oldest trophy unlocked during play. `meta` receives
/// "<np_com_id>\t<trophy_id>\t<grade 1-4>\t<name>\t<detail>" and the PNG icon
/// goes to `icon` (length in `icon_len`). Returns 1 when one was popped,
/// 0 when none is pending, -1 when not initialized.
int vita3k_ios_session_pop_trophy(char *meta, size_t meta_size, uint8_t *icon, size_t icon_size, size_t *icon_len);

/// Force a re-scan of <vita>/ux0/app. Returns 0 on success, -1 when the
/// environment is not initialized.
int vita3k_ios_session_scan_apps(void);

/// Uninstall a library title and its patches, DLC, license, custom config
/// and shader caches. Preserves saves, trophies and imported source files.
/// Runs off-main; refuses while the runtime or another operation is busy.
/// Returns 0 on success, -1 uninitialized, -2 invalid/unknown title,
/// -3 busy, -4 filesystem failure. Writes a user-facing error to out.
int vita3k_ios_session_delete_app(const char *title_id, char *out, size_t out_size);

/// Firmware state mask: bit 0 = preinstalled (pd0), bit 1 = main (vs0),
/// bit 2 = font (sa0). Returns 0 when the environment is not initialized.
int vita3k_ios_session_firmware_mask(void);

// ==================================================================
// Per-game settings (parity with the desktop settings dialog scope)
// ==================================================================
//
// The desktop stores per-game overrides in
// <config>/config/config_<APP>.xml (config::save_custom_config); the core
// already loads them on every launch (setup_game_launch ->
// config::set_current_config), so values saved here take effect the next
// time that game starts. A few settings the desktop also lists (log level,
// compatibility warnings, shader compilation hint) are global-only in the
// core: they are updated in the global config (all games) and applied live
// where possible (log level, compat warnings).

/// Report the settings shown by the game settings screen, one
/// "key=value" line each, for `app_path` (a title id):
///   title, has_custom (0/1), then per-game effective values (global
///   defaults + title profile + this game's overrides): cpu_opt, cpu_jit_cache_mib (0 = Auto),
///   cpu_jit_cache_auto_mib (core title profile or global default),
///   force_software_page_table (0/1),
///   high_accuracy (0 = Standard, 1 = High), disable_surface_sync,
///   async_pipeline_compilation, resolution_multiplier, anisotropic_filtering,
///   shader_cache, fps_hack, frame_cap_30, texture_cache, half_res_textures, log_level, log_compat_warn;
///   then global values: show_compile_shaders.
/// An empty `app_path` reads (and, for set, edits) the global defaults that games
/// without their own config use; log keys are per-game only.
/// The report is written to `out` (NUL-terminated, truncated when too small).
/// Returns 0 on success, -1 when the environment is not initialized,
/// -4 when the buffer is too small.
int vita3k_ios_game_config_get(const char *app_path, char *out, size_t out_size);

/// Set one setting and persist it. `value` is "0"/"1" for booleans, a
/// decimal string for numbers (resolution_multiplier is a float such as
/// "1.5"; cpu_jit_cache_mib is 0 for Auto or 8..32 MiB per thread, in steps of 4;
/// anisotropic_filtering a power of two; log_level 0..6 =
/// trace..critical/off). Per-game keys (cpu_opt, cpu_jit_cache_mib, force_software_page_table, high_accuracy, disable_surface_sync,
/// async_pipeline_compilation, resolution_multiplier, anisotropic_filtering,
/// shader_cache, fps_hack, frame_cap_30, texture_cache, half_res_textures, log_level, log_compat_warn) are saved
/// to the game's custom config (requires a non-empty app_path), applied next
/// launch. show_compile_shaders updates the shared config.
/// Returns 0 on success, -1 invalid arguments/environment, -2 unknown key/invalid value,
/// -3 the file could not be written.
int vita3k_ios_game_config_set(const char *app_path, const char *key, const char *value);

/// Delete the per-game custom config for `app_path` (values fall back to
/// the global defaults and title profile on the next launch). Idempotent.
/// Returns 0 on success, -1 invalid arguments/environment.
int vita3k_ios_game_config_reset(const char *app_path);

/// Clear compiled shader caches and shader logs: for a single title
/// (`app_path` = title id) or for every title when `app_path` is empty or
/// NUL (like the desktop's "Clean shader cache" button).
/// Returns 0 on success, -1 when the environment is not initialized,
/// -3 when removal failed.
int vita3k_ios_clear_shaders(const char *app_path);

/// Opt-in runtime options (Settings > System): low memory mode and recommended per-game profiles.
void vita3k_ios_set_options(int low_memory, int title_profiles);

/// Start a session for an installed app (its title id, as listed by
/// vita3k_ios_session_get_apps) on the app's CAMetalLayer (delivered before
/// the call through vita3k_ios_frame_host_set_layer). The launch sequence
/// runs on a background thread; query vita3k_ios_session_report for
/// progress and errors. Returns 0 when the launch thread started, or a
/// negative code:
///   -1  invalid arguments, environment not initialized, or the CAMetalLayer
///       was not delivered beforehand
///   -2  a session is already active (stop it first)
int vita3k_ios_session_launch(const char *app_path, int width, int height);

/// Stop the active session (user request). Runs on a background thread
/// (teardown joins the render/kernel threads). Returns 0 on success,
/// -1 when no session is active, -2 when a stop is already in flight.
int vita3k_ios_session_stop(void);

/// 1 when a session is active (phase != Idle), 0 otherwise.
int vita3k_ios_session_is_active(void);

/// Session phase: 0 Idle, 1 Launching, 2 Running, 3 Stopping.
int vita3k_ios_session_phase(void);

/// 1 when the running session is paused (any reason), 0 otherwise.
int vita3k_ios_session_is_paused(void);

/// Cumulative successful guest frame submissions (sceDisplaySetFrameBuf),
/// reset on session teardown. Thread-safe; independent of diagnostic logs.
/// Sample deltas over monotonic elapsed time while Running to calculate FPS.
/// This counts game frames, not host refreshes, and does not measure input lag.
uint64_t vita3k_ios_session_frame_count(void);

/// 1 when the last launch failed (see vita3k_ios_session_report for the
/// error), 0 otherwise.
int vita3k_ios_session_launch_failed(void);

/// Title id of the app being launched/running ("" when none).
/// The returned pointer is valid until the next call.
const char *vita3k_ios_session_app_path(void);

/// Multi-line live report: phase, app, pause mask, JIT arena state, and
/// the last launch error when the launch failed.
/// Returns 0 on success, -4 when the buffer is too small.
int vita3k_ios_session_report(char *out, size_t out_size);

/// Set/clear a pause reason on the running session: 1 = user, 2 = menu,
/// 4 = background (same values as AppSessionPauseReason). Returns 0 on
/// success, -1 when the session is not running or the reason is invalid.
int vita3k_ios_session_set_pause(int reason, int enabled);

/// Main-thread lifecycle transition. Keeps the session alive, pauses guest
/// CPU/audio, and drains/parks GPU submissions before returning on background.
/// Also applies during startup and to the Vulkan demo. Does not clear User pause.
void vita3k_ios_session_set_background(int background);

// ==================================================================
// Step 9 of the iOS port: input (touch, IME, rear touch)
// ==================================================================
//
// The app owns the screen (CAMetalLayer); UIKit touch events and the
// software keyboard cross into the core through this API, on the main
// thread, and are consumed by the running session's input pump (the
// launch worker thread, which also pumps SDL gamepad/sensor events —
// SDL is used without its video driver on iOS). All calls are no-ops
// when no session is active.

/// Front-touch event from UIKit. `px`/`py` are drawable pixel
/// coordinates of the surface (the app scales points to pixels); the core
/// normalizes them across the whole drawable (Android's semantics) and the
/// guest touch API applies the renderer's letterbox viewport. `event`:
///   0 = down, 1 = move, 2 = up, 3 = cancelled
/// `finger_id` is a stable per-touch identifier (the app's choice).
void vita3k_ios_input_touch_event(int event, int32_t finger_id, int32_t px, int32_t py);

/// Commit text to the active IME session (UTF-16, `count` code units).
/// No-op when the guest has no IME open.
void vita3k_ios_input_ime_commit_text(const uint16_t *text, int32_t count);

/// Set the IME preedit (composition) text (UTF-16).
void vita3k_ios_input_ime_preedit(const uint16_t *text, int32_t count);

/// IME backspace at the caret.
void vita3k_ios_input_ime_backspace(void);

/// Move the IME caret: `dir` < 0 left, > 0 right.
void vita3k_ios_input_ime_cursor(int dir);

/// 1 when sceImeOpen or sceImeDialogInit requests a keyboard, 0 otherwise.
int vita3k_ios_input_ime_active(void);

/// Native keyboard snapshot. UTF-16 lengths/caret exclude the terminator.
/// kind: 0 closed, 1 sceImeOpen, 2 sceImeDialogInit. request_id changes on
/// every open, even if successive dialogs occur between UI polling ticks.
typedef struct Vita3KImeSnapshot {
    uint64_t request_id;
    uint32_t kind;
    uint32_t max_length;
    uint32_t text_length;
    uint32_t caret;
    uint32_t keyboard_type;
    uint32_t multiline;
    uint32_t cancelable;
    uint16_t text[2049];
    char title[128];
} Vita3KImeSnapshot;

/// Returns the kind, or 0 when inactive. Does not enable diagnostic logging.
int vita3k_ios_input_ime_snapshot(Vita3KImeSnapshot *out);
/// Replaces committed text and caret atomically. Enforces the guest's UTF-16
/// limit. Returns 0 on success, -1 if closed/stale, -2 for invalid input.
int vita3k_ios_input_ime_replace(uint64_t request_id, const uint16_t *text, int32_t count, uint32_t caret);
/// Confirms (cancel=0) or cancels (cancel=1) the matching request. Confirmation
/// writes the dialog result buffer and finishes the dialog; low-level IME
/// receives PRESS_ENTER/PRESS_CLOSE. Noncancelable dialogs reject cancel.
int vita3k_ios_input_ime_finish(uint64_t request_id, int cancel);

/// Explicit rear-touch selection (the Vita has two touchscreens; the
/// front is the one mapped from the screen, the rear is opted in).
void vita3k_ios_input_set_rear_touch(int enabled);

/// Clear fingers, overlay mouse and held virtual buttons/axes, preserving
/// whether the virtual pad is enabled. Use on rotation/focus loss; disable
/// the pad separately when hiding its view or tearing down the session.
void vita3k_ios_input_clear(void);

// On-screen (virtual) gamepad: the app's touch controls write button masks
// (SCE_CTRL bits) and analog axes into the core's CtrlState, blended with
// any physical gamepad. The app enables it while its on-screen pad is
// shown and disables it otherwise (e.g. a physical pad is connected).

/// Enable/disable the virtual gamepad (0 or 1).
void vita3k_ios_input_virtual_enabled(int enabled);

/// Set the virtual gamepad's button masks: `buttons` for the non-extended
/// SCE_CTRL set, `buttons_ext` for the extended one. Replaces the previous
/// state (the UI recomputes the full mask on each touch).
void vita3k_ios_input_virtual_buttons(uint32_t buttons, uint32_t buttons_ext);

/// Set the virtual analogs LX,LY,RX,RY in the -1..1 range.
void vita3k_ios_input_virtual_axes(float lx, float ly, float rx, float ry);

/// Number of physical gamepads currently attached (the app hides its
/// on-screen pad while one is connected). -1 when not initialized.
int vita3k_ios_input_gamepad_count(void);

#ifdef __cplusplus
}
#endif
