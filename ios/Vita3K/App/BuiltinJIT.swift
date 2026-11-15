import SwiftUI
import Network
import Vita3KCore

// Built-in JIT: no JIT app. The player imports their pairing file once; from then on a helper process
// (the FlowyrRamHelper extension running StikJIT) attaches a debugger to Flowyr by itself whenever JIT is
// off, through LocalDevVPN, the same way StikDebug does. Not inside LiveContainer, which can't start the
// helper: there the usual way (LiveContainer or StikDebug enabling JIT) is unchanged.
// StikJIT is by the StikDebug team (MPL-2.0); it bundles jkcoxson's idevice (MIT). The tunnel check below
// follows Hinoki's implementation (credits in README).

@MainActor
final class BuiltinJIT: ObservableObject {
    static let shared = BuiltinJIT()
    static let autoKey = "jit.builtinAuto"

    @Published private(set) var status = ""
    @Published private(set) var busy = false

    /// Always-on log (Documents/logs/builtin-jit.log), independent of the game log: the JIT check runs before any
    /// game session exists, so nothing else would record it.
    nonisolated static func log(_ text: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = documents.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("builtin-jit.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(text)\n"
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: file)
        }
    }

    /// Where StikJIT's guide keeps it (Files and Finder can reach Documents)
    static var pairingURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("StikJIT/pairingFile.plist")
    }

    static var hasPairingFile: Bool { FileManager.default.isReadableFile(atPath: pairingURL.path) }

    /// Why it can't run here, nil when it can
    static var unavailableReason: String? {
        guard let reason = v3k_builtin_jit_unavailable_reason() else { return nil }
        return String(cString: reason)
    }

    static var usable: Bool { hasPairingFile && unavailableReason == nil }

    /// Whether Flowyr enables JIT by itself when it opens and JIT is off (default on; needs a pairing file)
    static var autoEnabled: Bool {
        UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true
    }

    /// Copies the picked file in (atomically) and enables JIT straight away
    func importPairingFile(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            // A pairing file is a property list; anything else is the wrong file
            guard (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else {
                status = "That file isn't a pairing file (it should be a .plist or .mobiledevicepairing file)"
                return
            }
            let target = Self.pairingURL
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            Self.log("pairing file imported")
            status = "Pairing file imported"
            objectWillChange.send()
        } catch {
            status = "Could not import the pairing file: \(error.localizedDescription)"
        }
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: Self.pairingURL)
        status = "Pairing file removed"
        objectWillChange.send()
    }

    /// Called while JIT is being checked (CoreController.checkJIT): starts the helper if wanted and waits until
    /// the debugger is attached (or the attempt ends), so the caller can then prepare the JIT memory. With a
    /// TXM device the helper stays attached until that preparation has happened, so this must not wait for
    /// the helper to finish.
    func enableAndWait(timeout: TimeInterval = 180) async {
        // busy: the player started it by hand (Settings), so wait for that even if automatic is off
        Self.log("enableAndWait: usable=\(Self.usable) pairing=\(Self.hasPairingFile) reason=\(Self.unavailableReason ?? "none") auto=\(Self.autoEnabled) busy=\(busy) cs_debugged=\(vita3k_ios_cs_debugged())")
        guard Self.usable, busy || Self.autoEnabled, vita3k_ios_cs_debugged() != 1 else { return }
        if !busy { enable() }
        let deadline = Date().addingTimeInterval(timeout)
        while busy, vita3k_ios_cs_debugged() != 1, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        Self.log("enableAndWait done: busy=\(busy) cs_debugged=\(vita3k_ios_cs_debugged()) timedOut=\(Date() >= deadline)")
    }

    func enable() {
        guard !busy else { return }
        if let reason = Self.unavailableReason {
            status = reason
            return
        }
        guard let pairing = try? Data(contentsOf: Self.pairingURL), !pairing.isEmpty else {
            status = "Import your pairing file first"
            return
        }
        busy = true
        status = "Looking for the device (LocalDevVPN)"
        Self.log("enable: started")
        // The device's developer services are found from the app first: iOS only asks for Local Network
        // access from the app, and newer iOS versions move the Remote Pairing port away from 49152
        DeviceTunnel.find { found in
            Task { @MainActor in
                let this = BuiltinJIT.shared
                Self.log("tunnel: \(found.log)")
                if let port = found.port {
                    this.start(pairing: pairing, port: port)
                } else {
                    this.finished(ok: false, message: found.problem ?? "LocalDevVPN isn't connected")
                }
            }
        }
    }

    private func start(pairing: Data, port: UInt16) {
        status = "Starting"
        // No script: StikJIT attaches and lets go where that is enough, and runs its universal script
        // (the protocol Flowyr's JIT memory follows, as with StikDebug) where the device needs it.
        pairing.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self).baseAddress
            v3k_builtin_jit_start(bytes, pairing.count, nil, false, port, builtinJITProgress, builtinJITDone)
        }
    }

    fileprivate func update(_ text: String) {
        Self.log("progress: \(text)")
        status = text
    }

    fileprivate func finished(ok: Bool, message: String?) {
        busy = false
        if ok {
            status = "JIT enabled"
        } else {
            let reason = message ?? "unknown error"
            // The usual cause: no route to the device's own developer services
            let lowered = reason.lowercased()
            if reason.hasPrefix("Local Network") || reason.hasPrefix("LocalDevVPN") {
                status = reason
            } else if lowered.contains("unreachable") || lowered.contains("timed out") || lowered.contains("connect") {
                status = "Couldn't reach the device: is LocalDevVPN connected? (\(reason))"
            } else {
                status = "Failed: \(reason)"
            }
        }
        let outcome = ok ? "done" : "failed: \(status)"
        Self.log("finished: \(outcome) (helper message: \(message ?? "none"))")
    }
}

