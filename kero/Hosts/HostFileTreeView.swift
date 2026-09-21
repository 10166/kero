import AppKit
import Combine
import SwiftUI

struct HostFileTreeRepresentable: NSViewRepresentable {
    let model: FileTreeModel
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (String, String) -> Void
    func makeNSView(context: Context) -> HostFileTreeView {
        HostFileTreeView(model: model, open: openFile, side: openToSide, rename: onRename)
    }
    func updateNSView(_ view: HostFileTreeView, context: Context) { view.reload() }
}

@MainActor
final class HostFileTreeView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private let model: FileTreeModel
    private let table = NSTableView()
    private let title = NSTextField(labelWithString: "")
    private let open: (String) -> Void
    private let side: (String) -> Void
    private var observation: AnyCancellable?
    private var displayedItems: [FileTreeModel.Item] = []
    private var displayedExpansion: Set<String> = []
    private var displayedFontSize: Double = 0
    init(
        model: FileTreeModel, open: @escaping (String) -> Void, side: @escaping (String) -> Void,
        rename: @escaping (String, String) -> Void
    ) {
        self.model = model
        self.open = open
        self.side = side
        super.init(frame: .zero)
        model.onCreated = open
        model.onRenamed = rename
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let column = NSTableColumn(identifier: .init("files"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 25
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(activate)
        table.setAccessibilityLabel("Project files")
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        let add = NSButton(
            image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New File")!, target: self,
            action: #selector(newFile))
        add.isBordered = false
        let refresh = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Files")!,
            target: self, action: #selector(refreshFiles))
        refresh.isBordered = false
        title.lineBreakMode = .byTruncatingHead
        title.font = .systemFont(ofSize: 11)
        for view in [title, add, refresh, scroll] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            add.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            add.trailingAnchor.constraint(equalTo: refresh.leadingAnchor, constant: -4),
            refresh.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            refresh.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: add.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observation = model.objectWillChange.debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }
    func reload() {
        title.stringValue = model.error ?? model.rootPath
        title.toolTip = title.stringValue
        let items = model.items
        let expansion = Set(items.filter { $0.isDirectory && model.isExpanded($0) }.map(\.path))
        let fontSize = AppSettings.shared.sidebarFontSize
        guard displayedItems != items || displayedExpansion != expansion || displayedFontSize != fontSize
        else { return }
        let selection = table.selectedRowIndexes.compactMap {
            displayedItems.indices.contains($0) ? displayedItems[$0].path : nil
        }
        // SwiftUI updates and unchanged watch events must not recreate every
        // AppKit row or clear the user's selection. Snapshot rows together so
        // a pending model refresh cannot invalidate a table delegate index.
        displayedItems = items
        displayedExpansion = expansion
        displayedFontSize = fontSize
        table.reloadData()
        table.selectRowIndexes(
            IndexSet(items.indices.filter { selection.contains(items[$0].path) }), byExtendingSelection: false
        )
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }
    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = displayedItems[row]
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell =
            (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? NSTableCellView()
        if cell.textField == nil {
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text)
            cell.textField = text
        }
        cell.textField?.frame = NSRect(
            x: CGFloat(8 + item.depth * 14), y: 4,
            width: max(20, tableView.bounds.width - CGFloat(16 + item.depth * 14)), height: 18)
        cell.textField?.font = .systemFont(ofSize: AppSettings.shared.sidebarFontSize)
        cell.textField?.stringValue =
            (item.isDirectory ? (model.isExpanded(item) ? "▾ " : "▸ ") : "  ") + item.name
        cell.toolTip = item.path
        return cell
    }
    private var selected: FileTreeModel.Item? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return displayedItems.indices.contains(row) ? displayedItems[row] : nil
    }
    @objc private func activate() {
        guard let item = selected else { return }
        if item.isDirectory { model.toggle(item) } else { open(item.path) }
    }
    @objc private func openSide() { if let item = selected, !item.isDirectory { side(item.path) } }
    @objc private func refreshFiles() { model.refresh() }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for (label, selector) in [
            ("Open", #selector(activate)), ("Open to Side", #selector(openSide)),
            ("New File…", #selector(newFile)), ("New Folder…", #selector(newFolder)),
            ("Rename…", #selector(rename)), ("Delete…", #selector(remove)),
        ] {
            let item = NSMenuItem(title: label, action: selector, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
    }
    private func name(_ title: String, value: String = "", apply: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) {
                if $0 == .alertFirstButtonReturn { apply(field.stringValue) }
            }
        }
    }
    private var parent: String {
        if let item = selected {
            return item.isDirectory ? item.path : (item.path as NSString).deletingLastPathComponent
        }
        return model.rootPath
    }
    @objc private func newFile() {
        let parent = parent
        guard !parent.isEmpty else { return }
        name("New File") { [weak self] value in
            self?.model.beginNewFile(in: parent)
            self?.model.commitDraft(name: value)
        }
    }
    @objc private func newFolder() {
        let parent = parent
        guard !parent.isEmpty else { return }
        name("New Folder") { [weak self] value in
            self?.model.beginNewFolder(in: parent)
            self?.model.commitDraft(name: value)
        }
    }
    @objc private func rename() {
        guard let item = selected else { return }
        name("Rename", value: item.name) { [weak self] in self?.model.rename(item, to: $0) }
    }
    @objc private func remove() { if let item = selected { model.moveToTrash(item) } }
}
