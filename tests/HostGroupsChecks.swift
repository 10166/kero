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
    let sessions = [Session()]
    init(_ id: UUID) { hostID = id }
}
@MainActor final class TerminalManager: ObservableObject {
    static var automationManagers: [TerminalManager] = []
    let projects: [Project]
    init(_ ids: [UUID]) { projects = ids.map(Project.init) }
}
@MainActor final class SSHHostConnection {
    var socketPath: String? = "/test-only"
    var connects = 0
    var closes = 0
    var wakes = 0
    init(_ definition: SSHHostDefinition) {}
    func connect() { connects += 1 }
    func close() { closes += 1 }
    func reconnectAfterWake() { wakes += 1 }
}
@MainActor final class RemoteControlService {
    static let shared = RemoteControlService()
    var collapsed: [UUID] = []
    func collapseHost(_ id: UUID) { collapsed.append(id) }
}
@main struct HostGroupsChecks {
    @MainActor static func main() async {
        // This executable has its own preferences domain; preserve it as well.
        let defaults = UserDefaults.standard
        let keys = ["expandedHostGroups", "sshHostGroups"]
        let prior = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, prior) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.removeObject(forKey: key) }
        let groups = HostGroups.shared
        let active = SSHHostDefinition(name: "active", destination: "fixture.invalid")
        let collapsed = SSHHostDefinition(name: "collapsed", destination: "fixture.invalid")
        groups.add(active)
        groups.add(collapsed)
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
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(a.wakes == 1 && b.wakes == 0)
        precondition(local.invalidated)
        for manager in TerminalManager.automationManagers {
            precondition(manager.projects[1].sessions[0].detachCount == 1)
            precondition(manager.projects[2].sessions[0].detachCount == 0)
        }
        groups.setExpanded(active.id, false)
        precondition(current.invalidated && a.closes == 1)
        precondition(groups.service(active.id).socketPath == nil)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(100))
        precondition(a.wakes == 1 && b.wakes == 0, "wake reconnected a collapsed host")
        for manager in TerminalManager.automationManagers {
            precondition(manager.projects[1].sessions[0].detachCount == 2)
        }
        precondition(RemoteControlService.shared.collapsed == [active.id])
        print(
            "PASS: real HostGroups model, two windows, collapsed wake exclusion, instance-based capability invalidation (synthetic wake notification; mocked connections)"
        )
    }
}
