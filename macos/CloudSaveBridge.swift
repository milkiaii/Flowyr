import Foundation

// All entry points are called by Qt on the main thread. Work is performed by
// the shared iOS engine off-thread; busy stays true until that work finishes.
@MainActor
private final class DesktopSaves {
    static let shared = DesktopSaves()
    let sync = CloudSaveSync()
    var busy = false
    var idle = false
    var root: URL?

    func run(_ resolution: SaveResolution? = nil) {
        guard !busy, idle, sync.enabled, let root else { return }
        busy = true
        Task {
            await sync.synchronize(documents: root, usersRelativePath: "ux0/user", resolution: resolution)
            busy = false
        }
    }
}

@_cdecl("flowyr_cloud_tick") @MainActor
public func cloudTick(_ path: UnsafePointer<CChar>, _ safe: Bool) {
    let service = DesktopSaves.shared
    service.idle = safe
    guard !service.busy else { return }
    let root = URL(fileURLWithPath: String(cString: path), isDirectory: true).standardizedFileURL
    if service.root != root {
        service.root = root
        service.sync.requestSync()
    }
    if safe && service.sync.needsSync { service.run() }
}

@_cdecl("flowyr_cloud_busy") @MainActor
public func cloudBusy() -> Bool { DesktopSaves.shared.busy }

@_cdecl("flowyr_cloud_enable") @MainActor
public func cloudEnable(_ enabled: Bool) {
    guard !DesktopSaves.shared.busy else { return }
    DesktopSaves.shared.sync.setEnabled(enabled)
}

@_cdecl("flowyr_cloud_request") @MainActor
public func cloudRequest() { DesktopSaves.shared.sync.requestSync() }

@_cdecl("flowyr_cloud_resolve") @MainActor
public func cloudResolve(_ key: UnsafePointer<CChar>, _ revision: UnsafePointer<CChar>) {
    let service = DesktopSaves.shared
    guard !service.busy,
          let conflict = service.sync.conflicts.first(where: { $0.id == String(cString: key) }) else { return }
    let value = String(cString: revision)
    let id = value.isEmpty ? nil : UUID(uuidString: value)
    guard value.isEmpty || (id != nil && conflict.versions.contains(where: { $0.id == id })) else { return }
    service.run(SaveResolution(conflict: conflict, revision: id))
}

@_cdecl("flowyr_cloud_state") @MainActor
public func cloudState() -> UnsafeMutablePointer<CChar>? {
    let service = DesktopSaves.shared
    let sync = service.sync
    let state: [String: Any] = [
        "enabled": sync.enabled, "busy": service.busy, "status": sync.status,
        "lastCheck": sync.lastCheck?.formatted(date: .abbreviated, time: .shortened) ?? "",
        "conflicts": sync.conflicts.map { conflict -> [String: Any] in
            ["id": conflict.id, "game": conflict.key.game, "user": conflict.key.user,
             "local": conflict.localDigest != nil,
             "versions": conflict.versions.map { version in
                 ["id": version.id.uuidString, "device": version.device,
                  "date": version.date.formatted(date: .abbreviated, time: .shortened)]
             }]
        }
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: state),
          let json = String(data: data, encoding: .utf8) else { return nil }
    return strdup(json)
}

@_cdecl("flowyr_cloud_free")
public func cloudFree(_ string: UnsafeMutablePointer<CChar>?) { free(string) }
