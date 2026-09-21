import AppKit

@MainActor
final class DaemonTerminalTransport: TerminalTransport {
    enum State: Equatable {
        case disconnected, connecting, connected, exited
        case failed(String)
    }
    let sessionID: UUID
    let hostID: UUID
    let ownsProtocolResponses = true
    var onData: ((Data, Bool) -> Void)?
    var onRelayOutput: ((Data) -> Void)?
    private var relayReady = false
    private var relaySize: RemoteResize?
    private var localSize: RemoteResize?
    private var bootstrap: CheckedContinuation<Data?, Never>?
    private var bootstrapID = UUID()
    private var termination: CheckedContinuation<Bool, Never>?
    var onStateChange: ((State) -> Void)?
    var onDirectory: ((String) -> Void)?
    private var colors: [String: [UInt8]] = [:]
    private var supportsColors = false
    private var cursorStyle: UInt8 = 1
    var onSession: ((DaemonSessionInfo, Bool) -> Void)?
    private(set) var identity: DaemonSessionIdentity?
    private(set) var state = State.disconnected { didSet { onStateChange?(state) } }
    private var wire: DaemonWire?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var retry: Task<Void, Never>?
    private var hasConnected = false
    private var size: DaemonSize?
    private var enabled = true
    private let launch: TerminalLaunch
    private let legacyHistory: String?
    private let directory: String