private func builtinJITProgress(_ text: UnsafePointer<CChar>?) {
    guard let text else { return }
    let line = String(cString: text)
    Task { @MainActor in BuiltinJIT.shared.update(line) }
}

private func builtinJITDone(_ ok: Bool, _ message: UnsafePointer<CChar>?) {
    let text = message.map { String(cString: $0) }
    Task { @MainActor in BuiltinJIT.shared.finished(ok: ok, message: text) }
}

/// Finds the device's own Remote Pairing service through LocalDevVPN (10.7.0.1) and checks it answers.
/// The port comes from Bonjour, as StikJIT does it, but only one that really answers on 10.7.0.1 is
/// used: on Wi-Fi other Apple devices advertise the same service, and taking theirs gave a port this
/// iPhone doesn't listen on.
enum DeviceTunnel {
    static let address = "10.7.0.1"
    static let defaultPort: UInt16 = 49152

    struct Found: Sendable {
        var port: UInt16?
        var problem: String?
        var log: String
    }

    private static let queue = DispatchQueue(label: "flowyr.builtin-jit.tunnel")

    static func find(completion: @escaping @Sendable (Found) -> Void) {
        queue.async {
            let browsed = browse(timeout: 4)
            var tried: [UInt16] = []
            // the loopback service first (the device's own, through the tunnel), then the usual port, then the rest
            let ordered = browsed.loopback + [defaultPort] + browsed.other
            for port in ordered where !tried.contains(port) {
                tried.append(port)
                if reachable(port: port, timeout: port == defaultPort || browsed.loopback.contains(port) ? 8 : 3) {
                    completion(Found(port: port, problem: nil, log: "device reachable at \(address):\(port) (Bonjour: \(browsed.summary))"))
                    return
                }
            }
            let problem: String
            if browsed.denied {
                problem = "Local Network access is off for Flowyr: turn it on in Settings › Privacy & Security › Local Network, then try again"
            } else {
                problem = "LocalDevVPN isn't connected: open LocalDevVPN, connect it, then try again (nothing answered at \(address))"
            }
            completion(Found(port: nil, problem: problem, log: "device not reachable, tried ports \(tried) (Bonjour: \(browsed.summary))"))
        }
    }

