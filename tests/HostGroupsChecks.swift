import AppKit
import Combine

struct DaemonSessionIdentity { let instance: UUID }
struct DaemonWire { struct Failure: Error { init(_ message: String) {} } }
final class HostService {
    let socketPath: String?
    private(set) var invalidated = false
    init(hostID: UUID, socketPath: String?) { self.socketPath = socketPath }
    func invalidate() { invalidated = true }
}
@MainActor final class Session {
    var detachCount = 0
    var resumeCount = 0
    func detach() { detachCount += 1 }
    func resume() { resumeCount += 1 }
}
@MainActor final class Project: ObservableObject {
    let hostID: UUID
    var sessions = [Session()]
    init(_ id: UUID) { hostID = id }
}
@MainActor final class TerminalManager: ObservableObject {
    static var automationManagers: [TerminalManager] = []
    var projects: [Project]
    init(_ ids: [UUID]) { projects = ids.map(Project.init) }
    func removeHostProjects(_ hostID: UUID) {
        projects.removeAll { $0.hostID == hostID }
    }
}
@MainActor final class SSHHostConnection {
    enum State: Equatable {
        case disconnected, connecting, installing, connected, reconnecting
        case failed(String)
    }
    struct FailureRecord: Equatable {
        let message: String
    }

    var state = State.disconnected
    var lastFailure: FailureRecord?
    var socketPath: String? = "/test-only"
    var connects = 0
    var closes = 0
    var wakes = 0
    var retries = 0
    let hostID: UUID
    init(hostID: UUID) { self.hostID = hostID }
    func connect(notifyFailure: Bool) { connects += 1; state = .connecting }
    func retry(notifyFailure: Bool) { retries += 1; connect(notifyFailure: notifyFailure) }
    func close() { closes += 1; state = .disconnected }
    func reconnectAfterWake() { wakes += 1 }
}
@MainActor final class RemoteControlService {
    static let shared = RemoteControlService()
    var collapsed: [UUID] = []
    func collapseHost(_ id: UUID) { collapsed.append(id) }
}
private struct LegacyHost: Encodable {
    var id: UUID
    var name: String
    var destination: String
    var port: UInt16
    var directory: String
}

@main struct HostGroupsChecks {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        let keys = ["expandedHostGroups", "sshHostGroups"]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }

        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-host-checks-\(UUID().uuidString).json")
        HostStore.storageOverride = store
        let legacy = LegacyHost(
            id: UUID(), name: "legacy", destination: "legacy.invalid", port: 0,
            directory: "/tmp")
        defaults.set(try! JSONEncoder().encode([legacy]), forKey: "sshHostGroups")

        let groups = HostGroups.shared
        precondition(groups.sshHosts.map(\.id) == [legacy.id])
        precondition(groups.sshHosts[0].port == nil, "legacy port zero must decode as nil")
        precondition(groups.sshHosts[0].directory == "/tmp")
        precondition(FileManager.default.fileExists(atPath: store.path))
        precondition(defaults.object(forKey: "sshHostGroups") == nil)
        precondition(try! HostStore.load().map(\.id) == [legacy.id])

        groups.remove(id: legacy.id)
        precondition(try! HostStore.load().isEmpty)

        let active = SSHHostDefinition(name: "active", destination: "fixture.invalid", port: 22)
        let collapsed = SSHHostDefinition(name: "collapsed", destination: "fixture.invalid")
        precondition(groups.add(active) && groups.add(collapsed))
        precondition(try! HostStore.load().map(\.id) == [active.id, collapsed.id])
        HostStore.storageOverride = URL(fileURLWithPath: "/dev/null/kero-hosts")
        let unwritable = SSHHostDefinition(name: "unwritable", destination: "x.invalid")
        precondition(!groups.add(unwritable))
        precondition(groups.persistenceErrorMessage != nil)
        precondition(groups.sshHosts.map(\.id).contains(unwritable.id))
        HostStore.storageOverride = store
        groups.clearPersistenceError()
        precondition(groups.remove(id: unwritable.id))
        let ids = [HostGroups.localID, active.id, collapsed.id]
        TerminalManager.automationManagers = [TerminalManager(ids), TerminalManager(ids)]
        groups.setExpanded(active.id, true)
        let a = groups.connection(active.id)!
        let b = groups.connection(collapsed.id)!
        precondition(a.connects == 1 && b.connects == 0)

        let local = groups.service(HostGroups.localID)
        let old = groups.service(active.id)
        let identity = DaemonSessionIdentity(instance: UUID())
        groups.observedDaemon(identity, on: active.id)
        precondition(old.invalidated)
        let current = groups.service(active.id)
        groups.observedDaemon(identity, on: active.id)
        precondition(!current.invalidated, "same instance invalidated an active operation")

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(a.wakes == 1 && b.wakes == 0)
        precondition(local.invalidated)
        for manager in TerminalManager.automationManagers {
            precondition(manager.projects[1].sessions[0].detachCount == 1)
            precondition(manager.projects[2].sessions[0].detachCount == 0)
        }

        var renamed = active
        renamed.name = "renamed"
        renamed.directory = "/srv"
        precondition(groups.update(renamed))
        precondition(a.closes == 0, "name/directory-only edit must not rebind a connection")
        precondition(groups.connection(active.id) === a)
        precondition(try! HostStore.load().first?.name == "renamed")

        var movedHost = active
        movedHost.name = "renamed"
        movedHost.directory = "/srv"
        movedHost.destination = "edited.invalid"
        movedHost.port = nil
        precondition(groups.update(movedHost))
        precondition(a.closes == 1, "destination edit must close the stale connection")
        let replacement = groups.connection(active.id)!
        precondition(replacement !== a && replacement.connects == 1)
        precondition(groups.definition(active.id)?.destination == "edited.invalid")
        precondition(groups.definition(active.id)?.port == nil)
        precondition(try! HostStore.load().first?.destination == "edited.invalid")

        groups.setExpanded(active.id, false)
        precondition(current.invalidated && replacement.closes == 1)
        precondition(groups.service(active.id).socketPath == nil)

        precondition(groups.duplicate(collapsed.id))
        precondition(groups.sshHosts.map(\.name) == ["renamed", "collapsed", "collapsed (copy)"])
        let copyID = groups.sshHosts[2].id
        groups.moveHost(copyID, relativeTo: active.id)
        precondition(groups.sshHosts.map(\.id) == [copyID, active.id, collapsed.id])
        precondition(try! HostStore.load().map(\.id) == groups.sshHosts.map(\.id))

        groups.remove(id: active.id)
        precondition(!groups.isExpanded(active.id) && groups.definition(active.id) == nil)
        for manager in TerminalManager.automationManagers {
            precondition(manager.projects.allSatisfy { $0.hostID != active.id })
        }
        precondition(try! !HostStore.load().contains(where: { $0.id == active.id }))

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(a.wakes == 1 && replacement.wakes == 0 && b.wakes == 0)
        precondition(RemoteControlService.shared.collapsed == [active.id])
        print(
            "PASS: real HostGroups model, hosts.json migration, CRUD/reorder, selective rebind, multi-window deletion, wake exclusion (mocked connections)"
        )
    }
}
