import AppKit
import Combine
import SwiftUI

/// SwiftUI is only the legacy window's mounting point. Rows, disclosure,
/// selection, menus, dragging, resizing and configuration are native AppKit.
struct HostSidebarRepresentable: NSViewRepresentable {
    let manager: TerminalManager
    let bottomBarHeight: CGFloat
    let openSettings: () -> Void
    func makeNSView(context: Context) -> HostSidebarView {
        HostSidebarView(manager: manager, bottomBarHeight: bottomBarHeight, openSettings: openSettings)
    }
    func updateNSView(_ view: HostSidebarView, context: Context) { view.reload() }
}

@MainActor
final class HostSidebarView: NSVisualEffectView, NSOutlineViewDataSource, NSOutlineViewDelegate,
    NSMenuDelegate
{
    private final class Row: NSObject {
        let id: UUID
        let hostID: UUID
        var title: String
        var kind: String
        var children: [Row] = []
        init(id: UUID, hostID: UUID, title: String, kind: String) {
            self.id = id
            self.hostID = hostID
            self.title = title
            self.kind = kind
        }
    }
    private weak var manager: TerminalManager?
    private let outline = NSOutlineView()
    private var roots: [Row] = []
    private var rows: [UUID: Row] = [:]
    private var observations = Set<AnyCancellable>()
    private var isReloading = false
    private var lastSnapshot = ""
    private let settings: () -> Void
    private let dragType = NSPasteboard.PasteboardType("sh.kero.project")
    private let hostDragType = NSPasteboard.PasteboardType("sh.kero.sshHost")
    private var scrollerObserver: NSObjectProtocol?
    private var reportedPersistenceErrorMessage: String?

    init(manager: TerminalManager, bottomBarHeight: CGFloat, openSettings: @escaping () -> Void) {
        self.manager = manager
        settings = openSettings
        super.init(frame: .zero)
        material = .sidebar
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        let header = SidebarDragRegion()
        let collapse = button("sidebar.left", "Toggle Left Sidebar (⌘B)", #selector(toggleSidebar))
        let footer = NSView()
        let add = button("plus", "New Project (⌘N)", #selector(newProject))
        let ssh = button(
            "network.badge.shield.half.filled",
            String(localized: "Add SSH Host…"), #selector(addSSHHost))
        let preferences = button("gearshape", "Settings (⌘,)", #selector(openPreferences))
        let feedback = button("exclamationmark.bubble", "Send Feedback", #selector(sendFeedback))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.scrollerStyle = .overlay
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hosts"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 29
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes([dragType, hostDragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel(String(localized: "Hosts and projects"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.verticalScroller = ThinOverlayScroller(frame: .zero)
        let resize = SidebarWidthHandle()
        for view in [header, scroll, footer, resize] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        header.addSubview(collapse)
        for view in [add, ssh, preferences, feedback] { footer.addSubview(view) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),
            collapse.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            collapse.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.heightAnchor.constraint(equalToConstant: bottomBarHeight),
            add.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            add.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            ssh.leadingAnchor.constraint(equalTo: add.trailingAnchor, constant: 4),
            ssh.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            preferences.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
            preferences.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            feedback.trailingAnchor.constraint(equalTo: preferences.leadingAnchor, constant: -4),
            feedback.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            resize.trailingAnchor.constraint(equalTo: trailingAnchor),
            resize.topAnchor.constraint(equalTo: topAnchor),
            resize.bottomAnchor.constraint(equalTo: bottomAnchor),
            resize.widthAnchor.constraint(equalToConstant: 5),
        ])
        for publisher in [
            manager.objectWillChange.eraseToAnyPublisher(),
            HostGroups.shared.objectWillChange.eraseToAnyPublisher(),
            RemoteControlService.shared.objectWillChange.eraseToAnyPublisher(),
        ] {
            publisher.debounce(for: .milliseconds(30), scheduler: RunLoop.main).sink { [weak self] in
                self?.reload()
            }.store(in: &observations)
        }
        scrollerObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil,
            queue: .main
        ) { [weak scroll] _ in
            MainActor.assumeIsolated {
                scroll?.scrollerStyle = .overlay
            }
        }
        NotificationCenter.default.publisher(
            for: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
        .receive(on: RunLoop.main)
        .sink { [weak scroll] _ in
            MainActor.assumeIsolated {
                (scroll?.verticalScroller as? ThinOverlayScroller)?.noteScrollActivity()
            }
        }
        .store(in: &observations)
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func button(_ symbol: String, _ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(),
            target: self, action: action)
        button.bezelStyle = .accessoryBarAction
        button.isBordered = false
        button.toolTip = title
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }
    fileprivate static func statusText(for state: SSHHostConnection.State?) -> String {
        switch state {
        case .disconnected, nil: return String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting…")
        case .reconnecting: return String(localized: "Reconnecting…")
        case .installing: return String(localized: "Installing…")
        case .connected: return String(localized: "Connected")
        case .failed: return String(localized: "Failed")
        }
    }
    func reload() {
        guard let manager else { return }
        let groups = HostGroups.shared
        let signature =
            manager.projects.map { "\($0.id):\($0.hostID):\($0.name)" }.joined(separator: "|")
            + "#\(manager.selectedProjectID?.uuidString ?? "")#\(manager.selectedRemoteProject?.projectID.uuidString ?? "")#\(groups.revision)"
            + "#\(AppSettings.shared.sidebarFontSize)"
            + RemoteControlService.shared.hosts.map {
                "\($0.id):\($0.name):\($0.topology?.projects.map { $0.name }.joined(separator:"|") ?? "")"
            }.joined(separator: "|")
        guard signature != lastSnapshot else { return }
        lastSnapshot = signature
        isReloading = true
        defer { isReloading = false }
        func row(_ id: UUID, _ host: UUID, _ title: String, _ kind: String) -> Row {
            let value = rows[id] ?? Row(id: id, hostID: host, title: title, kind: kind)
            value.title = title
            value.kind = kind
            rows[id] = value
            return value
        }
        HostGroups.shared.startExpandedConnections()
        let local = row(HostGroups.localID, HostGroups.localID, String(localized: "Local"), "local")
        roots = [local] + HostGroups.shared.sshHosts.map { row($0.id, $0.id, $0.name, "ssh") }
        for host in roots {
            host.children = manager.projects.filter { $0.hostID == host.id }.map {
                row($0.id, host.id, $0.name, "project")
            }
        }
        for host in RemoteControlService.shared.hosts {
            let node = row(host.id, host.id, host.name, "relay")
            node.children = (host.topology?.projects ?? []).map {
                row($0.id, host.id, $0.name, "relayProject")
            }
            roots.append(node)
        }
        let live = Set(roots.flatMap { [$0.id] + $0.children.map(\.id) })
        rows = rows.filter { live.contains($0.key) }
        outline.reloadData()
        for root in roots {
            if HostGroups.shared.isExpanded(root.id) { outline.expandItem(root) }
            else { outline.collapseItem(root) }
        }
        let selected = manager.selectedRemoteProject?.projectID ?? manager.selectedProjectID
        if let selected, let item = rows[selected] {
            let index = outline.row(forItem: item)
            if index >= 0 {
                outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        if let message = groups.persistenceErrorMessage,
            message != reportedPersistenceErrorMessage
        {
            reportedPersistenceErrorMessage = message
            Task { @MainActor [weak self] in self?.showPersistenceError(message) }
        } else if groups.persistenceErrorMessage == nil {
            reportedPersistenceErrorMessage = nil
        }
    }
    func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Row)?.children.count ?? roots.count
    }
    func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Row)?.children[index] ?? roots[index]
    }
    func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let row = item as? Row else { return false }
        return row.kind != "project" && row.kind != "relayProject"
    }
    func outlineView(_ view: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        let id = NSUserInterfaceItemIdentifier("host-row")
        let cell =
            (view.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = id
            let image = NSImageView()
            let text = NSTextField(labelWithString: "")
            let status = HostStatusIndicator()
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            status.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.addSubview(status)
            cell.imageView = image
            cell.textField = text
            text.lineBreakMode = .byTruncatingTail
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                text.trailingAnchor.constraint(equalTo: status.leadingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                status.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                status.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                status.widthAnchor.constraint(equalToConstant: 12),
                status.heightAnchor.constraint(equalToConstant: 12),
            ])
        }
        cell.textField?.font = .systemFont(ofSize: AppSettings.shared.sidebarFontSize)
        cell.textField?.stringValue = row.title
        let symbol =
            row.kind == "local"
            ? "laptopcomputer"
            : row.kind == "ssh" ? "network" : row.kind == "relay" ? "desktopcomputer" : "folder"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let status = cell.subviews.compactMap { $0 as? HostStatusIndicator }.first
        if row.kind == "ssh" {
            let connection = HostGroups.shared.connection(row.id)
            let state = HostGroups.shared.isExpanded(row.id) ? connection?.state : .disconnected
            status?.configure(state: state, failure: connection?.lastFailure)
            var tooltip = row.title + "\n" + Self.statusText(for: state)
            if case .failed = state, let failure = connection?.lastFailure {
                tooltip += "\n"
                + failure.message.split(separator: "\n", omittingEmptySubsequences: true)
                    .prefix(1).joined()
            }
            cell.toolTip = tooltip
        } else {
            status?.configure(state: nil, failure: nil)
            cell.toolTip = row.title
        }
        return cell
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading, let row = outline.item(atRow: outline.selectedRow) as? Row else { return }
        if row.kind == "project" {
            manager?.selectedProjectID = row.id
        } else if row.kind == "relayProject" {
            manager?.selectRemoteProject(hostID: row.hostID, projectID: row.id)
        }
    }
    func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, false) }
    private func expansion(_ notification: Notification, _ expanded: Bool) {
        guard !isReloading, let row = notification.userInfo?["NSObject"] as? Row else { return }
        HostGroups.shared.setExpanded(row.id, expanded, userInitiated: true)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = outline.item(atRow: outline.clickedRow) as? Row else { return }
        if row.kind == "local" {
            let item = NSMenuItem(
                title: String(localized: "New Project"), action: #selector(newHostProject),
                keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.isEnabled = HostGroups.shared.isExpanded(row.id)
            menu.addItem(item)
            return
        }
        if row.kind == "project" {
            for (title, action) in [
                (String(localized: "Rename…"), #selector(renameProject)),
                (String(localized: "Set Project Directory…"), #selector(setDirectory)),
                (String(localized: "Close Project"), #selector(closeProject)),
            ] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = row.id
                menu.addItem(item)
            }
            return
        }
        guard row.kind == "ssh" else { return }

        func menuItem(
            _ title: String, _ action: Selector, enabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.isEnabled = enabled
            return item
        }

        menu.addItem(
            menuItem(
                String(localized: "New Project"), #selector(newHostProject),
                enabled: HostGroups.shared.isExpanded(row.id)))
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                HostGroups.shared.isExpanded(row.id)
                    ? String(localized: "Disconnect") : String(localized: "Connect"),
                #selector(toggleHostConnection)))
        if case .failed = HostGroups.shared.connection(row.id)?.state {
            menu.addItem(menuItem(String(localized: "Retry"), #selector(retryHostConnection)))
        }
        menu.addItem(.separator())
        menu.addItem(menuItem(String(localized: "Edit…"), #selector(editSSHHost)))
        menu.addItem(menuItem(String(localized: "Duplicate"), #selector(duplicateSSHHost)))
        menu.addItem(menuItem(String(localized: "Delete…"), #selector(deleteSSHHost)))
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                String(localized: "Show Connection Details…"), #selector(showConnectionDetails)))
    }
    @objc private func renameProject(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let project = manager?.projects.first(where: { $0.id == id })
        else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Project")
        let text = NSTextField(string: project.name)
        text.frame = NSRect(x: 0, y: 0, width: 260, height: 26)
        alert.accessoryView = text
        alert.addButton(withTitle: String(localized: "Rename"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                project.customName = Project.normalizedCustomName(text.stringValue)
            }
        }
    }
    @objc private func setDirectory(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let project = manager?.projects.first(where: { $0.id == id }), let window
        else { return }
        if project.hostID != HostGroups.localID {
            let alert = NSAlert()
            alert.messageText = "Remote Project Directory"
            let field = NSTextField(
                string: project.customDirectory ?? project.selectedSession?.currentDirectoryPath ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
            alert.accessoryView = field
            alert.addButton(withTitle: "Set Directory")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn, field.stringValue.hasPrefix("/") {
                    project.customDirectory = field.stringValue
                }
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK { project.customDirectory = panel.url?.path }
        }
    }
    @objc private func closeProject(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID,
            let project = manager?.projects.first(where: { $0.id == id })
        {
            manager?.close(project)
        }
    }
    @objc private func newHostProject(_ sender: NSMenuItem) {
        guard let hostID = sender.representedObject as? UUID, HostGroups.shared.isExpanded(hostID)
        else { return }
        manager?.newProject(hostID: hostID)
    }
    @objc private func toggleHostConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        HostGroups.shared.setExpanded(id, !HostGroups.shared.isExpanded(id), userInitiated: true)
    }
    @objc private func retryHostConnection(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        HostGroups.shared.connectHost(id, userInitiated: true)
    }
    @objc private func editSSHHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SSHHostConfigurationSheet.present(on: window, edit: id)
    }
    @objc private func duplicateSSHHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        reportSaveResult(HostGroups.shared.duplicate(id))
    }
    @objc private func deleteSSHHost(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
            let host = HostGroups.shared.definition(id)
        else { return }
        let projects = TerminalManager.automationManagers.reduce(0) { count, manager in
            count + manager.projects.filter { $0.hostID == id }.count
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete \(host.name)?")
        alert.informativeText = projects == 0
            ? String(
                localized:
                    "The saved host configuration is removed and its Kero projects are closed. The remote daemon, shells, and tasks keep running; Kero does not uninstall the daemon.")
            : String(
                localized:
                    "\(projects) project(s) on this host are closed across all Kero windows. The remote daemon, shells, and tasks keep running; Kero does not uninstall the daemon.")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard let window else {
            if alert.runModal() == .alertFirstButtonReturn {
                reportSaveResult(HostGroups.shared.remove(id: id))
            }
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.reportSaveResult(HostGroups.shared.remove(id: id))
        }
    }
    @objc private func showConnectionDetails(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        SSHConnectionDetailsSheet.present(hostID: id, on: window)
    }
    private func reportSaveResult(_ saved: Bool) {
        guard !saved, let message = HostGroups.shared.persistenceErrorMessage else { return }
        showPersistenceError(message)
    }
    private func showPersistenceError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "SSH hosts were not saved")
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
    @objc private func toggleSidebar() { manager?.toggleLeftSidebar() }
    @objc private func newProject() {
        let row = outline.item(atRow: outline.selectedRow) as? Row
        let hostID =
            row.flatMap { ["local", "ssh", "project"].contains($0.kind) ? $0.hostID : nil } ?? manager?
            .selectedProject?.hostID ?? HostGroups.localID
        guard HostGroups.shared.isExpanded(hostID) else {
            HostGroups.shared.showDisconnectedClose()
            return
        }
        manager?.newProject(hostID: hostID)
    }
    @objc private func openPreferences() { settings() }
    @objc private func sendFeedback() {
        NSWorkspace.shared.open(URL(string: "https://github.com/egoist/kero/issues/new")!)
    }
    @objc private func addSSHHost() { SSHHostConfigurationSheet.present(on: window) }
    func outlineView(_ view: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let row = item as? Row else { return nil }
        let value = NSPasteboardItem()
        if row.kind == "project" {
            value.setString(row.id.uuidString, forType: dragType)
        } else if row.kind == "ssh" {
            value.setString(row.id.uuidString, forType: hostDragType)
        } else {
            return nil
        }
        return value
    }
    func outlineView(
        _ view: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        if let id = info.draggingPasteboard.string(forType: hostDragType).flatMap(UUID.init(uuidString:)),
            let source = rows[id], let target = item as? Row
        {
            return source.kind == "ssh" && target.kind == "ssh" && source.id != target.id
                ? .move : []
        }
        guard let target = item as? Row, target.kind == "project",
            let id = info.draggingPasteboard.string(forType: dragType).flatMap(UUID.init(uuidString:)),
            let source = rows[id], source.hostID == target.hostID
        else { return [] }
        return .move
    }
    func outlineView(
        _ view: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        if let id = info.draggingPasteboard.string(forType: hostDragType).flatMap(UUID.init(uuidString:)),
            let target = item as? Row
        {
            let saved = HostGroups.shared.moveHost(id, relativeTo: target.id)
            reportSaveResult(saved)
            return true
        }
        guard let row = item as? Row,
            let id = info.draggingPasteboard.string(forType: dragType).flatMap(UUID.init(uuidString:))
        else { return false }
        manager?.moveProject(id, to: row.id)
        return true
    }
}

@MainActor
private final class HostStatusIndicator: NSView {
    private let image = NSImageView()
    private let progress = NSProgressIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image.translatesAutoresizingMaskIntoConstraints = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(image)
        addSubview(progress)
        NSLayoutConstraint.activate([
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 10),
            image.heightAnchor.constraint(equalToConstant: 10),
            progress.centerXAnchor.constraint(equalTo: centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(state: SSHHostConnection.State?, failure: SSHHostConnection.FailureRecord?) {
        let isWorking: Bool
        let symbol: String?
        let color: NSColor?
        let label: String
        switch state {
        case .connecting:
            isWorking = true
            symbol = nil
            color = nil
            label = String(localized: "Connecting")
        case .reconnecting, .installing:
            isWorking = true
            symbol = nil
            color = nil
            label = HostSidebarView.statusText(for: state)
        case .connected:
            isWorking = false
            symbol = "circle.fill"
            color = .systemGreen
            label = String(localized: "Connected")
        case .failed:
            isWorking = false
            symbol = "exclamationmark.triangle.fill"
            color = .systemRed
            label = String(localized: "Failed")
        case .disconnected, nil:
            isWorking = false
            symbol = "circle.fill"
            color = .quaternaryLabelColor
            label = String(localized: "Disconnected")
        }
        image.isHidden = symbol == nil
        image.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        image.contentTintColor = color
        image.toolTip = failure.map { label + "\n" + $0.message } ?? label
        progress.isHidden = !isWorking
        if isWorking {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
        setAccessibilityLabel(label)
    }
}

@MainActor
private final class ThinOverlayScroller: NSScroller {
    private var fadeTask: Task<Void, Never>?

    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        alphaValue = 0
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        alphaValue = 0
    }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        8
    }

    override func draw(_ dirtyRect: NSRect) {
        guard alphaValue > 0.01, bounds.height > 8 else { return }

        let track = bounds.insetBy(dx: 2, dy: 2)
        var knob = track
        knob.size.height = max(24, track.height * knobProportion)
        knob.origin.y = track.maxY - knob.height - doubleValue * (track.height - knob.height)
        NSColor.labelColor.withAlphaComponent(0.42).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 2, yRadius: 2).fill()
    }

    override func mouseDown(with event: NSEvent) {
        noteScrollActivity()
        guard let window, bounds.height > 8 else { return }
        let startY = convert(event.locationInWindow, from: nil).y
        let currentKnob = overlayKnobRect()
        let grabOffset = startY - currentKnob.midY
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            let scrollable = bounds.height - currentKnob.height
            if scrollable > 0 {
                doubleValue = min(1, max(0, (point.y - grabOffset - currentKnob.height / 2) / scrollable))
            } else {
                doubleValue = 0
            }
            scrollEnclosingScrollView()
            if next.type == .leftMouseUp { break }
        }
        noteScrollActivity()
    }

    private func overlayKnobRect() -> NSRect {
        let track = bounds.insetBy(dx: 2, dy: 2)
        var knob = track
        knob.size.height = max(24, track.height * knobProportion)
        knob.origin.y = track.maxY - knob.height - doubleValue * (track.height - knob.height)
        return knob
    }

    private func scrollEnclosingScrollView() {
        guard let scroll = enclosingScrollView, let documentView = scroll.documentView else { return }
        let visibleHeight = scroll.documentVisibleRect.height
        let scrollable = max(0, documentView.bounds.height - visibleHeight)
        documentView.scroll(NSPoint(x: 0, y: doubleValue * scrollable))
        needsDisplay = true
    }

    func noteScrollActivity() {
        fadeTask?.cancel()
        alphaValue = 1
        needsDisplay = true
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fadeTask = Task { @MainActor [weak self] in
            if !reducesMotion {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = reducesMotion ? 0 : 0.22
                self.animator().alphaValue = 0
            }
        }
    }
}

private final class SidebarDragRegion: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
private final class SidebarWidthHandle: NSView {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            UserDefaults.standard.set(220.0, forKey: "leftSidebarWidth")
            return
        }
        let start = event.locationInWindow.x
        let initial = UserDefaults.standard.double(forKey: "leftSidebarWidth")
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            UserDefaults.standard.set(
                min(400, max(160, (initial > 0 ? initial : 220) + next.locationInWindow.x - start)),
                forKey: "leftSidebarWidth")
        }
    }
}
