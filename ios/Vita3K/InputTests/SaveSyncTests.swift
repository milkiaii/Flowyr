import XCTest
@testable import Vita3K

final class SaveSyncTests: XCTestCase {
    private let fm = FileManager.default
    private var root: URL!
    private var cloud: URL { root.appendingPathComponent("Cloud") }
    private let key = SaveKey(user: "00", game: "TEST00001")

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("SaveSyncTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func documents(_ device: String) -> URL { root.appendingPathComponent(device) }
    private func engine(_ device: String, cloud: URL? = nil, account: String = "test-account") -> SaveSyncEngine {
        SaveSyncEngine(documents: documents(device), cloud: cloud ?? self.cloud, account: account, device: device)
    }
    private func save(_ device: String, _ key: SaveKey? = nil) -> URL {
        let key = key ?? self.key
        return documents(device).appendingPathComponent("vita/ux0/user/\(key.user)/savedata/\(key.game)")
    }
    private func write(_ device: String, _ content: String, path: String = "save.dat", key: SaveKey? = nil) throws {
        let url = save(device, key).appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    private func read(_ device: String, path: String = "save.dat", key: SaveKey? = nil) throws -> String {
        try String(contentsOf: save(device, key).appendingPathComponent(path), encoding: .utf8)
    }
    private func snapshots() throws -> [URL] {
        try fm.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil).filter { $0.pathExtension == "vitasave" }
    }
    private func seedDevices() throws {
        try write("A", "initial")
        XCTAssertEqual(try engine("A").synchronize().uploaded, 1)
        XCTAssertEqual(try engine("B").synchronize().restored, 1)
    }

    func testRoundTripAllUsersAndUninstalledGamesIsIdempotent() throws {
        let other = SaveKey(user: "01", game: "UNINSTALLED")
        try write("A", "progress")
        try write("A", "metadata", path: "sce_sys/.hidden")
        try write("A", "second user", key: other)
        try fm.createDirectory(at: save("A").appendingPathComponent("empty"), withIntermediateDirectories: true)
        XCTAssertEqual(try engine("A").synchronize().uploaded, 2)
        XCTAssertEqual(try engine("B").synchronize().restored, 2)
        XCTAssertEqual(try read("B"), "progress")
        XCTAssertEqual(try read("B", path: "sce_sys/.hidden"), "metadata")
        XCTAssertEqual(try read("B", key: other), "second user")
        XCTAssertTrue(fm.fileExists(atPath: save("B").appendingPathComponent("empty").path))
        let report = try engine("B").synchronize()
        XCTAssertEqual(report.uploaded, 0)
        XCTAssertEqual(report.restored, 0)
        XCTAssertEqual(try snapshots().count, 2)
    }

    func testDesktopAndIOSUseTheSameSnapshotsWithDifferentStorageLayouts() throws {
        let desktop = root.appendingPathComponent("Custom Mac Library")
        let desktopSave = desktop.appendingPathComponent("ux0/user/00/savedata/TEST00001/save.dat")
        let mac = SaveSyncEngine(documents: desktop, cloud: cloud, account: "mac-account",
            device: "Mac", usersRelativePath: "ux0/user")
        try write("iPhone", "phone progress")
        XCTAssertEqual(try engine("iPhone").synchronize().uploaded, 1)
        XCTAssertEqual(try mac.synchronize().restored, 1)
        XCTAssertEqual(try String(contentsOf: desktopSave, encoding: .utf8), "phone progress")
        XCTAssertFalse(fm.fileExists(atPath: desktop.appendingPathComponent("vita").path))

        try Data("mac progress".utf8).write(to: desktopSave)
        XCTAssertEqual(try mac.synchronize().uploaded, 1)
        XCTAssertEqual(try engine("iPhone").synchronize().restored, 1)
        XCTAssertEqual(try read("iPhone"), "mac progress")

        try write("iPhone", "phone offline")
        _ = try engine("iPhone").synchronize()
        try Data("mac offline".utf8).write(to: desktopSave)
        let conflict = try XCTUnwrap(mac.synchronize().conflicts.first)
        XCTAssertEqual(try String(contentsOf: desktopSave, encoding: .utf8), "mac offline")
        _ = try mac.synchronize(resolution: .init(conflict: conflict, revision: conflict.versions[0].id))
        XCTAssertEqual(try String(contentsOf: desktopSave, encoding: .utf8), "phone offline")
        XCTAssertTrue(fm.fileExists(atPath: desktop.appendingPathComponent("Save Backups/00/TEST00001").path))
    }

    func testLegacyMalformedPathsAreNotRestoredAndOriginalDeviceCanRepublish() throws {
        try write("iPhone", "original progress")
        var legacy = SaveSnapshot(key: key, device: "old iPhone", entries: [
            .init(path: String(key.game.suffix(7)) + "/save.dat", data: Data("original progress".utf8))
        ])
        legacy.format = 1
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        try encoder.encode(legacy).write(to: cloud.appendingPathComponent(legacy.revision.uuidString + ".vitasave"))
        XCTAssertThrowsError(try engine("Mac").synchronize()) { error in
            guard case SaveSyncError.legacySnapshot = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(fm.fileExists(atPath: save("Mac").path))

        // The original device's baseline records the digest uploaded by the old build.
        let state = documents("iPhone").appendingPathComponent(".save-sync/test-account.plist")
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode([key.id: legacy.digest]).write(to: state)
        XCTAssertEqual(try engine("iPhone").synchronize().uploaded, 1)
        XCTAssertEqual(try engine("Mac").synchronize().restored, 1)
        XCTAssertEqual(try read("Mac"), "original progress")
        XCTAssertEqual(try snapshots().count, 2) // preserve the old archive as history
    }

    func testMatchingLegacySnapshotIsRepublishedWithCanonicalFormat() throws {
        try write("iPhone", "progress")
        var legacy = SaveSnapshot(key: key, device: "old iPhone", entries: [.init(path: "save.dat", data: Data("progress".utf8))])
        legacy.format = 1
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(legacy).write(to: cloud.appendingPathComponent(legacy.revision.uuidString + ".vitasave"))
        XCTAssertEqual(try engine("iPhone").synchronize().uploaded, 1)
        XCTAssertEqual(try engine("Mac").synchronize().restored, 1)
        XCTAssertEqual(try read("Mac"), "progress")
    }

    func testPreviouslyRestoredMalformedCopyIsNotRelabeledAsCanonical() throws {
        let prefix = String(key.game.suffix(7))
        try write("Mac", "old progress", path: prefix + "/save.dat")
        var legacy = SaveSnapshot(key: key, device: "old phone", entries: [
            .init(path: prefix + "/save.dat", data: Data("old progress".utf8))
        ])
        legacy.format = 1
        try fm.createDirectory(at: cloud, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(legacy).write(to: cloud.appendingPathComponent(legacy.revision.uuidString + ".vitasave"))
        XCTAssertThrowsError(try engine("Mac").synchronize())
        XCTAssertEqual(try snapshots().count, 1)
        XCTAssertEqual(try read("Mac", path: prefix + "/save.dat"), "old progress")
    }

    func testChangedSaveRestoresWholeDirectoryAndKeepsBackup() throws {
        try write("A", "obsolete", path: "old-slot.dat")
        try seedDevices()
        try fm.removeItem(at: save("A").appendingPathComponent("old-slot.dat"))
        try write("A", "level 2")
        XCTAssertEqual(try engine("A").synchronize().uploaded, 1)
        XCTAssertEqual(try engine("B").synchronize().restored, 1)
        XCTAssertEqual(try read("B"), "level 2")
        XCTAssertFalse(fm.fileExists(atPath: save("B").appendingPathComponent("old-slot.dat").path))
        let backups = documents("B").appendingPathComponent("Save Backups/00/TEST00001")
        let urls = try fm.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 1)
        let backup = try PropertyListDecoder().decode(SaveSnapshot.self, from: Data(contentsOf: XCTUnwrap(urls.first)))
        XCTAssertEqual(backup.entries.first { $0.path == "save.dat" }?.data, Data("initial".utf8))
    }

    func testFirstSyncWithExistingDifferentProgressRequiresChoice() throws {
        try write("A", "from A")
        try write("B", "from B")
        _ = try engine("A").synchronize()
        let report = try engine("B").synchronize()
        XCTAssertEqual(report.conflicts.count, 1)
        XCTAssertEqual(try read("B"), "from B")
        XCTAssertEqual(try snapshots().count, 1)
        let conflict = try XCTUnwrap(report.conflicts.first)
        let version = try XCTUnwrap(conflict.versions.first)
        let resolved = try engine("B").synchronize(resolution: .init(conflict: conflict, revision: version.id))
        XCTAssertTrue(resolved.conflicts.isEmpty)
        XCTAssertEqual(try read("B"), "from A")
        XCTAssertTrue(fm.fileExists(atPath: documents("B").appendingPathComponent("Save Backups/00/TEST00001").path))
    }

    func testOfflineBranchesArePreservedAndCanResolveToLocalProgress() throws {
        try seedDevices()
        let offlineCloud = root.appendingPathComponent("OfflineCloud")
        try fm.copyItem(at: cloud, to: offlineCloud)
        try write("A", "A offline")
        try write("B", "B offline")
        _ = try engine("A").synchronize()
        _ = try engine("B", cloud: offlineCloud).synchronize()
        for url in try fm.contentsOfDirectory(at: offlineCloud, includingPropertiesForKeys: nil) {
            let target = cloud.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        }
        let conflict = try XCTUnwrap(engine("B").synchronize().conflicts.first)
        XCTAssertEqual(conflict.versions.count, 2)
        XCTAssertEqual(try read("A"), "A offline")
        XCTAssertEqual(try read("B"), "B offline")
        XCTAssertEqual(try snapshots().count, 3)
        _ = try engine("B").synchronize(resolution: .init(conflict: conflict, revision: nil))
        let result = try engine("A").synchronize()
        XCTAssertTrue(result.conflicts.isEmpty)
        XCTAssertEqual(try read("A"), "B offline")
        XCTAssertEqual(try snapshots().count, 4) // both losing branches remain recoverable
    }

    func testConflictChoiceDoesNotOverwriteNewLocalChanges() throws {
        try seedDevices()
        try write("A", "new A")
        _ = try engine("A").synchronize()
        try write("B", "new B")
        let conflict = try XCTUnwrap(engine("B").synchronize().conflicts.first)
        try write("B", "even newer B")
        XCTAssertThrowsError(try engine("B").synchronize(resolution: .init(conflict: conflict, revision: conflict.versions[0].id)))
        XCTAssertEqual(try read("B"), "even newer B")
    }

    func testConflictChoiceDoesNotOverwriteNewRemoteChanges() throws {
        try seedDevices()
        try write("A", "new A")
        _ = try engine("A").synchronize()
        try write("B", "new B")
        let conflict = try XCTUnwrap(engine("B").synchronize().conflicts.first)
        try write("A", "even newer A")
        _ = try engine("A").synchronize()
        XCTAssertThrowsError(try engine("B").synchronize(resolution: .init(conflict: conflict, revision: nil)))
        XCTAssertEqual(try read("A"), "even newer A")
        XCTAssertEqual(try read("B"), "new B")
    }

    func testMissingLocalGameIsRestoredWithoutDeletingCloud() throws {
        try seedDevices()
        try fm.removeItem(at: save("B"))
        XCTAssertEqual(try engine("B").synchronize().restored, 1)
        XCTAssertEqual(try read("B"), "initial")
        XCTAssertEqual(try snapshots().count, 1)
    }

    func testAccountChangeDoesNotReusePreviousBaseline() throws {
        try seedDevices()
        try write("A", "updated")
        _ = try engine("A").synchronize()
        XCTAssertEqual(try engine("B", account: "different-account").synchronize().conflicts.count, 1)
        XCTAssertEqual(try read("B"), "initial")
    }

    func testInvalidSnapshotAndTraversalLeaveLocalSavesUntouched() throws {
        try seedDevices()
        let invalid = SaveSnapshot(key: key, device: "other", entries: [.init(path: "../escaped", data: Data())])
        let url = cloud.appendingPathComponent("\(invalid.revision.uuidString).vitasave")
        try PropertyListEncoder().encode(invalid).write(to: url)
        XCTAssertThrowsError(try engine("B").synchronize())
        XCTAssertEqual(try read("B"), "initial")
        XCTAssertFalse(fm.fileExists(atPath: save("B").deletingLastPathComponent().appendingPathComponent("escaped").path))
        for path in ["/absolute", "a//b", "..", "a/../b", "a\\b", ""] {
            let snapshot = SaveSnapshot(key: key, device: "other", entries: [.init(path: path, data: Data())])
            XCTAssertThrowsError(try snapshot.validate(), path)
        }
    }

    func testLinkedLocalFileCannotBeUploaded() throws {
        try write("A", "progress")
        let outside = root.appendingPathComponent("private")
        try Data("private".utf8).write(to: outside)
        try fm.createSymbolicLink(at: save("A").appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertThrowsError(try engine("A").synchronize())
        XCTAssertTrue(try snapshots().isEmpty)
    }

    func testAccessRevocationAndBackupFailurePreserveLocalProgress() throws {
        try seedDevices()
        try write("A", "updated")
        _ = try engine("A").synchronize()
        var revoked = engine("B")
        revoked.checkAccess = { throw SaveSyncError.accountChanged }
        XCTAssertThrowsError(try revoked.synchronize())
        XCTAssertEqual(try read("B"), "initial")
        // A file in place of the backup directory forces an actual I/O failure.
        try Data().write(to: documents("B").appendingPathComponent("Save Backups"))
        XCTAssertThrowsError(try engine("B").synchronize())
        XCTAssertEqual(try read("B"), "initial")
    }
}

@MainActor
final class SaveSyncControllerTests: XCTestCase {
    func testIdentityUsesObjectEqualityAcrossArchiveFormatsAndAccountSwitches() throws {
        let suite = "SaveSyncIdentity-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let token = NSUUID()
        let id = UUID().uuidString
        let encoder = NSKeyedArchiver(requiringSecureCoding: false)
        encoder.outputFormat = .xml
        encoder.encode(token, forKey: NSKeyedArchiveRootObjectKey)
        encoder.finishEncoding()
        defaults.set([id: encoder.encodedData], forKey: CloudSaveAccount.identitiesKey)
        XCTAssertEqual(try CloudSaveAccount.identify(token.copy() as! NSUUID, defaults: defaults).id, id)
        XCTAssertNotEqual(try CloudSaveAccount.identify(NSUUID(), defaults: defaults).id, id)
        XCTAssertEqual(try CloudSaveAccount.identify(token, defaults: defaults).id, id)
    }

    #if os(iOS)
    func testPresentedGameAndImportKeepPendingSyncOutOfSaveFiles() async {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: CloudSaveSync.preference)
        defer { defaults.set(old, forKey: CloudSaveSync.preference) }
        defaults.set(true, forKey: CloudSaveSync.preference)
        let controller = CoreController()
        controller.sessionInitialized = true
        controller.isGamePresented = true
        await controller.syncSaves()
        XCTAssertTrue(controller.saveSync.needsSync)
        XCTAssertNil(controller.saveSync.lastCheck)
        XCTAssertFalse(controller.canDeleteGame)
        controller.isGamePresented = false
        controller.isImporting = true
        await controller.syncSaves()
        XCTAssertTrue(controller.saveSync.needsSync)
        XCTAssertNil(controller.saveSync.lastCheck)
        controller.saveSync.setEnabled(false)
    }
    #endif

    #if os(macOS)
    func testDesktopBridgeDefersSyncWhileLibraryIsInUse() throws {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: CloudSaveSync.preference)
        defer {
            cloudEnable(old as? Bool ?? false)
            defaults.set(old, forKey: CloudSaveSync.preference)
        }
        cloudEnable(true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("Flowyr-InUse-\(UUID().uuidString)")
        path.path.withCString { cloudTick($0, false) }
        XCTAssertFalse(cloudBusy())
        let state = try XCTUnwrap(cloudState())
        defer { cloudFree(state) }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(String(cString: state).utf8)) as? [String: Any])
        XCTAssertEqual(json["lastCheck"] as? String, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
    #endif
}
