import CryptoKit
import Foundation

struct SaveKey: Codable, Hashable, Sendable, Identifiable {
    let user: String
    let game: String
    var id: String { "\(user)/\(game)" }

    func validate() throws {
        guard SaveSnapshot.validComponent(user), SaveSnapshot.validComponent(game) else {
            throw SaveSyncError.invalidSnapshot
        }
    }
}

enum SaveSyncError: LocalizedError {
    case invalidSnapshot, unsafeFile, downloading, unavailable, accountChanged, staleConflict, legacySnapshot

    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: L10n.text("Uma cópia de save está inválida ou usa uma versão incompatível. Os saves locais foram preservados.")
        case .unsafeFile: L10n.text("A pasta de saves contém um link ou arquivo não suportado.")
        case .downloading: L10n.text("Aguardando o download dos saves pelo iCloud.")
        case .unavailable: L10n.text("iCloud indisponível. Verifique sua conta, o iCloud Drive e se esta instalação tem acesso ao iCloud.")
        case .accountChanged: L10n.text("A conta do iCloud mudou. Sincronize novamente para continuar.")
        case .staleConflict: L10n.text("Os saves mudaram desde a escolha. Confira as versões e tente novamente.")
        case .legacySnapshot: L10n.text("Há cópias antigas de saves. Atualize o Flowyr e sincronize no aparelho onde você joga antes de restaurar neste aparelho. Os saves locais foram preservados.")
        }
    }
}

