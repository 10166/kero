import AppKit

@MainActor
final class SSHHostConnection {
    /// Check executables substitute a tiny gateway for the bundled daemon. This
    /// keeps stdout/termination behavior testable without opening a network
    /// connection.
    nonisolated(unsafe) static var gatewayExecutableOverride: URL?
    enum State: Equatable {
        case disconnected, connecting, installing, connected, reconnecting
        case failed(String)

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }
    enum FailureStage: String {
        case resolvingConfiguration = "resolving SSH configuration"
        case startingGateway = "starting the SSH gateway"
        case remote = "connecting to the remote host"
        case closed = "connection closed"
    }

    struct FailureRecord: Equatable {
        let occurredAt: Date
        let stage: FailureStage
        let message: String
        let diagnostics: String?
    }

    private(set) var state = State.disconnected
    private(set) var home = ""
    private(set) var shell = "/bin/sh"
    private(set) var socketPath: String?
    private(set) var lastFailure: FailureRecord?
    private var process: Process?
    private var input: FileHandle?
    private var epoch = 0
    private var directory: URL?
    private var pending: [CheckedContinuation<String, Error>] = []
    private var prompt: NSAlert?
    private var configTask: Task<Void, Never>?
    private var processWatchdog: Task<Void, Never>?
    private var triedSecrets = Set<String>()
    private var retryTask: Task<Void, Never>?
    private var failures = 0
    private var wasConnected = false
    private var notifyNextFailure = false
    private var stderrBuffer: StandardErrorBuffer?
    let hostID: UUID
    init(hostID: UUID) { self.hostID = hostID }

