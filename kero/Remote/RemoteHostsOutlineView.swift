import AppKit
import SwiftUI

struct RemoteHostsOutlineRepresentable: NSViewRepresentable {
    @ObservedObject private var service = RemoteControlService.shared
    let manager: TerminalManager

    func makeNSView(context: Context) -> RemoteHostsOutlineView {
        RemoteHostsOutlineView(manager: manager)
    }

    func updateNSView(_ view: RemoteHostsOutlineView, context: Context) {
        view.manager = manager
        view.reload(hosts: service.hosts)
    }
}

@MainActor
final class RemoteHostsOutlineView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var manager: TerminalManager?

    private let outline = NSOutlineView()
    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("remote"))
    private var hosts: [RemoteHostNode] = []
    private var nodesByID: [UUID: RemoteHostNode] = [:]
    private var expandedHostIDs = Set<UUID>()

    init(manager: TerminalManager) {
        self.manager = manager
        super.init(frame: .zero)
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 30
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(outline)
        NSLayoutConstraint.activate([
            outline.leadingAnchor.constraint(equalTo: leadingAnchor),
            outline.trailingAnchor.constraint(equalTo: trailingAnchor),
            outline.topAnchor.constraint(equalTo: topAnchor),
            outline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(CGFloat(outline.numberOfRows) * 32, hosts.isEmpty ? 0 : 32)
        )
    }

    func reload(hosts: [RemoteHost]) {
        let desiredIDs = Set(hosts.map(\.id))
        nodesByID = nodesByID.filter { desiredIDs.contains($0.key) }
        self.hosts = hosts.map { host in
            let node = nodesByID[host.id] ?? RemoteHostNode(host: host)
            node.update(host)
            nodesByID[host.id] = node
            return node
        }
        outline.reloadData()
        for host in self.hosts where expandedHostIDs.contains(host.id) {
            outline.expandItem(host, expandChildren: false)
        }
        selectCurrentProject()
        invalidateIntrinsicContentSize()
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        if item == nil { return hosts.count }
        return (item as? RemoteHostNode)?.projects.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        if let host = item as? RemoteHostNode {
            return host.projects[index]
        }
        return hosts[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? RemoteHostNode)?.projects.isEmpty == false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("RemoteTreeCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView ?? makeCell(identifier: identifier)
        if let host = item as? RemoteHostNode {
            cell.imageView?.image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
            cell.textField?.stringValue = host.name
            cell.textField?.textColor = host.isOnline && host.isHostEnabled
                ? .labelColor : .secondaryLabelColor
            cell.toolTip = host.isOnline
                ? (host.isHostEnabled ? String(localized: "Online") : String(localized: "Remote control disabled"))
                : String(localized: "Offline")
        } else if let project = item as? RemoteProjectItem {
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            cell.textField?.stringValue = project.project.name
            cell.textField?.textColor = .labelColor
            cell.toolTip = nil
        }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0 else { return }
        if let host = outline.item(atRow: row) as? RemoteHostNode {
            if outline.isItemExpanded(host) {
                expandedHostIDs.remove(host.id)
                outline.collapseItem(host)
            } else {
                expandedHostIDs.insert(host.id)
                outline.expandItem(host)
            }
            outline.deselectRow(row)
            invalidateIntrinsicContentSize()
        } else if let item = outline.item(atRow: row) as? RemoteProjectItem {
            manager?.selectRemoteProject(hostID: item.hostID, projectID: item.project.id)
        }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if let host = notification.userInfo?["NSObject"] as? RemoteHostNode {
            expandedHostIDs.insert(host.id)
        }
        invalidateIntrinsicContentSize()
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if let host = notification.userInfo?["NSObject"] as? RemoteHostNode {
            expandedHostIDs.remove(host.id)
        }
        invalidateIntrinsicContentSize()
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let image = NSImageView()
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingTail
        text.font = .systemFont(ofSize: 11.5)
        image.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.addSubview(text)
        cell.imageView = image
        cell.textField = text
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 7),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func selectCurrentProject() {
        guard let selection = manager?.selectedRemoteProject else { return }
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? RemoteProjectItem else { continue }
            if item.hostID == selection.hostID && item.project.id == selection.projectID {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
        }
    }
}

private final class RemoteHostNode: NSObject {
    let id: UUID
    private(set) var name: String
    private(set) var isOnline: Bool
    private(set) var isHostEnabled: Bool
    private(set) var projects: [RemoteProjectItem] = []
    private var projectsByID: [UUID: RemoteProjectItem] = [:]

    init(host: RemoteHost) {
        id = host.id
        name = host.name
        isOnline = host.isOnline
        isHostEnabled = host.isHostEnabled
        super.init()
        update(host)
    }

    func update(_ host: RemoteHost) {
        name = host.name
        isOnline = host.isOnline
        isHostEnabled = host.isHostEnabled
        let descriptors = host.topology?.projects ?? []
        let desiredIDs = Set(descriptors.map(\.id))
        projectsByID = projectsByID.filter { desiredIDs.contains($0.key) }
        projects = descriptors.map { descriptor in
            let node = projectsByID[descriptor.id]
                ?? RemoteProjectItem(hostID: id, project: descriptor)
            node.project = descriptor
            projectsByID[descriptor.id] = node
            return node
        }
    }
}

private final class RemoteProjectItem: NSObject {
    let hostID: UUID
    var project: RemoteProjectDescriptor

    init(hostID: UUID, project: RemoteProjectDescriptor) {
        self.hostID = hostID
        self.project = project
    }
}
