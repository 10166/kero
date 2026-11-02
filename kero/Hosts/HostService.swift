import CryptoKit
import Darwin
import Foundation

/// A capability for one expansion of one host. Collapsing invalidates the
/// capability and closes every operation/watch; old workers cannot reconnect.
nonisolated final class HostService: @unchecked Sendable {
    @TaskLocal static var current: HostService?
    let hostID: UUID
    private let socketPath: String?
    private let lock = NSLock()
    private var active = true
    private var imageUploadSupported = false
    private var wires: [UUID: DaemonWire] = [:]
    private var idle: [(UUID, DaemonWire, String)] = []
    private var isLocal: Bool { hostID == HostGroups.localID }
    init(hostID: UUID, socketPath: String?) {
        self.hostID = hostID
        self.socketPath = socketPath
    }
    func invalidate() {
        lock.lock()
        active = false
        let pending = Array(wires.values)
        wires = [:]
        idle = []
        lock.unlock()
        pending.forEach { $0.close() }
    }
    private func open() throws -> (UUID, DaemonWire, String) {
        lock.lock()
        let allowed = active
        if allowed, let cached = idle.popLast() {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard allowed, let socketPath else {
            throw DaemonWire.Failure("Host is disconnected. Expand its group before continuing.")
        }
        let wire = try DaemonWire(path: socketPath)
        wire.setReadTimeout(65)
        let id = UUID()
        lock.lock()
        guard active else {
            lock.unlock()
            wire.close()
            throw DaemonWire.Failure("Host was disconnected")
        }
        wires[id] = wire
        lock.unlock()
        do {
            try wire.request(["op": "hello", "version": 1])
            let hello = try wire.event()
            guard let host = hello["host"] as? String else {
                throw DaemonWire.Failure("Missing host identity")
            }
            lock.lock()
            imageUploadSupported =
                (hello["capabilities"] as? [String])?.contains("clipboard-image-v1") == true
            lock.unlock()
            return (id, wire, host)
        } catch {
            finish(id, wire)
            throw error
        }
    }
    private func recycle(_ id: UUID, _ wire: DaemonWire, _ host: String) {
        lock.lock()
        if active, idle.count < 4 {
            idle.append((id, wire, host))
            lock.unlock()
        } else {
            lock.unlock()
            finish(id, wire)
        }
    }
    private func finish(_ id: UUID, _ wire: DaemonWire) {
        wire.close()
        lock.lock()
        wires.removeValue(forKey: id)
        lock.unlock()
    }
    func request(_ action: String, path: String, fields: [String: Any] = [:]) throws -> [String: Any] {
        guard path.hasPrefix("/") else { throw DaemonWire.Failure("Host paths must be absolute") }
        if isLocal { return try localRequest(action, path: path, fields: fields) }
        let (id, wire, host) = try open()
        var succeeded = false
        defer { if succeeded { recycle(id, wire, host) } else { finish(id, wire) } }
        var request = fields
        request["action"] = action
        request["path"] = ["host": host, "path": path]
        if let destination = fields["destination"] as? String {
            request["destination"] = ["host": host, "path": destination]
        }
        do {
            try wire.request(["op": "host", "request": request])
            let event = try wire.event()
            guard let response = event["response"] as? [String: Any] else {
                throw DaemonWire.Failure("Invalid host response")
            }
            succeeded = true
            return response
        } catch {
            if !["read", "read_directory", "repository"].contains(action) {
                throw DaemonWire.Failure(
                    "\(error.localizedDescription)\nThe operation was not retried. Refresh to check whether it completed before trying again."
                )
            }
            throw error
        }
    }
    struct File: Sendable {
        let data: Data
        let sha256: String
    }
    func uploadImage(_ data: Data, key: DaemonSessionIdentity) throws -> String {
        let (id, wire, host) = try open()
        var succeeded = false
        defer { if succeeded { recycle(id, wire, host) } else { finish(id, wire) } }
        lock.lock()
        let supported = imageUploadSupported
        lock.unlock()
        guard supported else {
            throw DaemonWire.Failure(
                "The running daemon predates image paste. Restart it after ending its active sessions to enable this feature. Existing tasks were preserved."
            )
        }
        try wire.request([
            "op": "upload_image", "key": try DaemonWire.object(key), "data": data.base64EncodedString(),
        ])
        let response = try wire.event()
        guard let path = response["path"] as? String, path.hasPrefix("/"),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            response["sha256"] as? String
                == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined()
        else { throw DaemonWire.Failure("Image upload could not be verified. It was not pasted or retried.") }
        succeeded = true
        return path
    }
    func read(_ path: String) throws -> File {
        if isLocal {
            try checkActive()
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return File(data: data, sha256: Self.hash(data))
        }
        let value = try request("read", path: path)
        guard let base64 = value["data"] as? String, let data = Data(base64Encoded: base64),
            let hash = value["sha256"] as? String
        else { throw DaemonWire.Failure("Invalid file response") }
        return File(data: data, sha256: hash)
    }
    @discardableResult func write(_ path: String, data: Data, expected: String) throws -> String {
        if isLocal {
            try checkActive()
            let url = URL(fileURLWithPath: path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw DaemonWire.Failure("Only regular local files can be saved")
            }
            let current = try Data(contentsOf: url)
            guard Self.hash(current) == expected else {
                throw DaemonWire.Failure("File changed on disk. Refresh before saving.")
            }
            let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
            // Verify again immediately before the atomic replacement. The
            // comparison guards ordinary external edits without claiming to
            // provide a filesystem transaction against another writer.
            try checkActive()
            try data.write(to: url, options: .atomic)
            if let permissions {
                try FileManager.default.setAttributes(
                    [.posixPermissions: permissions], ofItemAtPath: path
                )
            }
            return Self.hash(data)
        }
        let value = try request(
            "write", path: path,
            fields: ["data": data.base64EncodedString(), "expected_sha256": expected])
        guard let hash = value["sha256"] as? String else {
            throw DaemonWire.Failure("Invalid save response")
        }
        return hash
    }
    struct Entry: Decodable, Sendable {
        let name: String
        let is_dir: Bool
        let is_symlink: Bool
    }
    func directory(_ path: String) throws -> [Entry] {
        if isLocal {
            try checkActive()
            // Foundation's URL directory enumerator rejects a symlink used as
            // the directory URL, even though POSIX and the remote daemon follow it.
            let directoryURL = URL(fileURLWithPath: path, isDirectory: true)
                .resolvingSymlinksInPath()
            let urls = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            )
            return try urls.map { url in
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let symlink = values.isSymbolicLink == true
                // Match the remote daemon: a link to a directory remains expandable.
                var isDirectory = values.isDirectory == true
                if symlink {
                    var targetIsDirectory: ObjCBool = false
                    isDirectory = FileManager.default.fileExists(
                        atPath: url.path, isDirectory: &targetIsDirectory
                    ) && targetIsDirectory.boolValue
                }
                return Entry(
                    name: url.lastPathComponent, is_dir: isDirectory, is_symlink: symlink
                )
            }
        }
        let value = try request("read_directory", path: path)
        return try JSONDecoder().decode(
            [Entry].self, from: JSONSerialization.data(withJSONObject: value["entries"] ?? []))
    }
    func git(_ arguments: [String], in path: String) -> (
        status: Int32, stdout: String, stderr: String
    ) {
        if isLocal {
            do { try checkActive() }
            catch { return (-1, "", error.localizedDescription) }
            return HostService.$current.withValue(nil) {
                GitStatusModel.runGit(arguments, in: path)
            }
        }
        do {
            let response = try request("git", path: path, fields: ["arguments": arguments])
            guard let output = response["output"] as? [String: Any] else {
                throw DaemonWire.Failure("Invalid Git response")
            }
            // tty7's host protocol represents original stdout/stderr as bytes.
            func bytes(_ name: String) -> String {
                if let data = output[name] as? [UInt8] { return String(decoding: data, as: UTF8.self) }
                return (output[name] as? String).flatMap { Data(base64Encoded: $0) }.map {
                    String(decoding: $0, as: UTF8.self)
                } ?? ""
            }
            return (Int32(output["status"] as? Int ?? -1), bytes("stdout"), bytes("stderr"))
        } catch { return (-1, "", error.localizedDescription) }
    }
    final class Watch: @unchecked Sendable {
        private let lock = NSLock()
        private var wire: DaemonWire?
        private var localSources: [DispatchSourceFileSystemObject] = []
        private var cancelled = false
        func cancel() {
            lock.lock()
            cancelled = true
            let wire = wire
            let sources = localSources
            localSources = []
            lock.unlock()
            wire?.close()
            sources.forEach { $0.cancel() }
        }
        func attach(_ wire: DaemonWire) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled {
                wire.close()
                return false
            }
            self.wire = wire
            return true
        }
        func attachLocal(_ sources: [DispatchSourceFileSystemObject]) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            localSources = sources
            return true
        }
    }
    func watch(_ paths: [String], token: Watch, changed: @escaping @Sendable () -> Void) throws {
        if isLocal {
            try checkActive()
            // A directory descriptor reports changes to its immediate entries.
            // FileTreeModel supplies the root plus each expanded directory.
            let sources = paths.compactMap { path -> DispatchSourceFileSystemObject? in
                let descriptor = Darwin.open(path, O_EVTONLY)
                guard descriptor >= 0 else { return nil }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .attrib],
                    queue: .global(qos: .utility)
                )
                source.setEventHandler(handler: changed)
                source.setCancelHandler { Darwin.close(descriptor) }
                return source
            }
            guard token.attachLocal(sources) else {
                // Dispatch sources must be resumed even when cancellation
                // races their registration.
                sources.forEach { $0.resume(); $0.cancel() }
                return
            }
            sources.forEach { $0.resume() }
            return
        }
        let (id, wire, host) = try open()
        defer { finish(id, wire) }
        guard token.attach(wire) else { return }
        wire.setReadTimeout(0)
        try wire.request(["op": "watch", "paths": paths.map { ["host": host, "path": $0] }])
        while true {
            let event = try wire.event()
            if event["event"] as? String == "changed" { changed() }
        }
    }
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func checkActive() throws {
        lock.lock()
        let allowed = active
        lock.unlock()
        guard allowed else { throw DaemonWire.Failure("Host was disconnected") }
    }

    private func localRequest(
        _ action: String, path: String, fields: [String: Any]
    ) throws -> [String: Any] {
        try checkActive()
        let url = URL(fileURLWithPath: path)
        let fileManager = FileManager.default
        switch action {
        case "read":
            let file = try read(path)
            return ["data": file.data.base64EncodedString(), "sha256": file.sha256]
        case "read_directory":
            let entries = try directory(path).map {
                ["name": $0.name, "is_dir": $0.is_dir, "is_symlink": $0.is_symlink] as [String: Any]
            }
            return ["entries": entries]
        case "git":
            guard let arguments = fields["arguments"] as? [String] else {
                throw DaemonWire.Failure("Invalid Git arguments")
            }
            let result = git(arguments, in: path)
            return ["output": [
                "status": Int(result.status),
                "stdout": Data(result.stdout.utf8).base64EncodedString(),
                "stderr": Data(result.stderr.utf8).base64EncodedString(),
            ]]
        case "repository":
            let result = git(["rev-parse", "--show-toplevel"], in: path)
            let root = result.status == 0
                ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : path
            return ["path": ["host": hostID.uuidString, "path": root]]
        case "create_file":
            // An existence check followed by createFile can overwrite a file
            // another process creates in between. O_EXCL keeps new-file
            // creation atomic like the daemon's create_new operation.
            let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL, 0o666)
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            Darwin.close(descriptor)
            return [:]
        case "create_directory":
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
            return [:]
        case "rename":
            guard let destination = fields["destination"] as? String,
                  destination.hasPrefix("/") else {
                throw DaemonWire.Failure("Invalid destination")
            }
            try fileManager.moveItem(atPath: path, toPath: destination)
            return [:]
        case "remove":
            try fileManager.removeItem(at: url)
            return [:]
        default:
            throw DaemonWire.Failure("Unsupported local file operation: \(action)")
        }
    }
}
