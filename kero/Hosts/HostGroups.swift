import AppKit
import Combine

nonisolated struct SSHHostDefinition: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var destination: String
    /// Nil deliberately means “let OpenSSH choose” from `~/.ssh/config` or
    /// its built-in default. Zero was the old on-disk representation of nil.
    var port: UInt16?
    var directory: String?

    init(
        id: UUID = UUID(), name: String, destination: String, port: UInt16? = nil,
        directory: String? = nil
    ) {
        self.id = id
        self.name = name
        self.destination = destination
        self.port = port
        self.directory = directory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, destination, port, directory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        destination = try container.decode(String.self, forKey: .destination)
        let savedPort = try container.decodeIfPresent(UInt16.self, forKey: .port)
        port = savedPort == 0 ? nil : savedPort
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
    }
}

/// Expansion is shared by all windows. Every connection attempt has an epoch;
/// a completion from before collapse cannot revive a subscription.
@MainActor
final class HostGroups: ObservableObject {
    static let shared = HostGroups()
    nonisolated static let localID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    @Published private(set) var sshHosts: [SSHHostDefinition] = []
    @Published private(set) var revision = 0
    @Published private(set) var persistenceErrorMessage: String?
    private var expanded: Set<UUID>
    private var services: [UUID: HostService] = [:]
    private var daemonInstances: [UUID: UUID] = [:]
    private var wakeObserver: NSObjectProtocol?
    func observedDaemon(_ identity: DaemonSessionIdentity, on hostID: UUID) {
        guard daemonInstances[hostID] != identity.instance else { return }
        daemonInstances[hostID] = identity.instance
        // A watch attached to a former daemon cannot recover by itself.
        // Reissue file/Git capabilities when the terminal discovers a new one.
        invalidateService(hostID)
        connectionChanged()
    }
    private func resumeAfterWake() {
        guard !TerminalManager.automationManagers.isEmpty else { return }
        if expanded.contains(Self.localID) { invalidateService(Self.localID) }
        for host in sshHosts where expanded.contains(host.id) {
            for manager in TerminalManager.automationManagers {
                for project in manager.projects where project.hostID == host.id {
                    project.sessions.forEach { $0.detach() }
                }
            }
            connection(host.id)?.reconnectAfterWake()
        }
        connectionChanged()
    }
    func service(_ id: UUID) -> HostService {
        if let value = services[id] { return value }
        let socket: String?
        if !isExpanded(id) {
            socket = nil
        } else if id == Self.localID {
            let namespace =
                (Bundle.main.object(forInfoDictionaryKey: "KeroDaemonStateNamespace") as? String)
                ?? (Bundle.main.bundleIdentifier?.hasPrefix("sh.kero.dev") == true ? "kero-dev" : "kero")
            socket =
                FileManager.default.homeDirectoryForCurrentUser.path
                + "/.local/state/\(namespace)/daemon-v1/daemon.sock"
        } else {
            socket = connections[id]?.socketPath
        }
        let value = HostService(hostID: id, socketPath: socket)
        services[id] = value
        return value
    }
    func invalidateService(_ id: UUID) { services.removeValue(forKey: id)?.invalidate() }
    private var connections: [UUID: SSHHostConnection] = [:]
    func definition(_ id: UUID) -> SSHHostDefinition? { sshHosts.first { $0.id == id } }
    func connection(_ id: UUID) -> SSHHostConnection? {
        if let value = connections[id] { return value }
        guard let definition = definition(id) else { return nil }
        let value = SSHHostConnection(hostID: definition.id)
        connections[id] = value
        return value
    }
    func detachAll() {
        services.values.forEach { $0.invalidate() }
        services = [:]
        connections.values.forEach { $0.close() }
    }
    func startExpandedConnections() {
        guard !TerminalManager.automationManagers.isEmpty else { return }
        for host in sshHosts where expanded.contains(host.id) {
            connection(host.id)?.connect(notifyFailure: false)
        }
    }
    func connectionChanged() {
        revision += 1
        NotificationCenter.default.post(name: .keroHostGroupsChanged, object: nil)
    }
    private init() {
        if let values = UserDefaults.standard.stringArray(forKey: "expandedHostGroups") {
            expanded = Set(values.compactMap(UUID.init(uuidString:)))
        } else {
            expanded = [Self.localID]
        }
        if FileManager.default.fileExists(atPath: HostStore.storageURL.path) {
            do {
                sshHosts = try HostStore.load()
            } catch {
                persistenceErrorMessage = String(
                    localized: "Could not read the saved SSH hosts: \(error.localizedDescription)"
                )
                if let data = UserDefaults.standard.data(forKey: "sshHostGroups"),
                    let hosts = try? JSONDecoder().decode([SSHHostDefinition].self, from: data)
                {
                    sshHosts = hosts
                }
            }
        } else if let data = UserDefaults.standard.data(forKey: "sshHostGroups"),
            let hosts = try? JSONDecoder().decode([SSHHostDefinition].self, from: data)
        {
            sshHosts = hosts
            // Remove the legacy defaults blob only after the JSON write is
            // durable; a failed migration can then retry on the next launch.
            if (try? HostStore.save(hosts)) != nil {
                UserDefaults.standard.removeObject(forKey: "sshHostGroups")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resumeAfterWake() }
        }
    }
    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
    func setExpanded(_ id: UUID, _ value: Bool, userInitiated: Bool = false) {
        guard expanded.contains(id) != value else { return }
        invalidateService(id)
        if value { expanded.insert(id) } else { expanded.remove(id) }
        UserDefaults.standard.set(expanded.map(\.uuidString), forKey: "expandedHostGroups")
        revision += 1
        if let connection = connection(id) {
            value ? connection.connect(notifyFailure: userInitiated) : connection.close()
        }
        for manager in TerminalManager.automationManagers {
            for project in manager.projects where project.hostID == id {
                project.sessions.forEach { value ? $0.resume() : $0.detach() }
                project.objectWillChange.send()
            }
            manager.objectWillChange.send()
        }
        if !value { RemoteControlService.shared.collapseHost(id) }
        NotificationCenter.default.post(name: .keroHostGroupsChanged, object: id)
    }
    @discardableResult func add(_ host: SSHHostDefinition) -> Bool {
        sshHosts.append(host)
        let saved = persist()
        revision += 1
        return saved
    }

