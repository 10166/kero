import AppKit

@MainActor
final class SSHHostConnection {
    enum State: Equatable {
        case disconnected, connecting, installing, connected, reconnecting
        case failed(String)
    }
    private(set) var state = State.disconnected
    private(set) var home = ""
    private(set) var shell = "/bin/sh"
    private(set) var socketPath: String?
    private var process: Process?
    private var input: FileHandle?
    private var epoch = 0
    private var directory: URL?
    private var pending: [CheckedContinuation<String, Error>] = []
    private var prompt: NSAlert?
    private var configTask: Task<Void, Never>?
    private var triedSecrets = Set<String>()
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var wasConnected = false
    let definition: SSHHostDefinition
    init(_ definition: SSHHostDefinition) { self.definition = definition }
    func connect() {
        guard HostGroups.shared.isExpanded(definition.id), state == .disconnected else { return }
        epoch += 1
        let epoch = epoch
        setState(wasConnected ? .reconnecting : .connecting)
        let definition = definition
        configTask = Task { [weak self] in
            do {
                let resolver = Task.detached {
                    try JSONSerialization.data(
                        withJSONObject: SSHConfiguration.resolve(
                            destination: definition.destination,
                            port: definition.port == 0 ? nil : definition.port))
                }
                let specData = try await withTaskCancellationHandler {
                    try await resolver.value
                } onCancel: {
                    resolver.cancel()
                }
                guard let self, self.epoch == epoch, HostGroups.shared.isExpanded(definition.id) else {
                    return
                }
                try start(specData: specData, epoch: epoch)
            } catch { self?.fail(error.localizedDescription, epoch: epoch) }
        }
    }
    func endpoint() async throws -> String {
        guard HostGroups.shared.isExpanded(definition.id) else {
            throw DaemonWire.Failure("Host group is collapsed")
        }
        if state == .connected, let socketPath { return socketPath }
        if case .failed(let message) = state { throw DaemonWire.Failure(message) }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    private func start(specData: Data, epoch: Int) throws {
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "kero-daemon"),
            let resources = Bundle.main.resourceURL
        else { throw DaemonWire.Failure("Bundled SSH daemon assets are missing") }
        let directory = URL(
            fileURLWithPath: "/tmp/kero-gateway-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.directory = directory
        let socket = directory.appendingPathComponent("ssh.sock").path
        let spec = try JSONSerialization.jsonObject(with: specData)
        let namespace =
            (Bundle.main.object(forInfoDictionaryKey: "KeroRemoteDaemonStateNamespace") as? String)
            ?? (Bundle.main.bundleIdentifier?.hasPrefix("sh.kero.dev") == true ? "kero-dev" : "kero")
        let config: [String: Any] = [
            "spec": spec, "assets": resources.appendingPathComponent("daemon").path, "socket": socket,
            "namespace": namespace,
        ]
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = helper
        process.arguments = ["--ssh-gateway"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let reader = GatewayLineReader { [weak self] data in
            Task { @MainActor in self?.receive(data, epoch: epoch) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.read(data) }
        }
        process.terminationHandler = { [weak self] _ in
            // Let stdout drain the structured failure even when exit arrives first.
            Task { @MainActor in
                guard let self, self.epoch == epoch else { return }
                if case .failed = self.state { return }
                self.fail("SSH connection closed", epoch: epoch)
            }
        }
        try process.run()
        self.process = process
        input = stdin.fileHandleForWriting
        var data = try JSONSerialization.data(withJSONObject: config)
        data.append(10)
        try input?.write(contentsOf: data)
    }
    private func receive(_ data: Data, epoch: Int) {
        guard self.epoch == epoch, HostGroups.shared.isExpanded(definition.id),
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        switch value["event"] as? String {
        case "installing": setState(.installing)
        case "ready":
            home = value["home"] as? String ?? ""
            shell = value["shell"] as? String ?? "/bin/sh"
            socketPath = value["socket"] as? String
            guard let socketPath else { return }
            wasConnected = true
            failures = 0
            HostGroups.shared.invalidateService(definition.id)
            setState(.connected)
            let waiting = pending
            pending = []
            waiting.forEach { $0.resume(returning: socketPath) }
            for manager in TerminalManager.automationManagers {
                for project in manager.projects where project.hostID == definition.id {
                    project.sessions.forEach { $0.resume() }
                }
            }
        case "failed": fail(value["message"] as? String ?? "SSH failed", epoch: epoch)
        case "auth":
            if let id = value["request_id"] as? UInt64, let challenge = value["prompt"] as? [String: Any] {
                authenticate(id: id, challenge: challenge, epoch: epoch)
            }
        default: break
        }
    }
    private func setState(_ state: State) {
        self.state = state
        HostGroups.shared.connectionChanged()
    }
    private func fail(_ message: String, epoch: Int) {
        guard self.epoch == epoch else { return }
        HostGroups.shared.invalidateService(definition.id)
        socketPath = nil
        setState(.failed(message))
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume(throwing: DaemonWire.Failure(message)) }
        // Authentication/configuration failures require an explicit retry.
        // Only a previously live connection retries transient link loss.
        guard wasConnected, HostGroups.shared.isExpanded(definition.id), retryTask == nil else {
            return
        }
        failures += 1
        let delay = min(30, 1 << min(failures, 5))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.epoch == epoch,
                HostGroups.shared.isExpanded(self.definition.id)
            else { return }
            self.close()
            self.wasConnected = true
            self.connect()
        }
    }
    func reconnectAfterWake() {
        let connectedBefore = wasConnected
        close()
        wasConnected = connectedBefore
        connect()
    }
    func close() {
        HostGroups.shared.invalidateService(definition.id)
        epoch += 1
        retryTask?.cancel()
        retryTask = nil
        configTask?.cancel()
        configTask = nil
        wasConnected = false
        if let prompt, let parent = prompt.window.sheetParent {
            parent.endSheet(prompt.window, returnCode: .abort)
        }
        prompt = nil
        try? input?.close()
        input = nil
        socketPath = nil
        let process = process
        self.process = nil
        let directory = directory
        self.directory = nil
        Task {
            try? await Task.sleep(for: .seconds(2))
            if process?.isRunning == true { process?.terminate() }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume(throwing: DaemonWire.Failure("Host group disconnected")) }
        setState(.disconnected)
    }
    private func answer(_ id: UInt64, _ response: Any, epoch: Int) {
        guard self.epoch == epoch, HostGroups.shared.isExpanded(definition.id) else { return }
        guard
            var data = try? JSONSerialization.data(withJSONObject: [
                "request_id": id, "response": response,
            ])
        else { return }
        data.append(10)
        try? input?.write(contentsOf: data)
    }
    private func authenticate(id: UInt64, challenge: [String: Any], epoch: Int) {
        guard let kind = challenge.keys.first, let details = challenge[kind] as? [String: Any] else {
            return
        }
        if kind == "Banner" { return }
        let alert = NSAlert()
        prompt = alert
        if kind == "HostKeyUnknown" || kind == "HostKeyChanged" {
            alert.messageText =
                kind == "HostKeyChanged"
                ? String(localized: "SSH host key changed") : String(localized: "Trust this SSH host?")
            alert.informativeText =
                "\(details["host"] as? String ?? definition.destination)\n\(details["algorithm"] as? String ?? "")\n\(details["fingerprint_sha256"] as? String ?? "")"
            if kind == "HostKeyChanged" {
                alert.informativeText +=
                    "\n"
                    + String(
                        localized:
                            "Verify the changed key and update your known_hosts file before connecting.")
            } else {
                alert.addButton(withTitle: String(localized: "Trust and Save"))
            }
            alert.addButton(withTitle: String(localized: "Cancel"))
            present(alert) { [weak self] response in
                self?.answer(
                    id,
                    [
                        "HostKeyDecision": [
                            "accept": kind != "HostKeyChanged" && response == .alertFirstButtonReturn,
                            "remember": true,
                        ]
                    ], epoch: epoch)
            }
            return
        }
        let account =
            "ssh-\(definition.id.uuidString)-\(kind)-\(details["key_path"] as? String ?? "password")"
        if kind != "KeyboardInteractive", !triedSecrets.contains(account),
            let cached = RemoteKeychain.data(for: account),
            let secret = String(data: cached, encoding: .utf8)
        {
            triedSecrets.insert(account)
            answer(id, ["Secret": secret], epoch: epoch)
            return
        }
        alert.messageText =
            kind == "KeyPassphrase"
            ? String(localized: "SSH Key Passphrase") : String(localized: "SSH Authentication")
        alert.informativeText =
            details["instructions"] as? String ?? details["key_path"] as? String ?? definition.destination
        let prompts =
            (details["prompts"] as? [[String: Any]]) ?? [
                ["text": String(localized: "Password"), "echo": false]
            ]
        let fields: [NSTextField] = prompts.map {
            ($0["echo"] as? Bool) == true ? NSTextField(string: "") : NSSecureTextField(string: "")
        }
        let grid = NSGridView(
            views: zip(prompts, fields).map {
                [NSTextField(labelWithString: $0.0["text"] as? String ?? ""), $0.1]
            })
        grid.column(at: 1).width = 230
        let remember = NSButton(
            checkboxWithTitle: String(localized: "Remember in Keychain"), target: nil, action: nil)
        let stack = NSStackView(views: [grid, remember])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: CGFloat(prompts.count * 32 + 32))
        alert.accessoryView = stack
        alert.addButton(withTitle: String(localized: "Connect"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        present(alert) { [weak self] response in
            guard let self, self.epoch == epoch else { return }
            guard response == .alertFirstButtonReturn else {
                self.answer(id, "Cancelled", epoch: epoch)
                return
            }
            let secrets = fields.map(\.stringValue)
            if remember.state == .on, kind != "KeyboardInteractive", let secret = secrets.first {
                try? RemoteKeychain.set(Data(secret.utf8), for: account)
            }
            if kind == "KeyboardInteractive" {
                self.answer(id, ["Secrets": secrets], epoch: epoch)
            } else {
                self.answer(id, ["Secret": secrets.first ?? ""], epoch: epoch)
            }
        }
    }
    private func present(
        _ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
nonisolated private final class GatewayLineReader: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let receive: @Sendable (Data) -> Void
    init(_ receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
    func read(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard buffer.count + data.count <= 1024 * 1024 else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            receive(line)
        }
    }
}
