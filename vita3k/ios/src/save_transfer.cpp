#include <ios/save_transfer.h>

#include <ios/import_archive.h>

#include <miniz.h>

#include <algorithm>
#include <chrono>
#include <system_error>

namespace ios::save_transfer {
namespace fs = std::filesystem;

namespace {
bool ignored(const std::string &name) {
    return name == "__MACOSX" || name == ".DS_Store" || name == "Thumbs.db";
}

// Files and folders below `root`, as ZIP names relative to `root`. Links are skipped: a save is plain files.
bool collect(const fs::path &root, std::vector<std::pair<std::string, bool>> &out, std::string &error) {
    std::error_code ec;
    fs::recursive_directory_iterator it(root, fs::directory_options::skip_permission_denied, ec), end;
    if (ec) {
        error = "Não foi possível ler os saves: " + ec.message();
        return false;
    }
    for (; it != end; it.increment(ec)) {
        if (ec) {
            error = "Não foi possível ler os saves: " + ec.message();
            return false;
        }
        const auto status = it->symlink_status(ec);
        if (ec || fs::is_symlink(status))
            continue;
        if (ignored(it->path().filename().string()))
            continue;
        if (!fs::is_directory(status) && !fs::is_regular_file(status))
            continue;
        out.emplace_back(it->path().lexically_relative(root).generic_string(), fs::is_directory(status));
    }
    return true;
}

fs::path unique_dir(const fs::path &parent, const std::string &prefix) {
    const auto stamp = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    for (int i = 0;; ++i) {
        auto candidate = parent / (prefix + std::to_string(stamp) + (i ? "-" + std::to_string(i) : ""));
        if (!fs::exists(candidate))
            return candidate;
    }
}
}

bool is_title_id(const std::string &name) {
    if (name.size() != 9)
        return false;
    for (size_t i = 0; i < 9; ++i) {
        const bool letter = name[i] >= 'A' && name[i] <= 'Z';
        const bool digit = name[i] >= '0' && name[i] <= '9';
        if (i < 4 ? !letter : !digit)
            return false;
    }
    return true;
}

Result export_saves(const fs::path &savedata_root, const std::string &title_id, const fs::path &zip_path) {
    Result result;
    std::error_code ec;
    std::vector<std::string> titles;
    if (!title_id.empty()) {
        if (!is_title_id(title_id) || !fs::is_directory(savedata_root / title_id, ec)) {
            result.code = -2;
            return result;
        }
        titles.push_back(title_id);
    } else if (fs::is_directory(savedata_root, ec)) {
        for (const auto &entry : fs::directory_iterator(savedata_root, ec)) {
            const auto name = entry.path().filename().string();
            if (entry.is_directory(ec) && !entry.is_symlink(ec) && !ignored(name) && name.front() != '.')
                titles.push_back(name);
        }
        std::sort(titles.begin(), titles.end());
    }
    if (titles.empty()) {
        result.code = -2;
        return result;
    }

    fs::create_directories(zip_path.parent_path(), ec);
    fs::remove(zip_path, ec);
    mz_zip_archive zip{};
    if (!mz_zip_writer_init_file(&zip, zip_path.c_str(), 0)) {
        result.code = -3;
        result.error = "Não foi possível criar o arquivo ZIP.";
        return result;
    }
    bool ok = true;
    for (const auto &title : titles) {
        std::vector<std::pair<std::string, bool>> entries;
        if (!collect(savedata_root / title, entries, result.error)) {
            ok = false;
            break;
        }
        std::sort(entries.begin(), entries.end());
        // The game folder itself, so an empty save still comes back as a game
        ok = ok && mz_zip_writer_add_mem(&zip, (title + "/").c_str(), nullptr, 0, MZ_NO_COMPRESSION);
        for (const auto &[name, directory] : entries) {
            if (!ok)
                break;
            const auto archive_name = title + "/" + name + (directory ? "/" : "");
            ok = directory ? mz_zip_writer_add_mem(&zip, archive_name.c_str(), nullptr, 0, MZ_NO_COMPRESSION)
                           : mz_zip_writer_add_file(&zip, archive_name.c_str(), (savedata_root / title / name).c_str(), nullptr, 0, MZ_DEFAULT_LEVEL);
        }
        if (!ok && result.error.empty())
            result.error = "Falha ao gravar o ZIP.";
        if (!ok)
            break;
    }
    ok = ok && mz_zip_writer_finalize_archive(&zip);
    mz_zip_writer_end(&zip);
    if (!ok) {
        fs::remove(zip_path, ec);
        result.code = -3;
        if (result.error.empty())
            result.error = "Falha ao gravar o ZIP.";
        return result;
    }
    result.code = static_cast<int>(titles.size());
    result.titles = std::move(titles);
    return result;
}

Result import_saves(const fs::path &savedata_root, const fs::path &backup_root, const fs::path &work_dir,
    const std::string &title_id, const fs::path &zip_path) {
    Result result;
    std::error_code ec;
    if (!title_id.empty() && !is_title_id(title_id)) {
        result.code = -3;
        result.error = "Identificador de jogo inválido.";
        return result;
    }

    fs::create_directories(work_dir, ec);
    const auto staging = unique_dir(work_dir, ".save-import-");
    struct Cleanup {
        fs::path path;
        ~Cleanup() { std::error_code e; fs::remove_all(path, e); }
    } cleanup{ staging };

    if (!ios::import::extract_zip(zip_path, staging, result.error)) {
        result.code = -3;
        return result;
    }

    // Work out which folders hold saves, and for which game
    std::vector<std::pair<std::string, fs::path>> found; // title id, folder
    std::vector<fs::path> children;
    for (const auto &entry : fs::directory_iterator(staging, ec)) {
        if (!ignored(entry.path().filename().string()))
            children.push_back(entry.path());
    }
    if (title_id.empty()) {
        for (const auto &child : children) {
            if (fs::is_directory(child, ec) && is_title_id(child.filename().string()))
                found.emplace_back(child.filename().string(), child);
        }
    } else if (fs::is_directory(staging / title_id, ec)) {
        found.emplace_back(title_id, staging / title_id);
    } else if (children.size() == 1 && fs::is_directory(children.front(), ec)) {
        // One folder with another name, such as a renamed copy. One named like another game is that game's
        // saves, which must not end up in this one.
        if (is_title_id(children.front().filename().string())) {
            result.code = -4;
            result.error = "O arquivo contém saves de outro jogo.";
            return result;
        }
        found.emplace_back(title_id, children.front());
    } else if (!children.empty()) {
        // The contents of the save folder, zipped without the folder itself
        for (const auto &entry : fs::directory_iterator(staging, ec)) {
            if (ignored(entry.path().filename().string()))
                fs::remove_all(entry.path(), ec);
        }
        found.emplace_back(title_id, staging);
    }
    if (found.empty()) {
        result.code = -3;
        result.error = title_id.empty() ? "O arquivo não contém saves de nenhum jogo." : "O arquivo não contém saves deste jogo.";
        return result;
    }

    // Replace one game at a time, keeping whatever was there
    fs::create_directories(savedata_root, ec);
    for (const auto &[title, source] : found) {
        const auto target = savedata_root / title;
        fs::path backup;
        if (fs::exists(target, ec)) {
            fs::create_directories(backup_root / title, ec);
            backup = unique_dir(backup_root / title, "import-");
            fs::rename(target, backup, ec);
            if (ec) {
                result.code = -3;
                result.error = "Não foi possível guardar o save atual: " + title + " (" + ec.message() + ")";
                return result;
            }
        }
        fs::rename(source, target, ec);
        if (ec) {
            const auto message = ec.message();
            if (!backup.empty())
                fs::rename(backup, target, ec);
            result.code = -3;
            result.error = "Não foi possível instalar o save: " + title + " (" + message + ")";
            return result;
        }
        result.titles.push_back(title);
    }
    result.code = static_cast<int>(result.titles.size());
    return result;
}
}
