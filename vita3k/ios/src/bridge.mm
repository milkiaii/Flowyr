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

#include "ios/bridge.h"

#include "ios/jit_memory.h"
#include "ios/test_lock.h"

#include <util/exit_code.h>
#include <util/diagnostics.h>
#include <util/fs.h>
#include <util/jit_config.h>
#include <util/log.h>

#include <spdlog/details/registry.h>

#include <sys/param.h>
#include <unistd.h>

#include <mutex>

#include <cinttypes>
#include <cstdio>
#include <mutex>
#include <string>

// Two-level stringify so the gitver.h macro values are expanded before being
// turned into string literals.
#define VITA3K_STR3(x) #x
#define VITA3K_STR2(x) VITA3K_STR3(x)
#define VITA3K_STR(x) VITA3K_STR2(x)

#if __has_include("gitver.h")
#include "gitver.h"
// The commit count is meaningless in CI (shallow clone), so name the release and the upstream base.
#define VITA3K_VERSION_STRING "1.0 (Vita3K " VITA3K_STR(APP_VER_HI) "." VITA3K_STR(APP_VER_MID) "." VITA3K_STR(APP_VER_LO) " base)"
#else
#define VITA3K_VERSION_STRING "unknown"
#endif

namespace {

std::string version_string() {
    return VITA3K_VERSION_STRING;
}

bool write_report(char *out, size_t out_size, const std::string &report) {
    if (!out || out_size == 0 || report.size() + 1 > out_size)
        return false;
    std::snprintf(out, out_size, "%s", report.c_str());
    return true;
}

} // namespace

namespace vita::ios {

std::mutex &heavy_test_lock() {
    static std::mutex lock;
    return lock;
}

} // namespace vita::ios

extern "C" {

const char *vita3k_ios_version(void) {
    static std::string cached = version_string();
    return cached.c_str();
}

int vita3k_ios_self_test(const char *base_path, char *out, size_t out_size) {
    if (!base_path)
        return -1;

    const fs::path base{ base_path };
    const fs::path log_dir = base / "logs";
    // The core logger uses a fixed file name (util/logging.cpp).
    const fs::path log_file = log_dir / "vita3k.log";

    Root root;
    root.set_vita_fs_path(base / "vita");
    root.set_patch_path(base / "patches");
    root.set_log_path(log_dir);
    root.set_config_path(base / "config");
    root.set_shared_path(base / "shared");
    root.set_cache_path(base / "cache");
    root.set_static_assets_path(base / "assets");

    if (logging::init(root, /*use_stdout=*/false) != Success)
        return -1;
    logging::set_level(spdlog::level::info);

    // Unique per call: the core logger's dup filter drops identical lines
    // within 2s, which would make repeated self-tests leave an empty log.
    static std::atomic<unsigned> self_test_seq{0};
    const auto sequence = ++self_test_seq;
    LOG_INFO("Vita3K iOS core self-test #{} ({}).", sequence, version_string());

    // The core logger is async; flush so the file check (and any consumer
    // reading the file right after) sees the line above.
    spdlog::details::registry::instance().flush_all();

    // The log line above must have reached the file sink on disk.
    if (!fs::exists(log_file)) {
        LOG_ERROR("Self-test log file was not created at {}", log_file);
        spdlog::details::registry::instance().flush_all();
        return -2;
    }

    // Checkpoint probes (flushed to disk): on device the self-test can
    // observe a process suspended by the debugger; the last checkpoint
    // reached tells exactly where it stopped.
    LOG_INFO("Self-test checkpoint: log file exists, page_size={} bytes.", sysconf(_SC_PAGESIZE));
    spdlog::details::registry::instance().flush_all();

    const long page_size = sysconf(_SC_PAGESIZE);
    const auto &jit = vita::ios::JitMemory::instance();
    const bool arena_prepared = jit.is_prepared();
    LOG_INFO("Self-test checkpoint: JitMemory state cs_debugged={} arena={}.",
        vita::ios::cs_debugged_state(), arena_prepared ? "prepared" : "not prepared");
    spdlog::details::registry::instance().flush_all();

    std::string report;
    report += "version: " + version_string() + "\n";
    report += "page_size: " + std::to_string(page_size) + "\n";
    report += "logging: OK (" + fs_utils::path_to_utf8(log_file) + ")\n";
    report += "jit_arena: " + std::string(arena_prepared ? "prepared" : "not prepared") + "\n";
    if (arena_prepared) {
        report += jit.describe() + "\n";
    }
    report += "result: PASS\n";

    if (!write_report(out, out_size, report))
        return -3;

    LOG_INFO("Self-test checkpoint: done.");
    spdlog::details::registry::instance().flush_all();
    return 0;
}

int vita3k_ios_cs_debugged(void) {
    return vita::ios::cs_debugged_state();
}

const char *vita3k_ios_logging_mode(void) {
    if (diagnostics::enabled())
        return diagnostics::mode_name();
    return spdlog::get_level() <= spdlog::level::debug ? "debug" : "off";
}

int vita3k_ios_logging_enabled(void) {
    return logging::is_enabled() ? 1 : 0;
}

int vita3k_ios_jit_prepare(void) {
    const std::lock_guard<std::mutex> lock(vita::ios::heavy_test_lock());
    auto &arena = vita::ios::JitMemory::instance();
    if (arena.validate_alive())
        return 0;
    return arena.prepare(jit_config::default_arena_bytes) && arena.validate_alive() ? 0 : -1;
}

const char *vita3k_ios_jit_report(void) {
    // Refreshed on every call: the arena state changes at runtime (the
    // memory test prepares it after launch), so a first-call cache would
    // report "prepared: no" forever.
    static std::string cached;
    static std::mutex cached_mutex;
    {
        std::lock_guard<std::mutex> lock(cached_mutex);
        cached = vita::ios::JitMemory::instance().describe();
    }
    return cached.c_str();
}

int vita3k_ios_jit_validate_alive(void) {
    return vita::ios::JitMemory::instance().validate_alive() ? 0 : -1;
}

} // extern "C"
