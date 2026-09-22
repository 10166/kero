import AppKit
import Combine

struct DaemonWire {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
struct DaemonSessionIdentity { let instance: UUID }
final class HostService {
    let socketPath: String?
    init(hostID: UUID, socketPath: String?) { self.socketPath = socketPath }
    func invalidate() {}
}
enum RemoteKeychain {
    static func data(for account: String) -> Data? { nil }
    static func set(_ data: Data, for account: String) throws {}
}
@MainActor final class TerminalManager: ObservableObject {
    static var automationManagers: [TerminalManager] = []
    var projects: [Project] = []
    func removeHostProjects(_ hostID: UUID) {
        projects.removeAll { $0.hostID == hostID }
    }
}

@MainActor final class Project: ObservableObject {
    let hostID: UUID
    var sessions: [Session]
    init(hostID: UUID) {
        self.hostID = hostID
        sessions = [Session()]
    }
}

@MainActor final class Session {
    private(set) var isDetached = true
    func detach() { isDetached = true }
    func resume() { isDetached = false }
}
@MainActor final class RemoteControlService {
    static let shared = RemoteControlService()
    func collapseHost(_ id: UUID) {}
}

@main struct SSHConnectionChecks {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        let priorExpanded = defaults.object(forKey: "expandedHostGroups")
        defer { defaults.set(priorExpanded, forKey: "expandedHostGroups") }
        defaults.removeObject(forKey: "expandedHostGroups")
        HostStore.storageOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-ssh-connection-\(UUID().uuidString).json")

        let host = SSHHostDefinition(name: "missing helper", destination: "fixture.invalid")
        precondition(HostGroups.shared.add(host))
        HostGroups.shared.setExpanded(host.id, true, userInitiated: false)
        guard let connection = HostGroups.shared.connection(host.id) else {
            preconditionFailure("connection was not created")
        }

        for _ in 0..<100 where connection.state != .failed("Bundled SSH daemon assets are missing.") {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(
            connection.state == .failed("Bundled SSH daemon assets are missing."),
            "expected the structured missing-helper failure, got \(connection.state)")
        precondition(connection.lastFailure?.stage == .startingGateway)
        precondition(connection.lastFailure?.message == "Bundled SSH daemon assets are missing.")
        precondition(connection.lastFailure?.diagnostics == nil)

        connection.retry(notifyFailure: false)
        for _ in 0..<100 where connection.state != .failed("Bundled SSH daemon assets are missing.") {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(connection.lastFailure?.stage == .startingGateway)
        precondition(
            connection.state == .failed("Bundled SSH daemon assets are missing."),
            "explicit retry must replace the failed attempt, got \(connection.state)")

        HostGroups.shared.setExpanded(host.id, false)
        precondition(connection.state == .disconnected)
        precondition(connection.lastFailure != nil, "collapse must preserve the last failure")

        func gatewayScript(_ body: String) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kero-gateway-\(UUID().uuidString)")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        // The GUI must prefer the gateway's structured failure over process exit.
        do {
            SSHHostConnection.gatewayExecutableOverride = try gatewayScript(
                #"read line; printf '%s\n' '{"event":"failed","message":"Connection refused"}'"#)
        } catch {
            preconditionFailure("could not create structured gateway: \(error)")
        }
        let structuredHost = SSHHostDefinition(name: "structured failure", destination: "fixture.invalid")
        precondition(HostGroups.shared.add(structuredHost))
        HostGroups.shared.setExpanded(structuredHost.id, true, userInitiated: false)
        guard let structuredConnection = HostGroups.shared.connection(structuredHost.id) else {
            preconditionFailure("structured connection was not created")
        }
        for _ in 0..<100 where structuredConnection.state != .failed("Connection refused") {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(
            structuredConnection.state == .failed("Connection refused"),
            "structured stdout failure was not consumed, got \(structuredConnection.state)")
        precondition(structuredConnection.lastFailure?.stage == .remote)

        // A silent gateway exit is also a failure. This guards against a missed
        // readability callback leaving the sidebar on its progress indicator.
        do {
            SSHHostConnection.gatewayExecutableOverride = try gatewayScript("read line")
        } catch {
            preconditionFailure("could not create silent gateway: \(error)")
        }
        let silentHost = SSHHostDefinition(name: "silent gateway", destination: "fixture.invalid")
        precondition(HostGroups.shared.add(silentHost))
        HostGroups.shared.setExpanded(silentHost.id, true, userInitiated: false)
        guard let silentConnection = HostGroups.shared.connection(silentHost.id) else {
            preconditionFailure("silent connection was not created")
        }
        for _ in 0..<100 where !silentConnection.state.isFailed {
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(
            silentConnection.state.isFailed,
            "silent gateway exit must become failed, got \(silentConnection.state)")
        precondition(
            silentConnection.lastFailure?.stage == .startingGateway
                || silentConnection.lastFailure?.stage == .closed,
            "expected gateway-exit stage, got \(String(describing: silentConnection.lastFailure))")
        SSHHostConnection.gatewayExecutableOverride = nil

        print("PASS: SSH connection failure record, explicit retry, and collapse retention")
    }
}
