import Foundation

@MainActor
extension TerminalManager {
    static func remoteTopology(revision: UInt64) -> RemoteTopology {
        RemoteTopology(
            revision: revision,
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            projects: automationManagers.flatMap { manager in
                manager.projects.map(RemoteProjectDescriptor.init)
            }
        )
    }

    static func remoteSession(id: UUID) -> TerminalSession? {
        automationManagers.lazy
            .flatMap(\.projects)
            .lazy
            .flatMap(\.sessions)
            .first { $0.id == id }
    }
}

@MainActor
private extension RemoteProjectDescriptor {
    init(_ project: Project) {
        id = project.id
        name = project.name
        tabs = project.tabs.map(RemoteTabDescriptor.init)
        selectedTabID = project.selectedTabID
    }
}

@MainActor
private extension RemoteTabDescriptor {
    init(_ tab: PaneTab) {
        id = tab.id
        title = tab.displayTitle ?? String(localized: "Untitled")
        layout = RemotePaneNode(tab.layout)
        focusedPaneID = tab.focusedPaneID
    }
}

@MainActor
private extension RemotePaneNode {
    init(_ node: PaneNode) {
        switch node {
        case .pane(let pane):
            self = .pane(RemotePaneDescriptor(pane))
        case .split(let split):
            self = .split(
                id: split.id,
                axis: split.axis,
                fraction: Double(split.fraction),
                first: RemotePaneNode(split.first),
                second: RemotePaneNode(split.second)
            )
        }
    }
}

@MainActor
private extension RemotePaneDescriptor {
    init(_ pane: Pane) {
        id = pane.id
        title = pane.content.title
        switch pane.content {
        case .session(let session):
            kind = .terminal
            sessionID = session.id
        case .file:
            kind = .file
            sessionID = nil
        case .browser:
            kind = .browser
            sessionID = nil
        case .diff:
            kind = .diff
            sessionID = nil
        }
    }
}