    func clearPersistenceError() {
        guard persistenceErrorMessage != nil else { return }
        persistenceErrorMessage = nil
        connectionChanged()
    }

    /// Connections read the current definition by host ID. Nevertheless,
    /// changing the destination requires a fresh transport and auth attempt;
    /// merely renaming a host or changing its default directory must not
    /// disturb a live connection.
    @discardableResult func update(_ host: SSHHostDefinition) -> Bool {
        guard let index = sshHosts.firstIndex(where: { $0.id == host.id }) else { return false }
        let old = sshHosts[index]
        let requiresRebind =
            old.destination != host.destination || old.port != host.port
        let wasExpanded = isExpanded(host.id)

        if requiresRebind {
            invalidateService(host.id)
            if let connection = connections.removeValue(forKey: host.id) { connection.close() }
            sshHosts[index] = host
            let saved = persist()
            for manager in TerminalManager.automationManagers {
                for project in manager.projects where project.hostID == host.id {
                    project.sessions.forEach { $0.detach() }
                    project.objectWillChange.send()
                }
                manager.objectWillChange.send()
            }
            if wasExpanded {
                connection(host.id)?.connect(notifyFailure: true)
                for manager in TerminalManager.automationManagers {
                    for project in manager.projects where project.hostID == host.id {
                        project.sessions.forEach { $0.resume() }
                    }
                }
            }
            revision += 1
            NotificationCenter.default.post(name: .keroHostGroupsChanged, object: host.id)
            return saved
        }

        sshHosts[index] = host
        let saved = persist()
        revision += 1
        NotificationCenter.default.post(name: .keroHostGroupsChanged, object: host.id)
        return saved
    }

    @discardableResult func duplicate(_ id: UUID) -> Bool {
        guard let host = definition(id) else { return false }
        var copy = host
        copy.id = UUID()
        copy.name = host.name + " (copy)"
        return add(copy)
    }

    @discardableResult func remove(id: UUID) -> Bool {
        guard sshHosts.contains(where: { $0.id == id }) else { return false }
        setExpanded(id, false)
        for manager in TerminalManager.automationManagers { manager.removeHostProjects(id) }
        sshHosts.removeAll { $0.id == id }
        connections.removeValue(forKey: id)
        let saved = persist()
        revision += 1
        NotificationCenter.default.post(name: .keroHostGroupsChanged, object: id)
        return saved
    }

    /// Moves a host relative to another host row. A downward drag lands after
    /// the target; an upward drag lands before it, matching outline-view drop
    /// expectations without exposing a flat index in the UI layer.
    @discardableResult func moveHost(_ id: UUID, relativeTo targetID: UUID) -> Bool {
        guard id != targetID,
            let from = sshHosts.firstIndex(where: { $0.id == id }),
            let to = sshHosts.firstIndex(where: { $0.id == targetID })
        else { return false }
        let host = sshHosts.remove(at: from)
        sshHosts.insert(host, at: to)
        let saved = persist()
        revision += 1
        return saved
    }

    func connectHost(_ id: UUID, userInitiated: Bool = true) {
        guard isExpanded(id) else {
            setExpanded(id, true, userInitiated: userInitiated)
            return
        }
        guard let connection = connection(id) else { return }
        switch connection.state {
        case .disconnected, .failed:
            connection.retry(notifyFailure: userInitiated)
        default:
            break
        }
    }

    private func persist() -> Bool {
        do {
            try HostStore.save(sshHosts)
            if persistenceErrorMessage != nil {
                clearPersistenceError()
            } else {
                persistenceErrorMessage = nil
            }
            return true
        } catch {
            persistenceErrorMessage = String(
                localized:
                    "Could not save SSH hosts. The list is still available in this window, but the change was not written to disk."
            )
            connectionChanged()
            return false
        }
    }
    func showDisconnectedClose() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Connect before ending this session")
        alert.informativeText = String(
            localized:
                "Expand the host group to connect, then close the terminal. Its shell is still running on the host."
        )
        alert.addButton(withTitle: String(localized: "OK"))
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}
extension Notification.Name {
    static let keroHostGroupsChanged = Notification.Name("sh.kero.hostGroupsChanged")
}
