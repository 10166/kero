import AppKit
import Combine
import SwiftUI

struct HostFileTreeRepresentable: NSViewRepresentable {
    let model: FileTreeModel
    let git: GitStatusModel
    let session: TerminalSession?
    let rootBadge: (text: String, description: String)?
    let currentFilePath: String?
    let openFile: (String) -> Void
    let openToSide: (String) -> Void
    let onRename: (String, String) -> Void
    let refreshGitStatus: () -> Void

    func makeNSView(context: Context) -> HostFileTreeView {
        let view = HostFileTreeView(
            model: model, git: git, open: openFile, side: openToSide,
            rename: onRename, refreshGitStatus: refreshGitStatus
        )
        view.configure(session: session, badge: rootBadge, currentFilePath: currentFilePath)
        return view
    }

    func updateNSView(_ view: HostFileTreeView, context: Context) {
        view.configure(session: session, badge: rootBadge, currentFilePath: currentFilePath)
    }
}

/// View-based AppKit rows keep the same density and information as the former
/// file tree without creating one SwiftUI hierarchy for every visible entry.
@MainActor
final class HostFileTreeView: NSView, NSTableViewDataSource, NSTableViewDelegate,
    NSMenuDelegate, NSTextFieldDelegate
{
    override var isFlipped: Bool { true }

    private let model: FileTreeModel
    private let git: GitStatusModel
    private let open: (String) -> Void
    private let side: (String) -> Void
    private let rename: (String, String) -> Void
    private let refreshGitStatus: () -> Void
    private weak var session: TerminalSession?
    private var currentFilePath: String?
    private var rootBadge: (text: String, description: String)?
    private var observation: AnyCancellable?

    private let scroll = NSScrollView()
    private let table = NSTableView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let refreshButton = NSButton()
    private let reveal = NSButton()
    private var displayedItems: [FileTreeModel.Item] = []
    private var displayedExpansion: Set<String> = []
    private var displayedDecorations: [String: GitStatusModel.FileDecoration] = [:]
    private var displayedGitRoot = ""
    private var displayedIsRepo = false
    private var displayedFontSize: Double = 0
    private var displayedAppearance: NSAppearance.Name?
    private var displayedCurrentFilePath: String?
    private var displayedRenamePath: String?
    private var editingPath: String?
    private var menuIsTracking = false

    init(
        model: FileTreeModel, git: GitStatusModel,
        open: @escaping (String) -> Void,
        side: @escaping (String) -> Void,
        rename: @escaping (String, String) -> Void,
        refreshGitStatus: @escaping () -> Void
    ) {
        self.model = model
        self.git = git
        self.open = open
        self.side = side
        self.rename = rename
        self.refreshGitStatus = refreshGitStatus
        super.init(frame: .zero)
        model.onCreated = { [weak self] path in
            self?.open(path)
        }
        model.onRenamed = { [weak self] old, new in
            self?.rename(old, new)
        }
        model.onChanged = { [weak self] in self?.refreshGitStatus() }

        title.lineBreakMode = .byTruncatingTail
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.textColor = .secondaryLabelColor
        badge.alignment = .center
        badge.textColor = .secondaryLabelColor
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New File")
        addButton.imagePosition = .imageOnly
        addButton.isBordered = false
        addButton.target = self
        addButton.action = #selector(newFile)
        addButton.toolTip = String(localized: "New File…")
        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh Files")
        refreshButton.imagePosition = .imageOnly
        refreshButton.isBordered = false
        refreshButton.target = self
        refreshButton.action = #selector(refreshFiles)
        refreshButton.toolTip = String(localized: "Refresh Files")
        reveal.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Reveal in Finder")
        reveal.imagePosition = .imageOnly
        reveal.isBordered = false
        reveal.target = self
        reveal.action = #selector(revealRoot)
        reveal.toolTip = String(localized: "Reveal in Finder")

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        let column = NSTableColumn(identifier: .init("files"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.intercellSpacing = .zero
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(activate)
        table.setAccessibilityLabel(String(localized: "Project files"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        scroll.documentView = table
        for view in [title, subtitle, badge, addButton, refreshButton, reveal, scroll] {
            addSubview(view)
        }

        observation = model.objectWillChange
            .debounce(for: .milliseconds(20), scheduler: RunLoop.main)
            .sink { [weak self] in self?.reload() }
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        session: TerminalSession?, badge: (text: String, description: String)?,
        currentFilePath: String?
    ) {
        self.session = session
        rootBadge = badge
        self.currentFilePath = currentFilePath
        reload()
    }

    override func layout() {
        super.layout()
        let scale = CGFloat(AppSettings.shared.sidebarFontSize / AppSettings.defaultSidebarFontSize)
        let headerHeight: CGFloat = 48 * scale
        let right = bounds.width - 12
        let buttonWidth: CGFloat = 18 * scale
        let gap: CGFloat = 4 * scale
        let showReveal = !reveal.isHidden
        let buttonCount: CGFloat = showReveal ? 3 : 2
        let buttonsWidth = buttonCount * buttonWidth + (buttonCount - 1) * gap
        let buttonsLeft = right - buttonsWidth
        let badgeWidth = rootBadge == nil ? 0 : badge.intrinsicContentSize.width + 10
        let titleWidth = max(40, buttonsLeft - badgeWidth - 17)
        title.frame = NSRect(x: 12, y: 8 * scale, width: titleWidth, height: 17 * scale)
        badge.frame = NSRect(
            x: title.frame.maxX + 5, y: 9 * scale,
            width: badgeWidth, height: 16 * scale
        )
        subtitle.frame = NSRect(x: 12, y: 27 * scale, width: max(0, right - 12), height: 14 * scale)
        addButton.frame = NSRect(x: buttonsLeft, y: 8 * scale, width: buttonWidth, height: buttonWidth)
        refreshButton.frame = NSRect(
            x: buttonsLeft + buttonWidth + gap, y: 8 * scale,
            width: buttonWidth, height: buttonWidth
        )
        reveal.frame = NSRect(
            x: buttonsLeft + 2 * (buttonWidth + gap), y: 8 * scale,
            width: buttonWidth, height: buttonWidth
        )
        scroll.frame = NSRect(
            x: 0, y: headerHeight, width: bounds.width,
            height: max(0, bounds.height - headerHeight)
        )
    }

    func reload() {
        let subtitleText = model.error ?? model.rootPath
        let headerChanged = title.stringValue != model.rootName
            || subtitle.stringValue != subtitleText
            || badge.stringValue != (rootBadge?.text ?? "")
            || badge.isHidden != (rootBadge == nil)
        if title.stringValue != model.rootName { title.stringValue = model.rootName }
        title.toolTip = model.rootPath
        if subtitle.stringValue != subtitleText { subtitle.stringValue = subtitleText }
        subtitle.textColor = model.error == nil ? .secondaryLabelColor : .systemRed
        subtitle.toolTip = subtitle.stringValue
        if let rootBadge {
            if badge.stringValue != rootBadge.text { badge.stringValue = rootBadge.text }
            badge.setAccessibilityLabel(rootBadge.description)
        }
        badge.isHidden = rootBadge == nil
        if headerChanged { needsLayout = true }
        let hideReveal = session?.hostID != HostGroups.localID
        if reveal.isHidden != hideReveal {
            reveal.isHidden = hideReveal
            needsLayout = true
        }
        addButton.isEnabled = !model.rootPath.isEmpty
        refreshButton.isEnabled = !model.rootPath.isEmpty
        let scale = CGFloat(AppSettings.shared.sidebarFontSize / AppSettings.defaultSidebarFontSize)
        title.font = .systemFont(ofSize: 12 * scale, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 10 * scale)
        badge.font = .systemFont(ofSize: 9 * scale, weight: .medium)
        let rowHeight = 22 * scale
        if table.rowHeight != rowHeight { table.rowHeight = rowHeight }

        let items = rowsWithDraft(model.items)
        let expansion = Set(items.filter { $0.isDirectory && model.isExpanded($0) }.map(\.path))
        let fontSize = AppSettings.shared.sidebarFontSize
        let appearance = NSApp.effectiveAppearance.name
        let changed = displayedItems != items || displayedExpansion != expansion
            || displayedDecorations != git.fileDecorations || displayedGitRoot != git.repoRoot
            || displayedIsRepo != git.isRepo || displayedFontSize != fontSize
            || displayedAppearance != appearance || displayedCurrentFilePath != currentFilePath
            || displayedRenamePath != model.renamingPath
        guard changed else { return }
        let selectedPaths = table.selectedRowIndexes.compactMap { index in
            displayedItems.indices.contains(index) ? displayedItems[index].path : nil
        }
        needsLayout = true
        displayedItems = items
        displayedExpansion = expansion
        displayedDecorations = git.fileDecorations
        displayedGitRoot = git.repoRoot
        displayedIsRepo = git.isRepo
        displayedFontSize = fontSize
        displayedAppearance = appearance
        displayedCurrentFilePath = currentFilePath
        displayedRenamePath = model.renamingPath
        table.reloadData()
        let selectedPath = currentFilePath ?? selectedPaths.first
        if let selectedPath, let index = items.firstIndex(where: { $0.path == selectedPath }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        if let edit = items.first(where: { $0.isDraft || $0.path == model.renamingPath }),
           editingPath != edit.path {
            editingPath = edit.path
            if !menuIsTracking { focusEditingField() }
        }
    }

    private func focusEditingField() {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.menuIsTracking, let editingPath = self.editingPath,
                  let index = self.displayedItems.firstIndex(where: { $0.path == editingPath }),
                  let cell = self.table.view(atColumn: 0, row: index,
                                             makeIfNecessary: true) as? FileTreeCell
            else { return }
            self.window?.makeFirstResponder(cell.nameField)
            // selectText(_:) starts a second editing pass and immediately
            // ends the draft after a context menu action. Select in the live
            // field editor instead.
            cell.nameField.currentEditor()?.selectAll(nil)
        }
    }

    private func rowsWithDraft(_ items: [FileTreeModel.Item]) -> [FileTreeModel.Item] {
        guard let draft = model.draft else { return items }
        let depth: Int
        let index: Int
        if draft.parentDir == model.rootPath {
            depth = 0
            index = 0
        } else if let parent = items.firstIndex(where: { $0.path == draft.parentDir }) {
            depth = items[parent].depth + 1
            index = parent + 1
        } else {
            return items
        }
        var rows = items
        rows.insert(.init(
            name: "", path: draft.parentDir + "/\u{1}draft",
            isDirectory: draft.isDirectory, depth: depth, isDraft: true
        ), at: index)
        return rows
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayedItems.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let item = displayedItems[row]
        let identifier = NSUserInterfaceItemIdentifier("file")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileTreeCell)
            ?? FileTreeCell()
        cell.identifier = identifier
        let decoration = git.fileDecoration(for: item.path, isDirectory: item.isDirectory)
        let editing = item.isDraft || model.renamingPath == item.path
        cell.configure(
            item: item, expanded: model.isExpanded(item), decoration: decoration,
            editing: editing, fontSize: AppSettings.shared.sidebarFontSize
        )
        cell.nameField.delegate = self
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        FileTreeRowView()
    }

    private var selected: FileTreeModel.Item? {
        let row = table.selectedRow
        return displayedItems.indices.contains(row) ? displayedItems[row] : nil
    }

    @objc private func activate() {
        guard editingPath == nil, let item = selected, !item.isDraft else { return }
        if item.isDirectory { model.toggle(item) } else { open(item.path) }
    }

    @objc private func revealRoot() {
        guard !model.rootPath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.rootPath)])
    }

    @objc private func refreshFiles() {
        model.refresh()
        refreshGitStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // NSTableView keeps `clickedRow` after the click. Sync selection for a
        // context menu, then use the actual selection for toolbar and keyboard
        // actions so a previous right click cannot target the wrong file.
        if table.clickedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: table.clickedRow), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        menu.removeAllItems()
        let item = selected
        func add(_ title: String, _ action: Selector) {
            let value = NSMenuItem(title: title, action: action, keyEquivalent: "")
            value.target = self
            menu.addItem(value)
        }
        if let item, !item.isDraft {
            if !item.isDirectory {
                add(String(localized: "Open"), #selector(activate))
                add(String(localized: "Open to the Side"), #selector(openSide))
            }
            if session?.hostID == HostGroups.localID {
                add(String(localized: "Open in Default App"), #selector(openDefault))
                add(String(localized: "Reveal in Finder"), #selector(revealItem))
            }
            add(String(localized: "Copy Path"), #selector(copyPath))
            if item.isDirectory {
                add(String(localized: "cd Here"), #selector(cdHere))
            }
            menu.addItem(.separator())
        }
        add(String(localized: "New File…"), #selector(newFile))
        add(String(localized: "New Folder…"), #selector(newFolder))
        if let item, !item.isDraft {
            menu.addItem(.separator())
            add(String(localized: "Rename"), #selector(renameItem))
            add(session?.hostID == HostGroups.localID
                ? String(localized: "Move to Trash") : String(localized: "Delete…"),
                #selector(removeItem))
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsTracking = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsTracking = false
        if editingPath != nil { focusEditingField() }
    }

    private var parent: String {
        guard let item = selected, !item.isDraft else { return model.rootPath }
        return item.isDirectory ? item.path : (item.path as NSString).deletingLastPathComponent
    }

    @objc private func openSide() { if let item = selected, !item.isDirectory { side(item.path) } }
    @objc private func openDefault() {
        if let item = selected { NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) }
    }
    @objc private func revealItem() {
        if let item = selected {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
        }
    }
    @objc private func copyPath() {
        guard let item = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.path, forType: .string)
    }
    @objc private func cdHere() {
        guard let item = selected, item.isDirectory else { return }
        let path = "'" + item.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        session?.sendCommand("cd " + path + "\n")
    }
    @objc private func newFile() { model.beginNewFile(in: parent) }
    @objc private func newFolder() { model.beginNewFolder(in: parent) }
    @objc private func renameItem() { if let item = selected { model.beginRename(item) } }
    @objc private func removeItem() {
        guard let item = selected else { return }
        model.moveToTrash(item)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishEditing(cancel: false)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishEditing(cancel: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(cancel: false)
    }

    private func finishEditing(cancel: Bool) {
        guard let editingPath,
              let index = displayedItems.firstIndex(where: { $0.path == editingPath }) else { return }
        let item = displayedItems[index]
        let name = (table.view(atColumn: 0, row: index, makeIfNecessary: false) as? FileTreeCell)?
            .nameField.stringValue ?? ""
        self.editingPath = nil
        if item.isDraft {
            if cancel || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.cancelDraft()
            } else {
                model.commitDraft(name: name)
            }
        } else if cancel {
            model.cancelRename()
        } else {
            model.rename(item, to: name)
        }
        window?.makeFirstResponder(table)
        reload()
    }
}

private final class FileTreeRowView: NSTableRowView {
    private var hovering = false
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.09).setFill()
        bounds.insetBy(dx: 6, dy: 1).roundedPath(cornerRadius: 4).fill()
    }
    override func drawBackground(in dirtyRect: NSRect) {
        if hovering && !isSelected {
            NSColor.labelColor.withAlphaComponent(0.05).setFill()
            bounds.insetBy(dx: 6, dy: 1).roundedPath(cornerRadius: 4).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil
        ))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
}

private final class FileTreeCell: NSTableCellView {
    let disclosure = NSImageView()
    let icon = NSImageView()
    let nameField = NSTextField(labelWithString: "")
    let badge = NSTextField(labelWithString: "")
    private var depth = 0
    private var scale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosure.imageScaling = .scaleProportionallyDown
        icon.imageScaling = .scaleProportionallyDown
        nameField.lineBreakMode = .byTruncatingTail
        badge.alignment = .right
        badge.lineBreakMode = .byClipping
        addSubview(disclosure)
        addSubview(icon)
        addSubview(nameField)
        addSubview(badge)
        textField = nameField
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        item: FileTreeModel.Item, expanded: Bool,
        decoration: GitStatusModel.FileDecoration?, editing: Bool, fontSize: Double
    ) {
        scale = CGFloat(fontSize / AppSettings.defaultSidebarFontSize)
        depth = item.depth
        disclosure.image = item.isDirectory && !item.isDraft
            ? NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                      accessibilityDescription: nil) : nil
        disclosure.contentTintColor = .tertiaryLabelColor
        if item.isDirectory {
            icon.image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)
            icon.contentTintColor = Theme.accent.withAlphaComponent(0.8)
        } else {
            icon.image = MaterialFileIcon.image(forPath: item.path)
            icon.contentTintColor = nil
        }
        nameField.font = .systemFont(ofSize: 11.5 * scale)
        nameField.isEditable = editing
        nameField.isSelectable = editing
        nameField.isBezeled = editing
        nameField.drawsBackground = editing
        nameField.backgroundColor = Theme.background
        nameField.stringValue = item.isDraft ? "" : item.name
        nameField.placeholderString = item.isDraft
            ? (item.isDirectory ? String(localized: "Folder name") : String(localized: "File name"))
            : nil
        nameField.textColor = editing ? .labelColor
            : decoration?.nsColor ?? (item.name.hasPrefix(".")
                ? NSColor.secondaryLabelColor.withAlphaComponent(0.55) : .secondaryLabelColor)
        badge.isHidden = decoration == nil || editing
        badge.stringValue = decoration?.badge ?? ""
        badge.textColor = decoration?.nsColor
        badge.font = .monospacedSystemFont(ofSize: 9 * scale, weight: .semibold)
        toolTip = item.path
        setAccessibilityLabel(decoration.map { item.name + ", " + $0.accessibilityName } ?? item.name)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inset = (6 + CGFloat(depth) * 12) * scale
        let height = bounds.height
        disclosure.frame = NSRect(x: inset, y: (height - 10 * scale) / 2,
                                  width: 10 * scale, height: 10 * scale)
        icon.frame = NSRect(x: inset + 15 * scale, y: (height - 14 * scale) / 2,
                            width: 14 * scale, height: 14 * scale)
        let badgeWidth: CGFloat = badge.isHidden ? 0 : 16 * scale
        nameField.frame = NSRect(
            x: inset + 34 * scale, y: (height - 18 * scale) / 2,
            width: max(20, bounds.width - inset - 42 * scale - badgeWidth), height: 18 * scale
        )
        badge.frame = NSRect(x: bounds.width - 22 * scale, y: (height - 16 * scale) / 2,
                             width: 16 * scale, height: 16 * scale)
    }
}

private extension NSRect {
    func roundedPath(cornerRadius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: self, xRadius: cornerRadius, yRadius: cornerRadius)
    }
}

private extension GitStatusModel.FileDecoration {
    var badge: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .untracked: "U"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .conflict: "!"
        case .ignored: "I"
        }
    }
    var accessibilityName: String {
        switch self {
        case .modified: String(localized: "Modified")
        case .added: String(localized: "Added")
        case .untracked: String(localized: "Untracked")
        case .deleted: String(localized: "Deleted")
        case .renamed: String(localized: "Renamed")
        case .copied: String(localized: "Copied")
        case .conflict: String(localized: "Conflict")
        case .ignored: String(localized: "Ignored")
        }
    }
    var nsColor: NSColor {
        switch self {
        case .modified: NSColor(calibratedRed: 0.82, green: 0.60, blue: 0.13, alpha: 1)
        case .added, .untracked: NSColor(calibratedRed: 0.25, green: 0.73, blue: 0.31, alpha: 1)
        case .deleted: NSColor(calibratedRed: 1.0, green: 0.48, blue: 0.45, alpha: 1)
        case .renamed, .copied: NSColor(calibratedRed: 0.35, green: 0.65, blue: 1.0, alpha: 1)
        case .conflict: NSColor(calibratedRed: 0.74, green: 0.55, blue: 1.0, alpha: 1)
        case .ignored: NSColor.secondaryLabelColor.withAlphaComponent(0.55)
        }
    }
}
