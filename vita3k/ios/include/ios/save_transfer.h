#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace ios::save_transfer {
struct Result {
    // Number of games exported or imported; negative on failure.
    int code = 0;
    std::vector<std::string> titles;
    std::string error;
};

// Writes the save folders under `savedata_root` (one folder per title id) into a ZIP, one top level folder
// per game. An empty `title_id` exports every game, otherwise just that one.
Result export_saves(const std::filesystem::path &savedata_root, const std::string &title_id, const std::filesystem::path &zip_path);

// Replaces saves from a ZIP made by export_saves (or a Vita3K savedata folder zipped by hand). With an empty
// `title_id` every top level folder named like a title id is imported; otherwise the archive must hold the
// saves of that one game. Saves that get replaced are first moved to `backup_root/<title id>/`. `work_dir`
// must be on the same volume as `savedata_root` and outside it, so an interrupted import never leaves a
// half written game behind.
Result import_saves(const std::filesystem::path &savedata_root, const std::filesystem::path &backup_root,
    const std::filesystem::path &work_dir, const std::string &title_id, const std::filesystem::path &zip_path);

// "PCSE00240" style ids: four capital letters and five digits.
bool is_title_id(const std::string &name);
}
