import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Apple's opaque identity token promises NSCoding and isEqual, not a stable
/// archive representation or NSSecureCoding. Only locally stored token archives
/// are decoded here; cloud documents never supply identity objects.
struct CloudSaveAccount: Sendable {
    static let identitiesKey = "saves.iCloud.identities"
    let id: String
    let archive: Data

    static func current() throws -> Self {
        guard let token = FileManager.default.ubiquityIdentityToken else { throw SaveSyncError.unavailable }
        return try identify(token, defaults: .standard)
    }

    static func identify(_ token: any NSObjectProtocol, defaults: UserDefaults) throws -> Self {
        var identities = defaults.dictionary(forKey: identitiesKey) as? [String: Data] ?? [:]
        for (id, archive) in identities where UUID(uuidString: id) != nil {
            let account = Self(id: id, archive: archive)
            if account.matches(token) { return account }
        }
        let archive = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: false)
        let account = Self(id: UUID().uuidString, archive: archive)
        identities[account.id] = archive
        defaults.set(identities, forKey: identitiesKey)
        return account
    }

    var isCurrent: Bool {
        guard let token = FileManager.default.ubiquityIdentityToken else { return false }
        return matches(token)
    }

    private func matches(_ token: any NSObjectProtocol) -> Bool {
        guard let decoder = try? NSKeyedUnarchiver(forReadingFrom: archive) else { return false }
        decoder.requiresSecureCoding = false
        decoder.decodingFailurePolicy = .setErrorAndReturn
        defer { decoder.finishDecoding() }
        guard let previous = decoder.decodeObject(forKey: NSKeyedArchiveRootObjectKey) else { return false }
        return token.isEqual(previous)
    }
}

@MainActor
final class CloudSaveSync: ObservableObject {
    static let preference = "saves.iCloud.enabled"
    @Published private(set) var enabled: Bool
    private enum Status {
        case message(String)
        case conflicts
        case failure(Error)
    }
    @Published private var state: Status = .message("Sincronização desativada.")
    var status: String {
        switch state {
        case .message(let key): L10n.text(key)
        case .conflicts: L10n.format("Há versões diferentes de %ld save(s). Escolha qual usar abaixo.", conflicts.count)
        case .failure(let error): error.localizedDescription
        }
    }
    @Published private(set) var conflicts: [SaveConflict] = []
    @Published private(set) var lastCheck: Date?
    private(set) var needsSync = false
    private var inFlight = false
    private var echoUntil = Date.distantPast
    private var query: NSMetadataQuery?
    private var gathered = false
    private var observers: [NSObjectProtocol] = []
    private var connection: Connection?

