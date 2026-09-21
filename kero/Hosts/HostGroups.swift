import AppKit
import Combine

nonisolated struct SSHHostDefinition: Codable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var destination: String
    var port: UInt16 = 22
    var directory: String = ""
}

/// Expansion is shared by all windows. Every connection attempt has an epoch;
/// a completion from before collapse cannot revive a subscription.
@MainActor
final class HostGroups: ObservableObject {
    static let shared = HostGroups()
    nonisolated static let localID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    @Published private(set) var sshHosts: [SSHHostDefinition] = []
    @Published private(set) var revision = 0
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
        let value = SSHHostConnection(definition)
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
        for host in sshHosts where expanded.contains(host.id) { connection(host.id)?.connect() }
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
        if let data = UserDefaults.standard.data(forKey: "sshHostGroups"),
            let hosts = try? JSONDecoder().decode([SSHHostDefinition].self, from: data)
        {
            sshHosts = hosts
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterWake() }
        }
    }
    func isExpanded(_ id: UUID) -> Bool { expanded.contains(id) }
    func setExpanded(_ id: UUID, _ value: Bool) {
        guard expanded.contains(id) != value else { return }
        invalidateService(id)
        if value { expanded.insert(id) } else { expanded.remove(id) }
        UserDefaults.standard.set(expanded.map(\.uuidString), forKey: "expandedHostGroups")
        revision += 1
        if let connection = connection(id) { value ? connection.connect() : connection.close() }
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
    func add(_ host: SSHHostDefinition) {
        sshHosts.append(host)
        UserDefaults.standard.set(try? JSONEncoder().encode(sshHosts), forKey: "sshHostGroups")
        revision += 1
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