    private struct Browsed {
        var loopback: [UInt16] = []
        var other: [UInt16] = []
        var denied = false
        var summary = "nothing found"
    }

    /// Lists the _remotepairing._tcp services and resolves their ports (iOS asks for Local Network access here)
    private static func browse(timeout: TimeInterval) -> Browsed {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var services: [(endpoint: NWEndpoint, loopback: Bool)] = []
            var denied = false
            var failure: String?
        }
        let state = State()
        let browseQueue = DispatchQueue(label: "flowyr.builtin-jit.browse")
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: parameters)
        browser.browseResultsChangedHandler = { results, _ in
            state.lock.lock()
            state.services = results.compactMap { result -> (endpoint: NWEndpoint, loopback: Bool)? in
                guard case .service = result.endpoint else { return nil }
                return (endpoint: result.endpoint, loopback: result.interfaces.contains { $0.name.hasPrefix("lo") })
            }
            state.lock.unlock()
        }
        browser.stateUpdateHandler = { browserState in
            var error: NWError?
            switch browserState {
            case .failed(let e): error = e
            case .waiting(let e): error = e
            default: break
            }
            guard let error else { return }
            state.lock.lock()
            state.failure = "\(error)"
            // kDNSServiceErr_PolicyDenied: Local Network access refused
            if case .dns(let code) = error, code == -65570 || code == -65555 { state.denied = true }
            state.lock.unlock()
        }
        browser.start(queue: browseQueue)
        // done early once the device's own (loopback) service shows up, or the browse is refused
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            state.lock.lock()
            let settled = state.denied || state.services.contains { $0.loopback }
            state.lock.unlock()
            if settled { break }
        }
        browser.cancel()

        state.lock.lock()
        let services = state.services
        var result = Browsed()
        result.denied = state.denied
        let failure = state.failure
        state.lock.unlock()

        for service in services.prefix(6) {
            guard let port = resolvePort(service.endpoint, parameters: parameters) else { continue }
            if service.loopback { result.loopback.append(port) } else { result.other.append(port) }
        }
        result.summary = "\(services.count) service(s), loopback ports \(result.loopback), other ports \(result.other)\(failure.map { ", \($0)" } ?? "")"
        return result
    }

    private static func resolvePort(_ endpoint: NWEndpoint, parameters: NWParameters) -> UInt16? {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var port: UInt16?
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(to: endpoint, using: parameters)
        let record = { [weak connection] in
            guard let connection, case .hostPort(_, let port) = connection.currentPath?.remoteEndpoint, port.rawValue != 0 else { return }
            box.lock.lock()
            let first = box.port == nil
            box.port = port.rawValue
            box.lock.unlock()
            if first { done.signal() }
        }
        connection.pathUpdateHandler = { path in
            if path.status == .satisfied { record() }
        }
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready, .waiting: record()
            case .failed: done.signal()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "flowyr.builtin-jit.resolve"))
        _ = done.wait(timeout: .now() + 2)
        connection.cancel()
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.port
    }

    /// A TCP connection to the device's developer services through the tunnel
    private static func reachable(port: UInt16, timeout: TimeInterval) -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var ok = false
        }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
        connection.stateUpdateHandler = { connectionState in
            switch connectionState {
            case .ready:
                box.lock.lock()
                box.ok = true
                box.lock.unlock()
                done.signal()
            case .failed, .waiting:
                // waiting: no route to 10.7.0.1 (LocalDevVPN off) or the connection was refused
                done.signal()
            default:
                break
            }
        }
        connection.start(queue: DispatchQueue(label: "flowyr.builtin-jit.probe"))
        _ = done.wait(timeout: .now() + timeout)
        connection.cancel()
        box.lock.lock()
        defer { box.lock.unlock() }
        return box.ok
    }
}
