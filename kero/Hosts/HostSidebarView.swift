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
        let ssh = button("network.badge.shield.half.filled", "Add SSH Host…", #selector(addSSHHost))
        let preferences = button("gearshape", "Settings (⌘,)", #selector(openPreferences))
        let feedback = button("exclamationmark.bubble", "Send Feedback", #selector(sendFeedback))
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
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
        outline.registerForDraggedTypes([dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setAccessibilityLabel(String(localized: "Hosts and projects"))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
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
    func reload() {
        guard let manager else { return }
        let groups = HostGroups.shared
        let signature =
            manager.projects.map { "\($0.id):\($0.hostID):\($0.name)" }.joined(separator: "|")
            + "#\(manager.selectedProjectID?.uuidString ?? "")#\(manager.selectedRemoteProject?.projectID.uuidString ?? "")#\(groups.revision)"
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
            image.translatesAutoresizingMaskIntoConstraints = false
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.addSubview(text)
            cell.imageView = image
            cell.textField = text
            text.lineBreakMode = .byTruncatingTail
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.font = .systemFont(ofSize: AppSettings.shared.sidebarFontSize)
        var label = row.title
        if row.kind == "ssh", HostGroups.shared.isExpanded(row.id),
            let connection = HostGroups.shared.connection(row.id)
        {
            switch connection.state {
            case .disconnected: label += " · Disconnected"
            case .connecting: label += " · Connecting…"
            case .reconnecting: label += " · Reconnecting…"
            case .installing: label += " · Installing…"
            case .connected: label += " · Connected"
            case .failed: label += " · Failed"
            }
        }
        cell.textField?.stringValue = label
        let symbol =
            row.kind == "local"
            ? "laptopcomputer"
            : row.kind == "ssh" ? "network" : row.kind == "relay" ? "desktopcomputer" : "folder"
        cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        cell.toolTip = row.title
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
        HostGroups.shared.setExpanded(row.id, expanded)
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let row = outline.item(atRow: outline.clickedRow) as? Row else { return }
        if row.kind == "ssh" || row.kind == "local" {
            let item = NSMenuItem(
                title: String(localized: "New Project"), action: #selector(newHostProject),
                keyEquivalent: "")
            item.target = self
            item.representedObject = row.id
            item.isEnabled = HostGroups.shared.isExpanded(row.id)
            menu.addItem(item)
            return
        }
        guard row.kind == "project" else { return }
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
        guard let row = item as? Row, row.kind == "project" else { return nil }
        let value = NSPasteboardItem()
        value.setString(row.id.uuidString, forType: dragType)
        return value
    }
    func outlineView(
        _ view: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let target = item as? Row, target.kind == "project",
            let id = info.draggingPasteboard.string(forType: dragType).flatMap(UUID.init(uuidString:)),
            let source = rows[id], source.hostID == target.hostID
        else { return [] }
        return .move
    }
    func outlineView(
        _ view: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int
    ) -> Bool {
        guard let row = item as? Row,
            let id = info.draggingPasteboard.string(forType: dragType).flatMap(UUID.init(uuidString:))
        else { return false }
        manager?.moveProject(id, to: row.id)
        return true
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
