import AppKit
import SwiftUI

struct RemoteWorkspaceRepresentable: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var service = RemoteControlService.shared

    func makeNSView(context: Context) -> RemoteWorkspaceView {
        RemoteWorkspaceView(frame: .zero)
    }

    func updateNSView(_ view: RemoteWorkspaceView, context: Context) {
        guard let selection = manager.selectedRemoteProject,
              let host = service.hosts.first(where: { $0.id == selection.hostID }),
              let project = host.topology?.projects.first(where: {
                  $0.id == selection.projectID
              }) else {
            view.showUnavailable(String(localized: "Remote project is unavailable."))
            return
        }
        let tab = project.tabs.first(where: { $0.id == selection.selectedTabID })
            ?? project.tabs.first(where: { $0.id == project.selectedTabID })
            ?? project.tabs.first
        guard let tab else {
            view.showUnavailable(String(localized: "No open remote tabs"))
            return
        }
        view.show(tab: tab, hostID: host.id)
    }

    static func dismantleNSView(_ view: RemoteWorkspaceView, coordinator: ()) {
        view.detach()
    }
}

struct RemoteTabsHeaderRepresentable: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager
    @ObservedObject private var service = RemoteControlService.shared

    func makeNSView(context: Context) -> RemoteTabsHeaderView {
        let view = RemoteTabsHeaderView(frame: .zero)
        view.onSelect = { [weak manager] tabID in
            manager?.selectRemoteTab(tabID)
        }
        return view
    }

    func updateNSView(_ view: RemoteTabsHeaderView, context: Context) {
        view.onSelect = { [weak manager] tabID in manager?.selectRemoteTab(tabID) }
        guard let selection = manager.selectedRemoteProject,
              let host = service.hosts.first(where: { $0.id == selection.hostID }),
              let project = host.topology?.projects.first(where: {
                  $0.id == selection.projectID
              }) else {
            view.update(hostName: nil, tabs: [], selectedTabID: nil)
            return
        }
        let selectedTabID = project.tabs.contains { $0.id == selection.selectedTabID }
            ? selection.selectedTabID
            : (project.selectedTabID ?? project.tabs.first?.id)
        view.update(
            hostName: host.name,
            tabs: project.tabs,
            selectedTabID: selectedTabID
        )
    }
}

@MainActor
final class RemoteTabsHeaderView: NSView {
    var onSelect: ((UUID) -> Void)?

    private let stack = NSStackView()
    private var buttons: [UUID: NSButton] = [:]
    private var titles: [UUID: String] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        hostName: String?,
        tabs: [RemoteTabDescriptor],
        selectedTabID: UUID?
    ) {
        let desired = Set(tabs.map(\.id))
        let removed = buttons.filter { !desired.contains($0.key) }
        for (id, button) in removed {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
            buttons[id] = nil
            titles[id] = nil
        }
        for tab in tabs {
            let button: NSButton
            if let existing = buttons[tab.id] {
                button = existing
            } else {
                button = NSButton(title: "", target: self, action: #selector(selectTab(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
                button.bezelStyle = .recessed
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.imagePosition = .imageLeading
                button.image = NSImage(
                    systemSymbolName: "terminal",
                    accessibilityDescription: nil
                )
                button.lineBreakMode = .byTruncatingTail
                button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
                buttons[tab.id] = button
                stack.addArrangedSubview(button)
            }
            let title = hostName.map { "\($0) · \(tab.title)" } ?? tab.title
            if titles[tab.id] != title {
                button.title = title
                titles[tab.id] = title
            }
            button.state = tab.id == selectedTabID ? .on : .off
        }
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let id = UUID(uuidString: raw) else { return }
        onSelect?(id)
    }
}