    func connect(notifyFailure: Bool) {
        guard HostGroups.shared.isExpanded(hostID), state == .disconnected else { return }
        guard let definition = HostGroups.shared.definition(hostID) else {
            recordFailure(
                "The saved SSH host configuration is missing.", stage: .resolvingConfiguration,
                structured: true)
            return
        }
        epoch += 1
        let epoch = epoch
        notifyNextFailure = notifyFailure
        triedSecrets.removeAll()
        setState(wasConnected ? .reconnecting : .connecting)
        configTask = Task { [weak self] in
            do {
                // OpenSSH config parsing intentionally blocks on a child process.
                // Running that on a detached Swift task can starve the
                // cooperative pool when other daemon transports are blocked in
                // socket reads; GCD owns this blocking work instead.
                let specData = try await resolveSpecData(
                    destination: definition.destination, port: definition.port)
                guard let self, self.epoch == epoch, HostGroups.shared.isExpanded(definition.id) else {
                    return
                }
                do { try self.start(specData: specData, epoch: epoch) }
                catch {
                    self.fail(
                        error.localizedDescription, epoch: epoch, stage: .startingGateway,
                        structured: true)
                }
            } catch {
                self?.fail(
                    error.localizedDescription, epoch: epoch, stage: .resolvingConfiguration,
                    structured: true)
            }
        }
    }
    func endpoint() async throws -> String {
        guard HostGroups.shared.isExpanded(hostID) else {
            throw DaemonWire.Failure("Host group is collapsed")
        }
        if state == .connected, let socketPath { return socketPath }
        if case .failed(let message) = state { throw DaemonWire.Failure(message) }
        return try await withCheckedThrowingContinuation { pending.append($0) }
    }
    private func start(specData: Data, epoch: Int) throws {
        guard let helper = Self.gatewayExecutableOverride
            ?? Bundle.main.url(forAuxiliaryExecutable: "kero-daemon"),
            let resources = Bundle.main.resourceURL
        else { throw DaemonWire.Failure("Bundled SSH daemon assets are missing.") }
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
        let stderr = Pipe()
        process.executableURL = helper
        process.arguments = ["--ssh-gateway"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let diagnostics = StandardErrorBuffer()
        stderrBuffer = diagnostics
        let reader = GatewayLineReader { [weak self] data in
            Task { @MainActor [weak self] in self?.receive(data, epoch: epoch) }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.read(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnostics.append(data)
            }
        }
        process.terminationHandler = { [weak self] _ in
            // Let stdout drain the structured failure even when exit arrives first.
            // Also give stderr a short drain window; it is shown only as a
            // technical tail when the gateway could not produce a reason.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.epoch == epoch else { return }
                if case .failed = self.state { return }
                self.fail(
                    "SSH connection closed", epoch: epoch, stage: .closed, structured: false,
                    diagnostics: diagnostics.tail())
            }
        }
        try process.run()
        self.process = process
        // A gateway can exit before stdout's readability handler has drained
        // the structured failure. Process exit is itself a terminal result, so
        // an initial attempt must never remain stuck in “connecting”.
        let startedProcess = process
        processWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.epoch == epoch, self.process === startedProcess,
                !startedProcess.isRunning
            else { return }
            if case .failed = self.state { return }
            self.fail(
                String(localized: "The SSH gateway exited before connecting."),
                epoch: epoch, stage: .startingGateway, structured: false,
                diagnostics: diagnostics.tail())
        }
        input = stdin.fileHandleForWriting
        var data = try JSONSerialization.data(withJSONObject: config)
        data.append(10)
        try input?.write(contentsOf: data)
    }
    private func receive(_ data: Data, epoch: Int) {
        guard self.epoch == epoch, HostGroups.shared.isExpanded(hostID),
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
            lastFailure = nil
            notifyNextFailure = false
            HostGroups.shared.invalidateService(hostID)
            setState(.connected)
            let waiting = pending
            pending = []
            waiting.forEach { $0.resume(returning: socketPath) }
            for manager in TerminalManager.automationManagers {
                for project in manager.projects where project.hostID == hostID {
                    project.sessions.forEach { $0.resume() }
                }
            }
        case "failed":
            fail(
                value["message"] as? String ?? "SSH failed", epoch: epoch, stage: .remote,
                structured: true)
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
    private func fail(
        _ message: String, epoch: Int, stage: FailureStage, structured: Bool,
        diagnostics: String? = nil
    ) {
        guard self.epoch == epoch else { return }
        HostGroups.shared.invalidateService(hostID)
        processWatchdog?.cancel()
        processWatchdog = nil
        dismissPrompt()
        socketPath = nil
        setState(.failed(message))
        recordFailure(message, stage: stage, structured: structured, diagnostics: diagnostics)
        let waiting = pending
        pending = []
        waiting.forEach { $0.resume(throwing: DaemonWire.Failure(message)) }
        // Authentication/configuration failures require an explicit retry.
        // Only a previously live connection retries transient link loss.
        guard wasConnected, HostGroups.shared.isExpanded(hostID), retryTask == nil else {
            return
        }
        failures += 1
        let delay = min(30, 1 << min(failures, 5))
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.epoch == epoch,
                HostGroups.shared.isExpanded(self.hostID)
            else { return }
            self.close()
            self.wasConnected = true
            self.connect(notifyFailure: false)
        }
    }
    private func recordFailure(
        _ message: String, stage: FailureStage, structured: Bool, diagnostics: String? = nil
    ) {
        lastFailure = FailureRecord(
            occurredAt: Date(), stage: stage, message: message,
            diagnostics: structured ? nil : diagnostics)
        if notifyNextFailure {
            notifyNextFailure = false
            presentFailure(message, stage: stage)
        }
    }
    private func presentFailure(_ message: String, stage: FailureStage) {
        let alert = NSAlert()
        alert.messageText = String(localized: "SSH connection failed")
        alert.informativeText =
            "\(HostGroups.shared.definition(hostID)?.name ?? "SSH host")\n"
            + String(localized: "Stage: \(stage.rawValue)") + "\n" + message
        alert.addButton(withTitle: String(localized: "Show Details"))
        alert.addButton(withTitle: String(localized: "Close"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.showDetails()
            }
        }
    }
    func showDetails() {
        SSHConnectionDetailsSheet.present(hostID: hostID, on: NSApp.keyWindow)
    }
    func retry(notifyFailure: Bool) {
        guard HostGroups.shared.isExpanded(hostID) else { return }
        close()
        connect(notifyFailure: notifyFailure)
    }
    func reconnectAfterWake() {
        let connectedBefore = wasConnected
        close()
        wasConnected = connectedBefore
        connect(notifyFailure: false)
    }
    func close() {
        HostGroups.shared.invalidateService(hostID)
        epoch += 1
        retryTask?.cancel()
        retryTask = nil
        configTask?.cancel()
        configTask = nil
        processWatchdog?.cancel()
        processWatchdog = nil
        wasConnected = false
        if let prompt, let parent = prompt.window.sheetParent {
            parent.endSheet(prompt.window, returnCode: .abort)
        }
        prompt = nil
        stderrBuffer = nil
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
        guard self.epoch == epoch, HostGroups.shared.isExpanded(hostID) else { return }
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
        let definition = HostGroups.shared.definition(hostID)
        let alert = NSAlert()
        prompt = alert
        if kind == "HostKeyUnknown" || kind == "HostKeyChanged" {
            alert.messageText =
                kind == "HostKeyChanged"
                ? String(localized: "SSH host key changed") : String(localized: "Trust this SSH host?")
            alert.informativeText =
                "\(details["host"] as? String ?? definition?.destination ?? "")\n"
                + "\(details["algorithm"] as? String ?? "")\n"
                + (details["fingerprint_sha256"] as? String ?? "")
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
            "ssh-\(hostID.uuidString)-\(kind)-\(details["key_path"] as? String ?? "password")"
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
            details["instructions"] as? String ?? details["key_path"] as? String
            ?? definition?.destination ?? ""
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

private func resolveSpecData(destination: String, port: UInt16?) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try continuation.resume(returning: JSONSerialization.data(
                    withJSONObject: SSHConfiguration.resolve(
                        destination: destination, port: port)))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

@MainActor
private extension SSHHostConnection {
    func dismissPrompt() {
        if let prompt, let parent = prompt.window.sheetParent {
            parent.endSheet(prompt.window, returnCode: .abort)
        }
        prompt = nil
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

nonisolated private final class StandardErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit = 16 * 1024

    func append(_ input: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(input)
        if data.count > limit {
            data.removeFirst(data.count - limit)
        }
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