    private struct Connection: Sendable {
        let account: CloudSaveAccount
        let directory: URL
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: Self.preference)
        if enabled {
            state = .message("Aguardando sincronização.")
            needsSync = true
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSUbiquityIdentityDidChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.disconnect()
                    self.conflicts = []
                    self.lastCheck = nil
                    self.requestSync()
                }
            })
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.preference)
        if value {
            requestSync()
        } else {
            disconnect()
            needsSync = false
            conflicts = []
            state = .message("Sincronização desativada. Os saves e as cópias existentes foram mantidos.")
        }
    }

    func requestSync() {
        guard enabled else { return }
        needsSync = true
        state = .message("Aguardando sincronização com o jogo encerrado.")
    }

    func synchronize(documents: URL, usersRelativePath: String = "vita/ux0/user", resolution: SaveResolution? = nil) async {
        guard enabled else { return }
        inFlight = true
        defer { inFlight = false }
        needsSync = false
        state = .message("Verificando saves no iCloud…")
        do {
            if let connection, !connection.account.isCurrent { disconnect() }
            if connection == nil { try await connect() }
            // Give the initial metadata query time to discover remote documents.
            // Never interpret an incomplete query as an empty cloud library.
            for _ in 0..<30 where !gathered {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard gathered, let query, let connection else { throw SaveSyncError.downloading }
            query.disableUpdates()
            let urls = (0..<query.resultCount).compactMap { index -> URL? in
                (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemURLKey) as? URL
            }.filter { $0.deletingLastPathComponent().standardizedFileURL == connection.directory.standardizedFileURL }
            query.enableUpdates()
            #if os(iOS)
            let device = UIDevice.current.name
            #else
            let device = Host.current().localizedName ?? "Mac"
            #endif
            let (report, pendingUpload) = try await Task.detached(priority: .utility) {
                let engine = SaveSyncEngine(documents: documents, cloud: connection.directory,
                    account: connection.account.id, device: device, usersRelativePath: usersRelativePath, checkAccess: {
                        try Task.checkCancellation()
                        guard connection.account.isCurrent else { throw SaveSyncError.accountChanged }
                    })
                let report = try engine.synchronize(remoteURLs: urls, resolution: resolution)
                let files = try FileManager.default.contentsOfDirectory(at: connection.directory,
                    includingPropertiesForKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
                    .filter { $0.pathExtension == "vitasave" }
                var pending = false
                for file in files {
                    let values = try file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey, .ubiquitousItemUploadingErrorKey])
                    if let error = values.ubiquitousItemUploadingError { throw error }
                    if values.ubiquitousItemIsUploaded != true { pending = true }
                }
                return (report, pending)
            }.value
            guard self.connection?.account.id == connection.account.id, enabled else { return }
            conflicts = report.conflicts
            lastCheck = Date()
            // The engine's own publishes reach this device's query as updates
            // shortly after the pass; ignore that echo instead of queueing a
            // second, user-visible sync.
            echoUntil = Date().addingTimeInterval(10)
            if !conflicts.isEmpty {
                state = .conflicts
            } else if pendingUpload {
                state = .message("Saves preparados. Aguardando envio pelo iCloud; mantenha a conexão com a internet.")
            } else {
                state = .message("Todos os saves estão sincronizados.")
            }
        } catch {
            state = .failure(error)
            if case SaveSyncError.staleConflict = error { needsSync = true }
        }
    }

    private func connect() async throws {
        let identifier = Bundle.main.object(forInfoDictionaryKey: "Vita3KSaveContainer") as? String
        let result = try await Task.detached(priority: .utility) {
            let account = try CloudSaveAccount.current()
            guard let identifier,
                  let root = FileManager.default.url(forUbiquityContainerIdentifier: identifier) else {
                throw SaveSyncError.unavailable
            }
            guard account.isCurrent else { throw SaveSyncError.accountChanged }
            return Connection(account: account, directory: root.appendingPathComponent("Documents/Saves", isDirectory: true))
        }.value
        guard enabled, result.account.isCurrent else { throw SaveSyncError.accountChanged }
        connection = result
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        query.predicate = NSPredicate(format: "%K ENDSWITH %@", NSMetadataItemFSNameKey, ".vitasave")
        query.notificationBatchingInterval = 1
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: query, queue: .main) { [weak self] notification in
                let finished = notification.name == .NSMetadataQueryDidFinishGathering
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if finished { self.gathered = true }
                    // A running pass already merges the cloud directory from
                    // disk, and the echo window above swallows its own
                    // publishes; re-arm only for changes that land while idle.
                    guard !self.inFlight, self.echoUntil <= Date() else { return }
                    self.needsSync = self.enabled
                }
            })
        }
        self.query = query
        guard query.start() else { disconnect(); throw SaveSyncError.unavailable }
    }

    private func disconnect() {
        query?.stop()
        query = nil
        gathered = false
        connection = nil
        // Keep the identity observer (the first one) for future sign-ins.
        for observer in observers.dropFirst() { NotificationCenter.default.removeObserver(observer) }
        observers = Array(observers.prefix(1))
    }

    isolated deinit {
        query?.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