@MainActor
final class RemoteWorkspaceView: NSView {
    private let layoutView = RemotePaneLayoutView(frame: .zero)
    private let message = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.background.cgColor
        layoutView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layoutView)
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.alignment = .center
        message.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        NSLayoutConstraint.activate([
            layoutView.leadingAnchor.constraint(equalTo: leadingAnchor),
            layoutView.trailingAnchor.constraint(equalTo: trailingAnchor),
            layoutView.topAnchor.constraint(equalTo: topAnchor),
            layoutView.bottomAnchor.constraint(equalTo: bottomAnchor),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])
        message.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(tab: RemoteTabDescriptor, hostID: UUID) {
        message.isHidden = true
        layoutView.isHidden = false
        layoutView.show(layout: tab.layout, hostID: hostID)
    }

    func showUnavailable(_ text: String) {
        layoutView.detach()
        layoutView.isHidden = true
        message.stringValue = text
        message.isHidden = false
    }

    func detach() {
        layoutView.detach()
    }
}

@MainActor
private final class RemotePaneLayoutView: NSView {
    private let gap: CGFloat = 10
    private var root: RemotePaneNode?
    private var hostID: UUID?
    private var leaves: [UUID: RemotePaneLeafView] = [:]

    override var isFlipped: Bool { true }

    func show(layout: RemotePaneNode, hostID: UUID) {
        let descriptors = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.id, $0) })
        if self.hostID != hostID {
            detach()
            self.hostID = hostID
        }
        let removed = leaves.filter { descriptors[$0.key] == nil }
        for (id, leaf) in removed {
            leaf.detach()
            leaf.removeFromSuperview()
            leaves[id] = nil
        }
        for descriptor in descriptors.values {
            if let leaf = leaves[descriptor.id], leaf.matches(descriptor) {
                leaf.update(descriptor)
                continue
            }
            if let old = leaves.removeValue(forKey: descriptor.id) {
                old.detach()
                old.removeFromSuperview()
            }
            let leaf = RemotePaneLeafView(descriptor: descriptor, hostID: hostID)
            leaves[descriptor.id] = leaf
            addSubview(leaf)
        }
        let showsChrome = descriptors.count > 1
        leaves.values.forEach { $0.showsChrome = showsChrome }
        root = layout
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let root else { return }
        let inset = root.panes.count > 1 ? gap : 0
        place(root, in: bounds.insetBy(dx: inset, dy: inset))
    }

    func detach() {
        leaves.values.forEach {
            $0.detach()
            $0.removeFromSuperview()
        }
        leaves = [:]
        root = nil
        hostID = nil
    }

    private func place(_ node: RemotePaneNode, in frame: CGRect) {
        switch node {
        case .pane(let descriptor):
            leaves[descriptor.id]?.frame = frame
        case let .split(_, axis, rawFraction, first, second):
            let fraction = CGFloat(min(max(rawFraction, 0.1), 0.9))
            switch axis {
            case .horizontal:
                let available = max(0, frame.width - gap)
                let firstWidth = available * fraction
                place(first, in: CGRect(
                    x: frame.minX, y: frame.minY,
                    width: firstWidth, height: frame.height
                ))
                place(second, in: CGRect(
                    x: frame.minX + firstWidth + gap, y: frame.minY,
                    width: available - firstWidth, height: frame.height
                ))
            case .vertical:
                let available = max(0, frame.height - gap)
                let firstHeight = available * fraction
                place(first, in: CGRect(
                    x: frame.minX, y: frame.minY,
                    width: frame.width, height: firstHeight
                ))
                place(second, in: CGRect(
                    x: frame.minX, y: frame.minY + firstHeight + gap,
                    width: frame.width, height: available - firstHeight
                ))
            }
        }
    }
}

@MainActor
private final class RemotePaneLeafView: NSView {
    private let paneID: UUID
    private let kind: RemotePaneDescriptor.Kind
    private let sessionID: UUID?
    private var surface: (any TerminalBackendSurface)?
    private var connection: RemoteTerminalConnection?
    private let header = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    var showsChrome = false {
        didSet {
            layer?.borderWidth = showsChrome ? 1 : 0
            needsLayout = true
        }
    }