    init(
        sessionID: UUID, identity: DaemonSessionIdentity?, launch: TerminalLaunch, hostID: UUID,
        legacyHistory: String? = nil
    ) {
        self.sessionID = sessionID
        self.identity = identity
        self.launch = launch
        self.hostID = hostID
        self.legacyHistory = identity == nil ? legacyHistory : nil
        enabled = HostGroups.shared.isExpanded(hostID)
        let namespace =
            (Bundle.main.object(forInfoDictionaryKey: "KeroDaemonStateNamespace") as? String)
            ?? (Bundle.main.bundleIdentifier?.hasPrefix("sh.kero.dev") == true ? "kero-dev" : "kero")
        directory =
            FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state/\(namespace)/daemon-v1"
    }
    deinit {
        wire?.close()
        task?.cancel()
        retry?.cancel()
        bootstrap?.resume(returning: nil)
    }
    func resize(_ resize: RemoteResize) {
        localSize = resize
        guard relaySize == nil else { return }
        applyResize(resize)
    }
    func pasteImagePath(_ path: String) {
        guard state == .connected, let identity, let key = try? DaemonWire.object(identity) else { return }
        // Bracketed paste is encoded by the daemon's authoritative mode. This
        // lets image-aware agents recognize an attachment path as one paste.
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        wire?.enqueue(["op": "paste", "key": key, "text": quoted])
    }
    private func applyResize(_ resize: RemoteResize) {
        size = DaemonSize(resize)
        if let wire, state == .connected, let identity, let key = try? DaemonWire.object(identity),
            let size = try? DaemonWire.object(size!)
        {
            wire.enqueue(["op": "resize", "key": key, "size": size])
        } else if state == .disconnected && enabled {
            connect()
        }
    }
    func connect() {
        guard enabled, task == nil, let size else { return }
        generation += 1
        let generation = generation
        let directory = directory
        let identity = identity
        let launch = launch
        let sessionID = sessionID
        let hostID = hostID
        let legacyHistory = legacyHistory
        let helper = Bundle.main.url(forAuxiliaryExecutable: "kero-daemon")
        state = .connecting
        task = Task.detached { [weak self] in
            var wire: DaemonWire?
            do {
                guard let helper else { throw DaemonWire.Failure("The bundled Kero daemon is missing") }
                let socketPath: String
                let remoteHome: String
                let remoteShell: String
                if hostID == HostGroups.localID {
                    let ensure = Process()
                    ensure.executableURL = helper
                    ensure.arguments = ["--ensure", "--state-dir", directory]
                    ensure.standardInput = FileHandle.nullDevice
                    ensure.standardOutput = FileHandle.nullDevice
                    ensure.standardError = FileHandle.nullDevice
                    try ensure.run()
                    ensure.waitUntilExit()
                    guard ensure.terminationStatus == 0 else {
                        throw DaemonWire.Failure("Could not start the Kero daemon")
                    }
                    socketPath = directory + "/daemon.sock"
                    remoteHome = ""
                    remoteShell = ""
                } else {
                    guard let host = await HostGroups.shared.connection(hostID) else {
                        throw DaemonWire.Failure("SSH host configuration is missing")
                    }
                    socketPath = try await host.endpoint()
                    remoteHome = await host.home
                    remoteShell = await host.shell
                }
                guard !Task.isCancelled else { return }
                let connection = try DaemonWire(path: socketPath)
                wire = connection
                guard await self?.accept(connection, generation: generation) == true else {
                    connection.close()
                    return
                }
                try connection.request(["op": "hello", "version": 1])
                let hello = try connection.event()
                guard hello["version"] as? Int == 1,
                    (hello["capabilities"] as? [String])?.contains("terminal-state-v1") == true
                else { throw DaemonWire.Failure("Incompatible daemon; running sessions were preserved") }
                await self?.capabilities(hello["capabilities"] as? [String] ?? [], generation: generation)
                try connection.request(["op": "list"])
                let list = try connection.event()
                let infos = try JSONDecoder().decode(
                    [DaemonSessionInfo].self,
                    from: JSONSerialization.data(withJSONObject: list["sessions"] ?? []))
                var info = infos.first {
                    $0.key.session == sessionID && (identity == nil || $0.key == identity)
                }
                let restarted = identity != nil && info == nil
                if info == nil {
                    // A replacement daemon never receives the old direct task.
                    // Reopening after a machine restart always starts a shell.
                    let program =
                        hostID != HostGroups.localID
                        ? remoteShell
                        : restarted
                            ? (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") : launch.program
                    let arguments = hostID != HostGroups.localID || restarted ? ["-l"] : launch.arguments
                    let workingDirectory =
                        hostID != HostGroups.localID && launch.workingDirectory.isEmpty
                        ? remoteHome : launch.workingDirectory
                    try connection.request([
                        "op": "create",
                        "launch": [
                            "session": sessionID.uuidString, "program": program, "arguments": arguments,
                            "directory": workingDirectory,
                            "environment": hostID == HostGroups.localID
                                ? launch.environment
                                : [
                                    "TERM": "xterm-256color", "COLORTERM": "truecolor",
                                    "TERM_PROGRAM": "Kero",
                                ],
                            "colors": await self?.colors ?? [:], "cursor_style": await self?.cursorStyle ?? 1,
                            "history": legacyHistory.flatMap {
                                $0.utf8.count <= 4 * 1024 * 1024 ? Data($0.utf8).base64EncodedString() : nil
                            } as Any? ?? NSNull(),
                            "size": try DaemonWire.object(size),
                        ],
                    ])
                    let created = try connection.event()
                    info = try JSONDecoder().decode(
                        DaemonSessionInfo.self,
                        from: JSONSerialization.data(withJSONObject: created["session"] ?? [:]))
                }
                guard let info else { throw DaemonWire.Failure("Missing daemon session") }
                let attachSize = await self?.size ?? size
                try connection.request([
                    "op": "attach_sized", "key": try DaemonWire.object(info.key),
                    "size": try DaemonWire.object(attachSize),
                ])
                let attached = try connection.event()
                let attachedInfo = try JSONDecoder().decode(
                    DaemonSessionInfo.self,
                    from: JSONSerialization.data(withJSONObject: attached["session"] ?? [:]))
                await self?.attached(attachedInfo, restarted: restarted, generation: generation)
                var sequence = attachedInfo.sequence
                var checkpoint = Data()
                var ready = false
                while !Task.isCancelled {
                    let (kind, payload) = try connection.readFrame()
                    switch kind {
                    case 4:
                        guard payload.count >= 9 else { throw DaemonWire.Failure("Invalid checkpoint") }
                        let offset = payload.withUnsafeBytes {
                            $0.loadUnaligned(as: UInt64.self).littleEndian
                        }
                        guard offset == sequence, checkpoint.count + payload.count <= 32 * 1024 * 1024 else {
                            throw DaemonWire.Failure("Invalid checkpoint sequence or size")
                        }
                        checkpoint.append(payload.dropFirst(9))
                        if payload[8] == 1 {
                            if ready {
                                await self?.finishBootstrap(checkpoint)
                                checkpoint.removeAll()
                                continue
                            }
                            ready = true
                            guard
                                await self?.restore(
                                    checkpoint, size: attachedInfo.size, generation: generation)
                                    == true
                            else {
                                connection.close()
                                return
                            }
                            checkpoint.removeAll()
                            await self?.ready(generation: generation)
                        }
                    case 2:
                        guard ready, payload.count >= 8 else {
                            throw DaemonWire.Failure("Output arrived before checkpoint")
                        }
                        let offset = payload.withUnsafeBytes {
                            $0.loadUnaligned(as: UInt64.self).littleEndian
                        }
                        guard offset == sequence + UInt64(payload.count - 8) else {
                            throw DaemonWire.Failure("Terminal output sequence gap")
                        }
                        sequence = offset
                        await self?.deliver(
                            Data(payload.dropFirst(8)), bootstrap: false, generation: generation)
                    case 1:
                        let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                        if value?["event"] as? String == "directory", let path = value?["path"] as? String {
                            await self?.directoryChanged(path, generation: generation)
                        }
                        if value?["event"] as? String == "terminated" {
                            await self?.finishTermination(true)
                            return
                        }
                        if value?["event"] as? String == "exited" {
                            if await self?.isEndingSession == true { continue }
                            await self?.exited(generation: generation)
                            return
                        }
                        if value?["event"] as? String == "error" {
                            throw DaemonWire.Failure(value?["message"] as? String ?? "Daemon error")
                        }
                    default: throw DaemonWire.Failure("Unknown daemon frame")
                    }
                }
            } catch {
                await self?.failed(error.localizedDescription, generation: generation)
            }
            wire?.close()
        }
    }
    private func capabilities(_ values: [String], generation: Int) {
        guard self.generation == generation else { return }
        supportsColors = values.contains("terminal-colors-v1")
    }
    private func directoryChanged(_ path: String, generation: Int) {
        guard self.generation == generation else { return }
        onDirectory?(path)
    }
    func updateColors(_ colors: [String: [UInt8]], cursorStyle: UInt8) {
        self.colors = colors
        self.cursorStyle = cursorStyle
        sendColors()
    }
    private func sendColors() {
        guard supportsColors, state == .connected, let wire, let identity,
            let key = try? DaemonWire.object(identity)
        else { return }
        wire.enqueue(["op": "colors", "key": key, "colors": colors, "cursor_style": cursorStyle])
    }
    private func accept(_ wire: DaemonWire, generation: Int) -> Bool {
        guard self.generation == generation, enabled else { return false }
        self.wire = wire
        return true
    }
    private func attached(_ info: DaemonSessionInfo, restarted: Bool, generation: Int) {
        guard self.generation == generation else { return }
        identity = info.key
        HostGroups.shared.observedDaemon(info.key, on: hostID)
        onSession?(info, restarted)
    }
    private func deliver(_ data: Data, bootstrap: Bool, generation: Int) {
        guard self.generation == generation, enabled else { return }
        if relaySize == nil { onData?(data, bootstrap) }
        if relayReady, !bootstrap { onRelayOutput?(data) }
    }
    private func restore(_ data: Data, size: DaemonSize, generation: Int) -> Bool {
        guard self.generation == generation, enabled else { return false }
        guard self.size?.columns == size.columns, self.size?.rows == size.rows else {
            // A window can acquire its real backing scale while SSH is
            // connecting. Never replay a checkpoint into a differently sized
            // grid; reattach the same shell at the current size instead.
            wire?.close()
            wire = nil
            task = nil
            state = .disconnected
            connect()
            return false
        }
        onData?(data, true)
        return true
    }
    private func ready(generation: Int) {
        guard self.generation == generation else { return }
        hasConnected = true
        state = .connected
        sendColors()
        if let size, let wire, let identity, let key = try? DaemonWire.object(identity),
            let dimensions = try? DaemonWire.object(size)
        {
            wire.enqueue(["op": "resize", "key": key, "size": dimensions])
        }
    }
    private func failed(_ reason: String, generation: Int) {
        guard self.generation == generation else { return }
        finishBootstrap(nil)
        finishTermination(false)
        relayReady = false
        wire = nil
        task = nil
        state = .failed(reason)
        guard enabled, hasConnected else { return }
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.generation == generation, self.enabled,
                HostGroups.shared.isExpanded(self.hostID)
            else { return }
            self.state = .disconnected
            self.connect()
        }
    }
    private func exited(generation: Int) {
        guard self.generation == generation else { return }
        wire?.close()
        wire = nil
        task = nil
        state = .exited
    }
    func beginRelay(_ resize: RemoteResize, output: @escaping (Data) -> Void) {
        relayReady = false
        onRelayOutput = output
        applyResize(resize)
        relaySize = resize
    }
    func resizeRelay(_ resize: RemoteResize) {
        relaySize = resize
        applyResize(resize)
    }
    func endRelay() {
        finishBootstrap(nil)
        relayReady = false
        onRelayOutput = nil
        relaySize = nil
        if let localSize { size = DaemonSize(localSize) }
        generation += 1
        wire?.close()
        wire = nil
        task?.cancel()
        task = nil
        state = .disconnected
        if enabled { connect() }
    }
    func remoteBootstrap() async -> Data? {
        guard state == .connected, bootstrap == nil, let wire, let identity,
            let key = try? DaemonWire.object(identity)
        else { return nil }
        return await withCheckedContinuation { continuation in
            bootstrapID = UUID()
            let requestID = bootstrapID
            bootstrap = continuation
            wire.enqueue(["op": "checkpoint", "key": key])
            let generation = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                guard let self, self.generation == generation, self.bootstrapID == requestID else { return }
                self.finishBootstrap(nil)
            }
        }
    }
    private func finishBootstrap(_ data: Data?) {
        guard let continuation = bootstrap else { return }
        bootstrap = nil
        relayReady = data != nil
        continuation.resume(returning: data)
    }
    func send(_ data: Data) {
        guard state == .connected else { return }
        // Paste may arrive as one large AppKit insertion. Keep each protocol
        // input frame within the daemon limit without changing byte order.
        for offset in stride(from: 0, to: data.count, by: 64 * 1024) {
            wire?.enqueue(3, Data(data.dropFirst(offset).prefix(64 * 1024)))
        }
    }
    private var isEndingSession: Bool { termination != nil }
    func terminate() async -> Bool {
        guard state == .connected, termination == nil, let wire, let identity,
            let key = try? DaemonWire.object(identity)
        else { return false }
        retry?.cancel()
        return await withCheckedContinuation { continuation in
            termination = continuation
            wire.enqueue(["op": "terminate", "key": key])
            Task { [self] in
                try? await Task.sleep(for: .seconds(10))
                finishTermination(false)
            }
        }
    }
    private func finishTermination(_ success: Bool) {
        guard let continuation = termination else { return }
        termination = nil
        continuation.resume(returning: success)
        // A lost termination acknowledgement has an unknown outcome. Automatic
        // reconnect could create a replacement shell after the original exited.
        close()
        state =
            success
            ? .exited
            : .failed("Could not confirm that the session ended. Reconnect the host before trying again.")
    }
    func close() {
        finishTermination(false)
        finishBootstrap(nil)
        relayReady = false
        retry?.cancel()
        retry = nil
        enabled = false
        generation += 1
        wire?.close()
        wire = nil
        task?.cancel()
        task = nil
        state = .disconnected
    }
    func resume() {
        enabled = true
        if state != .connected {
            state = .disconnected
            connect()
        }
    }
}
