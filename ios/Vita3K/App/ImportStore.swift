import Foundation

/// Persistent receipts shared by the picker, startup and the Files watcher.
/// A receipt is saved before entering native code, so a killed process cannot
/// cause an endless automatic retry on the next launch.
struct ImportStore {
    struct Fingerprint: Codable, Equatable, Sendable {
        let size: UInt64
        let modified: TimeInterval

        init(url: URL) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
    }

    enum Status: String, Codable { case installing, succeeded, failed }
    struct Receipt: Codable {
        let fingerprint: Fingerprint
        var status: Status
        var report: String
        var sourceRemoved: Bool?
    }

    let directory: URL
    private(set) var receipts: [String: Receipt]
    private let legacyDone: Set<String>
    private let legacyFailed: [String: TimeInterval]
    private var journal: URL { directory.appendingPathComponent(".imports-state.json") }

    init(directory: URL) throws {
        self.directory = directory
        let journal = directory.appendingPathComponent(".imports-state.json")
        if FileManager.default.fileExists(atPath: journal.path) {
            // A damaged/unwritable receipt must produce an error, never silently
            // turn all retained archives into new installs.
            receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: journal))
        } else {
            receipts = [:]
        }
        func lines(_ name: String) -> [String] {
            ((try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }
        legacyDone = Set(lines(".imports-done") + lines(".fw-done"))
        var failed: [String: TimeInterval] = [:]
        for line in lines(".imports-failed") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let time = Double(parts[1]) { failed[String(parts[0])] = time }
        }
        legacyFailed = failed
    }

    func shouldImport(_ name: String, fingerprint: Fingerprint) -> Bool {
        if let receipt = receipts[name] {
            if receipt.sourceRemoved == true { return true }
            return receipt.status == .failed && receipt.fingerprint != fingerprint
        }
        return !legacyDone.contains(name) && legacyFailed[name] != fingerprint.modified
    }

    mutating func record(_ name: String, fingerprint: Fingerprint, status: Status, report: String = "") throws {
        receipts[name] = Receipt(fingerprint: fingerprint, status: status, report: report)
        try save()
    }

    mutating func markSourceRemoved(_ name: String) throws {
        guard receipts[name] != nil else { return }
        receipts[name]?.sourceRemoved = true
        try save()
    }

    mutating func recoverInterrupted() throws -> [String] {
        let names = receipts.keys.filter { receipts[$0]?.status == .installing }.sorted()
        for name in names {
            receipts[name]?.status = .failed
            receipts[name]?.report = L10n.text("A importação foi interrompida antes de terminar. Selecione o arquivo em Importar para tentar novamente.")
        }
        if !names.isEmpty { try save() }
        return names.map { "\($0): \(receipts[$0]!.report)" }
    }

    private func save() throws {
        try JSONEncoder().encode(receipts).write(to: journal, options: .atomic)
    }
}

enum ImportStaging {
    struct Outcome: Sendable {
        var succeeded: Bool
        var message: String
    }

    /// Run on a worker: consume only the staging copy, even when installation
    /// or receipt persistence fails. Keep the report after removing the source.
    static func consume(_ source: URL, in directory: URL,
                        install: (String) -> (Int32, String)) -> Outcome {
        let name = source.lastPathComponent
        var store: ImportStore?
        var outcome = Outcome(succeeded: false, message: "")
        do {
            try validateSource(source, in: directory)
            store = try ImportStore(directory: directory)
            let fingerprint = try ImportStore.Fingerprint(url: source)
            try store?.record(name, fingerprint: fingerprint, status: .installing)
            let (rc, report) = install(source.path)
            outcome = Outcome(succeeded: rc == 0, message: ImportReport.message(rc: rc, report: report))
            try store?.record(name, fingerprint: fingerprint, status: rc == 0 ? .succeeded : .failed,
                              report: outcome.message)
        } catch {
            outcome.succeeded = false
            outcome.message += (outcome.message.isEmpty ? "" : "\n") + L10n.format("Não foi possível concluir a importação de %@: %@", name, error.localizedDescription)
        }

        do {
            try validateSource(source, in: directory)
            do { try FileManager.default.removeItem(at: source) }
            catch CocoaError.fileNoSuchFile { /* Already removed. */ }
        } catch {
            outcome.message += "\n" + L10n.format("Não foi possível apagar %@ da pasta imports: %@", name, error.localizedDescription)
            return outcome
        }
        do {
            // A newly copied file with the same name is a new attempt, even
            // when its size and timestamp match the source just consumed.
            try store?.markSourceRemoved(name)
        } catch {
            outcome.message += "\n" + L10n.format("O arquivo foi apagado, mas não foi possível atualizar o histórico: %@", error.localizedDescription)
        }
        return outcome
    }

    private static func validateSource(_ source: URL, in directory: URL) throws {
        guard source.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == directory.standardizedFileURL.resolvingSymlinksInPath().path,
              !source.lastPathComponent.hasPrefix(".") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
    }

    /// Called on a worker while the caller holds the security-scoped access.
    /// Publish the completed copy by renaming it; the watcher never sees a
    /// half-copied picker file. Selecting a file already in imports is safe.
    static func copy(_ source: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        if source.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL {
            return destination
        }
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        if directory.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(sourcePath + "/")
            || directory.resolvingSymlinksInPath().standardizedFileURL.path == sourcePath {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let temporary = directory.appendingPathComponent(".copy-" + UUID().uuidString)
        defer { try? fm.removeItem(at: temporary) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do { try fm.copyItem(at: readable, to: temporary) }
            catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: temporary, to: destination)
        return destination
    }
}


/// Turns the installer's raw report into one short line in the app language.
enum ImportReport {
    static func message(rc: Int32, report: String) -> String {
        if rc == 0 {
            let successes = ["PKG instalado", "Licença instalada", "Firmware instalado", "Jogo já instalado"]
            for key in successes where report.contains(key) {
                return key == "Jogo já instalado" ? L10n.text("O jogo já está instalado.") : L10n.text(key)
            }
            return L10n.text("Jogo instalado")
        }
        let lines = report.split(separator: "\n").map(String.init)
        let prefixes: [(String, String)] = [
            ("Este PKG precisa de uma licença", "Este PKG precisa de uma licença. Toque em + e adicione a licença ou a chave zRIF; depois instale o PKG de novo."),
            ("Arquivo de importação não encontrado", "Arquivo de importação não encontrado."),
            ("Chave zRIF inválida", "Chave zRIF inválida. Cole a chave inteira, sem texto extra."),
            ("Falha na importação", "Falha na importação."),
        ]
        var out: [String] = []
        for line in lines {
            if let hit = prefixes.first(where: { line.hasPrefix($0.0) }) { out.append(L10n.text(hit.1)); continue }
            let t = L10n.text(line)
            // Lines that are not translated debug output stay hidden.
            if t != line || line.first?.isUppercase == true { out.append(t) }
        }
        return out.isEmpty ? L10n.format("Falha na importação (código %d)", rc) : out.joined(separator: "\n")
    }
}


/// Messages produced by the core are written in Portuguese: show them in the app language.
enum CoreMessage {
    static func localized(_ report: String) -> String {
        report.split(separator: "\n", omittingEmptySubsequences: true)
            .map { L10n.text(String($0)) }
            .joined(separator: "\n")
    }
}