    init(descriptor: RemotePaneDescriptor, hostID: UUID) {
        paneID = descriptor.id
        kind = descriptor.kind
        sessionID = descriptor.sessionID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 0
        layer?.borderColor = NSColor.separatorColor.cgColor

        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingMiddle
        addSubview(header)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        addSubview(status)
        update(descriptor)

        if descriptor.kind == .terminal, let sessionID {
            let viewport = RemoteResize(
                sessionID: sessionID,
                columns: 80,
                rows: 24,
                cellWidth: 8,
                cellHeight: 16
            )
            if let connection = RemoteControlService.shared.connection(
                hostID: hostID,
                sessionID: sessionID,
                viewport: viewport
            ) {
                self.connection = connection
                connection.onStateChange = { [weak self] state in self?.show(state: state) }
                let surface = AppSettings.shared.terminalBackend.makeRemoteSurface(
                    connection: connection
                )
                self.surface = surface
                surface.translatesAutoresizingMaskIntoConstraints = true
                surface.setSurfaceVisible(true)
                addSubview(surface, positioned: .below, relativeTo: header)
            } else {
                status.stringValue = String(localized: "Host is offline")
            }
        } else {
            status.stringValue = String(localized: "Available on the host only")
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let headerHeight: CGFloat = showsChrome ? 24 : 0
        header.isHidden = !showsChrome
        header.frame = CGRect(x: 9, y: 0, width: max(0, bounds.width - 18), height: headerHeight)
        surface?.frame = CGRect(
            x: 1, y: headerHeight,
            width: max(0, bounds.width - 2),
            height: max(0, bounds.height - headerHeight - 1)
        )
        status.frame = CGRect(
            x: 12, y: headerHeight,
            width: max(0, bounds.width - 24),
            height: max(0, bounds.height - headerHeight)
        )
    }

    func matches(_ descriptor: RemotePaneDescriptor) -> Bool {
        guard paneID == descriptor.id,
              kind == descriptor.kind,
              sessionID == descriptor.sessionID else { return false }
        guard kind == .terminal else { return true }
        guard let connection else { return false }
        switch connection.state {
        case .connecting, .connected, .failed:
            // A host rejection, including locally reclaiming control, is a
            // terminal result for this mounted pane. Recreating it on the next
            // topology refresh would immediately attach again and undo the
            // host's explicit decision. Network loss remains retryable below.
            return true
        case .disconnected:
            return false
        }
    }

    func update(_ descriptor: RemotePaneDescriptor) {
        header.stringValue = descriptor.title
        if kind != .terminal {
            let name: String
            switch kind {
            case .file: name = String(localized: "File")
            case .browser: name = String(localized: "Browser")
            case .diff: name = String(localized: "Diff")
            case .terminal: name = String(localized: "Terminal")
            }
            status.stringValue = "\(name): \(descriptor.title)\n\(String(localized: "Available on the host only"))"
        }
    }

    func detach() {
        connection?.onStateChange = nil
        surface?.setSurfaceVisible(false)
        surface?.detach()
        surface?.removeFromSuperview()
        surface = nil
        connection = nil
    }

    private func show(state: RemoteTerminalConnection.State) {
        switch state {
        case .connecting:
            status.stringValue = String(localized: "Connecting…")
            status.isHidden = false
        case .connected:
            status.isHidden = true
        case .failed(let reason):
            status.stringValue = reason
            status.isHidden = false
        case .disconnected:
            status.stringValue = String(localized: "Disconnected")
            status.isHidden = false
        }
    }
}

private extension RemotePaneNode {
    var panes: [RemotePaneDescriptor] {
        switch self {
        case .pane(let pane): [pane]
        case let .split(_, _, _, first, second): first.panes + second.panes
        }
    }
}