/// A game is one atomic document, including empty directories and hidden files.
/// Immutable revisions avoid last-writer-wins data loss when devices play offline.
/// Ancestors record causality; device clocks are only used for display.
struct SaveSnapshot: Codable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        let path: String
        let data: Data? // nil = directory
    }

    // Version 2 guarantees canonical relative paths. Version 1 remains readable
    // as ancestry/baseline, but may contain the old /private/var prefix bug and
    // must be republished from the original device before being restored.
    var format = 2
    var revision = UUID()
    let key: SaveKey
    var ancestors: Set<UUID> = []
    var date = Date()
    var device: String
    let entries: [Entry]
    let digest: String

    init(key: SaveKey, device: String, entries: [Entry]) {
        self.key = key
        self.device = device
        self.entries = entries.sorted { $0.path < $1.path }
        digest = Self.fingerprint(self.entries)
    }

    static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\") && !value.contains("\0")
    }

    func validate() throws {
        try key.validate()
        guard (1...2).contains(format), !ancestors.contains(revision), digest == Self.fingerprint(entries) else {
            throw SaveSyncError.invalidSnapshot
        }
        var paths = Set<String>()
        let files = Set(entries.filter { $0.data != nil }.map(\.path))
        for entry in entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.allSatisfy(Self.validComponent), paths.insert(entry.path).inserted else {
                throw SaveSyncError.invalidSnapshot
            }
            for count in 1..<parts.count where files.contains(parts.prefix(count).joined(separator: "/")) {
                throw SaveSyncError.invalidSnapshot
            }
        }
    }

    private static func fingerprint(_ entries: [Entry]) -> String {
        var hash = SHA256()
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let path = Data(entry.path.utf8)
            // Length framing makes paths, directories and arbitrary binary data unambiguous.
            hash.update(data: Data("\(path.count):".utf8))
            hash.update(data: path)
            if let data = entry.data {
                hash.update(data: Data("f\(data.count):".utf8))
                hash.update(data: data)
            } else {
                hash.update(data: Data("d".utf8))
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct SaveConflict: Identifiable, Sendable {
    struct Version: Identifiable, Sendable {
        let id: UUID
        let date: Date
        let device: String
    }
    let key: SaveKey
    let localDigest: String?
    let heads: Set<UUID>
    let versions: [Version]
    var id: String { key.id }
}

struct SaveResolution: Sendable {
    let conflict: SaveConflict
    let revision: UUID? // nil = use this device
}

struct SaveSyncReport: Sendable {
    var conflicts: [SaveConflict] = []
    var uploaded = 0
    var restored = 0
}

/// Runs off the main thread, while the controller holds the library operation gate.
/// The cloud directory can also be a temporary directory in regression tests.
struct SaveSyncEngine {
    let documents: URL
    let cloud: URL
    let account: String
    let device: String
    // iOS stores the Vita filesystem under Documents/vita; desktop accepts a
    // configurable filesystem root. The snapshot format remains identical.
    var usersRelativePath = "vita/ux0/user"
    var checkAccess: () throws -> Void = {}
    private let fm = FileManager.default

    private var users: URL { documents.appendingPathComponent(usersRelativePath, isDirectory: true) }
    private var stateURL: URL { documents.appendingPathComponent(".save-sync/\(account).plist") }

    func synchronize(remoteURLs: [URL] = [], resolution: SaveResolution? = nil) throws -> SaveSyncReport {
        try checkAccess()
        try rejectLinks(to: stateURL)
        var baseline: [String: String] = [:]
        if fm.fileExists(atPath: stateURL.path) {
            baseline = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: stateURL))
        }
        // Combine metadata results (including not-yet-downloaded items) with the
        // filesystem so a just-published local revision is never missed.
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let diskURLs = try fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil)
        let urls = Set(remoteURLs + diskURLs).filter { $0.pathExtension == "vitasave" }
        var snapshots: [SaveKey: [SaveSnapshot]] = [:]
        var waitingForDownload = false
        for url in urls.sorted(by: { $0.path < $1.path }) {
            try checkAccess()
            do {
                let snapshot = try readCloud(url)
                let existing = snapshots[snapshot.key] ?? []
                // Keep only live branches in memory, even with a long history.
                if !existing.contains(where: { $0.ancestors.contains(snapshot.revision) }) {
                    snapshots[snapshot.key] = existing.filter { !snapshot.ancestors.contains($0.revision) } + [snapshot]
                }
            } catch SaveSyncError.downloading {
                waitingForDownload = true
            }
        }
        // Request every pending download in a pass, but never merge a partial view.
        if waitingForDownload { throw SaveSyncError.downloading }
        let keys = Set(try localKeys()).union(snapshots.keys).sorted { $0.id < $1.id }
        var report = SaveSyncReport()
        for key in keys {
            try checkAccess()
            let local = try readLocal(key)
            let remote = snapshots[key] ?? []
            let retired = remote.reduce(into: Set<UUID>()) { $0.formUnion($1.ancestors) }
            let heads = remote.filter { !retired.contains($0.revision) }
                .sorted { $0.revision.uuidString < $1.revision.uuidString }
            guard remote.isEmpty || !heads.isEmpty else { throw SaveSyncError.invalidSnapshot }
            let headIDs = Set(heads.map(\.revision))
            let remoteDigests = Set(heads.map(\.digest))
            let remoteHead = heads.first
            let previous = baseline[key.id]

            // A device may already have restored a malformed version-1 copy.
            // Its implicitly created wrapper directory also changes the digest;
            // check the layout before any branch can publish it as version 2.
            let oldDirectory = String(key.game.suffix(7))
            if let local, heads.contains(where: { $0.format == 1 }), !local.entries.isEmpty,
               local.entries.allSatisfy({ $0.path == oldDirectory || $0.path.hasPrefix(oldDirectory + "/") }) {
                throw SaveSyncError.legacySnapshot
            }

            if let resolution, resolution.conflict.key == key {
                guard resolution.conflict.localDigest == local?.digest,
                      resolution.conflict.heads == headIDs else { throw SaveSyncError.staleConflict }
                let chosen: SaveSnapshot?
                if let revision = resolution.revision {
                    chosen = heads.first { $0.revision == revision }
                } else {
                    chosen = local
                }
                guard let chosen else { throw SaveSyncError.staleConflict }
                guard chosen.format == 2 else { throw SaveSyncError.legacySnapshot }
                // Preserve a losing local version before publishing the choice,
                // even if it was never uploaded and local replacement later fails.
                if let local, local.digest != chosen.digest { try backup(local) }
                try publish(chosen, after: remote)
                report.uploaded += 1
                if local?.digest != chosen.digest {
                    try restore(chosen, replacing: local, backedUp: true)
                    report.restored += 1
                }
                baseline[key.id] = chosen.digest
            } else if remoteDigests.count <= 1, let local, local.digest == remoteHead?.digest {
                if heads.contains(where: { $0.format == 1 }) {
                    try publish(local, after: remote)
                    report.uploaded += 1
                }
                baseline[key.id] = local.digest
            } else if remoteDigests.count <= 1, let remoteHead,
                      local == nil || (previous != nil && local?.digest == previous) {
                try restore(remoteHead, replacing: local)
                report.restored += 1
                baseline[key.id] = remoteHead.digest
            } else if let local, remote.isEmpty || (remoteDigests.count == 1 && previous == remoteHead?.digest) {
                try publish(local, after: remote)
                report.uploaded += 1
                baseline[key.id] = local.digest
            } else if !heads.isEmpty {
                var seen = Set<String>()
                let versions = heads.filter { seen.insert($0.digest).inserted }.map {
                    SaveConflict.Version(id: $0.revision, date: $0.date, device: $0.device)
                }
                report.conflicts.append(SaveConflict(key: key, localDigest: local?.digest,
                    heads: headIDs, versions: versions))
            }
            // Checkpoint each game. A failure in another game cannot invalidate an
            // earlier restore or make a completed upload look like a new conflict.
            try checkAccess()
            try fm.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encode(baseline).write(to: stateURL, options: .atomic)
        }
        return report
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    private func localURL(_ key: SaveKey) throws -> URL {
        try key.validate()
        let url = users.appendingPathComponent("\(key.user)/savedata/\(key.game)", isDirectory: true)
        try rejectLinks(to: url)
        return url
    }

    /// Reject linked ancestors too; Documents is editable through Files/Finder.
    private func rejectLinks(to url: URL) throws {
        var current = url.standardizedFileURL
        let root = documents.standardizedFileURL
        guard current.path.hasPrefix(root.path + "/") else { throw SaveSyncError.unsafeFile }
        while current.path != root.path {
            if let attributes = try? fm.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw SaveSyncError.unsafeFile
            }
            current.deleteLastPathComponent()
        }
    }

    private func directories(_ url: URL) throws -> [URL] {
        try rejectLinks(to: url)
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            .filter {
                let values = try $0.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SaveSyncError.unsafeFile }
                return values.isDirectory == true
            }
    }

    private func localKeys() throws -> [SaveKey] {
        try directories(users).flatMap { user in
            try directories(user.appendingPathComponent("savedata")).map {
                SaveKey(user: user.lastPathComponent, game: $0.lastPathComponent)
            }
        }
    }

    private func readLocal(_ key: SaveKey) throws -> SaveSnapshot? {
        // Foundation's enumerator canonicalizes /var to /private/var on Apple
        // platforms. Derive relative names from the same canonical root;
        // slicing an uncanonicalized path silently corrupts snapshot paths.
        let root = try localURL(key).resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path) else { return nil }
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveSyncError.unsafeFile
        }
        var entries: [SaveSnapshot.Entry] = []
        var enumerationError: Error?
        guard let enumerator = fm.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SaveSyncError.unsafeFile
        }
        for case let url as URL in enumerator {
            try checkAccess()
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else {
                throw SaveSyncError.unsafeFile
            }
            let entryPath = url.standardizedFileURL.path
            guard entryPath.hasPrefix(root.path + "/") else { throw SaveSyncError.unsafeFile }
            let path = String(entryPath.dropFirst(root.path.count + 1))
            entries.append(.init(path: path, data: values.isDirectory == true ? nil : try Data(contentsOf: url)))
        }
        if let enumerationError { throw enumerationError }
        let snapshot = SaveSnapshot(key: key, device: device, entries: entries)
        try snapshot.validate()
        return snapshot
    }

    private func readCloud(_ url: URL) throws -> SaveSnapshot {
        guard url.deletingLastPathComponent().standardizedFileURL == cloud.standardizedFileURL else {
            throw SaveSyncError.invalidSnapshot
        }
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemDownloadingErrorKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw SaveSyncError.unsafeFile }
        if let error = values.ubiquitousItemDownloadingError { throw error }
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try fm.startDownloadingUbiquitousItem(at: url)
            throw SaveSyncError.downloading
        }
        return try coordinate(url, writing: false) { coordinated in
            let snapshot = try PropertyListDecoder().decode(SaveSnapshot.self, from: Data(contentsOf: coordinated))
            try snapshot.validate()
            guard coordinated.deletingPathExtension().lastPathComponent == snapshot.revision.uuidString else {
                throw SaveSyncError.invalidSnapshot
            }
            return snapshot
        }
    }

    private func publish(_ value: SaveSnapshot, after previous: [SaveSnapshot]) throws {
        var snapshot = value
        snapshot.revision = UUID()
        snapshot.date = Date()
        snapshot.device = device
        snapshot.ancestors = previous.reduce(into: Set<UUID>()) {
            $0.insert($1.revision)
            $0.formUnion($1.ancestors)
        }
        try snapshot.validate()
        let data = try encode(snapshot)
        let url = cloud.appendingPathComponent(snapshot.revision.uuidString).appendingPathExtension("vitasave")
        try coordinate(url, writing: true) { destination in
            try checkAccess()
            try data.write(to: destination, options: .atomic)
        }
    }

    private func backup(_ snapshot: SaveSnapshot) throws {
        let destination = documents.appendingPathComponent("Save Backups/\(snapshot.key.user)/\(snapshot.key.game)/\(UUID().uuidString).vitasave")
        try rejectLinks(to: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(snapshot).write(to: destination, options: .atomic)
    }

    private func restore(_ snapshot: SaveSnapshot, replacing local: SaveSnapshot?, backedUp: Bool = false) throws {
        try snapshot.validate()
        guard snapshot.format == 2 else { throw SaveSyncError.legacySnapshot }
        let target = try localURL(snapshot.key)
        let parent = target.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // Keep staging outside savedata so interrupted restores never become games.
        let staging = parent.deletingLastPathComponent().appendingPathComponent(".save-sync-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for entry in snapshot.entries {
            let url = staging.appendingPathComponent(entry.path)
            if let data = entry.data {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        try checkAccess()
        // Catch edits made through Files while preparing the replacement.
        guard try readLocal(snapshot.key)?.digest == local?.digest else { throw SaveSyncError.staleConflict }
        if let local {
            if !backedUp { try backup(local) }
            _ = try fm.replaceItemAt(target, withItemAt: staging, options: .usingNewMetadataOnly)
        } else {
            try fm.moveItem(at: staging, to: target)
        }
    }

    private func coordinate<T>(_ url: URL, writing: Bool, body: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let accessor: (URL) -> Void = { coordinated in result = Result { try body(coordinated) } }
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw SaveSyncError.unavailable }
        return try result.get()
    }
}
