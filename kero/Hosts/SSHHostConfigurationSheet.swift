import AppKit

@MainActor
enum SSHHostConfigurationSheet {
    static let connectResponse = NSApplication.ModalResponse(9001)

    static func present(on window: NSWindow?, edit hostID: UUID? = nil) {
        guard window != nil else { return }
        let title = hostID == nil
            ? String(localized: "Add SSH Host") : String(localized: "Edit SSH Host")
        let controller = SSHHostConfigurationController(hostID: hostID)
        SheetPresenter.shared.present(controller, title: title, on: window) { response in
            guard response == connectResponse, let id = controller.connectAfterClose else { return }
            HostGroups.shared.connectHost(id, userInitiated: true)
        }
    }
}

@MainActor
final class SSHHostConfigurationController: NSViewController {
    private let initialHostID: UUID?
    private(set) var connectAfterClose: UUID?
    private var editingID: UUID?

    private let nameField = NSTextField()
    private let destinationField = NSTextField()
    private let portField = NSTextField()
    private let directoryField = NSTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: String(localized: "Save"), target: nil, action: nil)
    private let connectButton = NSButton(
        title: String(localized: "Save & Connect"), target: nil, action: nil)

    init(hostID: UUID?) {
        initialHostID = hostID
        editingID = hostID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 348))

        for field in [nameField, destinationField, portField, directoryField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.bezelStyle = .roundedBezel
        }
        nameField.placeholderString = String(localized: "Optional display name")
        destinationField.placeholderString = "alias or user@host"
        portField.placeholderString = String(localized: "SSH config (default 22)")
        directoryField.placeholderString = String(localized: "Remote home directory")
        let portFormatter = NumberFormatter()
        portFormatter.allowsFloats = false
        portFormatter.minimum = 1
        portFormatter.maximum = 65_535
        portField.formatter = portFormatter

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Display Name")), nameField],
            [NSTextField(labelWithString: String(localized: "SSH Destination")), destinationField],
            [NSTextField(labelWithString: String(localized: "Port")), portField],
            [NSTextField(labelWithString: String(localized: "Startup Directory")), directoryField],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 1).xPlacement = .fill
        grid.row(at: 0).height = 28
        grid.row(at: 1).height = 28
        grid.row(at: 2).height = 28
        grid.row(at: 3).height = 28
        grid.column(at: 0).width = 116

        let note = NSTextField(wrappingLabelWithString: String(
            localized:
                "Authentication, IdentityFile, ProxyJump, and algorithms continue to come from ~/.ssh/config. Kero saves only this host’s display and connection entry."
        ))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.translatesAutoresizingMaskIntoConstraints = false

        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.isHidden = true
        errorLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancel = NSButton(
            title: String(localized: "Cancel"), target: self, action: #selector(closeSheet))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.bezelStyle = .regularSquare
        saveButton.keyEquivalent = "\r"
        saveButton.target = self
        saveButton.action = #selector(save)
        connectButton.bezelStyle = .regularSquare
        connectButton.target = self
        connectButton.action = #selector(saveAndConnect)
        let buttons = NSStackView(views: [cancel, saveButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(grid)
        view.addSubview(note)
        view.addSubview(errorLabel)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            note.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            note.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            note.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            errorLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            errorLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            errorLabel.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 8),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
        ])

        if let id = initialHostID, let host = HostGroups.shared.definition(id) {
            nameField.stringValue = host.name
            destinationField.stringValue = host.destination
            portField.stringValue = host.port.map(String.init) ?? ""
            directoryField.stringValue = host.directory ?? ""
        }
        destinationField.becomeFirstResponder()
    }

    private func validatedHost() -> SSHHostDefinition? {
        let destination = destinationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let portText = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory =
            directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !destination.isEmpty, !destination.hasPrefix("-") else {
            showValidationError(String(localized: "Enter an SSH alias or user@host."))
            return nil
        }
        var port: UInt16?
        if !portText.isEmpty {
            guard portText.allSatisfy(\.isNumber), let number = UInt16(portText), number >= 1 else {
                showValidationError(String(localized: "Port must be empty or a number from 1 to 65,535."))
                return nil
            }
            port = number
        }
        guard directory.isEmpty || directory.hasPrefix("/") else {
            showValidationError(String(localized: "Startup directory must be absolute or empty."))
            return nil
        }
        return SSHHostDefinition(
            id: editingID ?? UUID(), name: title.isEmpty ? destination : title,
            destination: destination, port: port, directory: directory.isEmpty ? nil : directory)
    }

    private func showValidationError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = false
    }

    @objc private func save() { apply(connectAfterClosing: false) }

    @objc private func saveAndConnect() { apply(connectAfterClosing: true) }

    private func apply(connectAfterClosing: Bool) {
        guard let host = validatedHost() else { return }
        let old = editingID.flatMap { HostGroups.shared.definition($0) }
        let changesTransport =
            old.map { $0.destination != host.destination || $0.port != host.port } ?? false
        let isExpanded = editingID.map { HostGroups.shared.isExpanded($0) } ?? false

        if changesTransport, isExpanded {
            let alert = NSAlert()
            alert.messageText = String(localized: "Reconnect this SSH host?")
            alert.informativeText = String(
                localized:
                    "Changing the destination or port disconnects the current Kero connection and reconnects with the new settings. Remote shells keep running under the daemon."
            )
            alert.addButton(withTitle: String(localized: "Reconnect"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard let sheet = view.window else { return }
            alert.beginSheetModal(for: sheet) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.performSave(host, connectAfterClosing: connectAfterClosing)
            }
            return
        }
        performSave(host, connectAfterClosing: connectAfterClosing)
    }

    private func performSave(_ host: SSHHostDefinition, connectAfterClosing: Bool) {
        HostGroups.shared.clearPersistenceError()
        // A failed add leaves the definition in memory by design. Remember it
        // immediately so retrying Save updates that host instead of adding a
        // second in-memory copy.
        let isExisting = editingID != nil
        editingID = host.id
        let saved =
            isExisting ? HostGroups.shared.update(host) : HostGroups.shared.add(host)
        guard saved else {
            showValidationError(
                HostGroups.shared.persistenceErrorMessage
                    ?? String(localized: "The SSH host could not be saved."))
            return
        }
        if connectAfterClosing {
            connectAfterClose = host.id
            close(connect: true)
        } else {
            close(connect: false)
        }
    }

    @objc private func closeSheet() { close(connect: false) }

    private func close(connect: Bool) {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(
            sheet,
            returnCode: connect ? SSHHostConfigurationSheet.connectResponse : .cancel)
    }
}
