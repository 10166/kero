import AppKit

@MainActor
enum SSHHostConfigurationSheet {
    static func present(on window: NSWindow?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Add SSH Host")
        alert.informativeText = String(
            localized:
                "Use an SSH config alias or user@host. Kero installs its daemon in your remote user directory."
        )
        let name = NSTextField(string: "")
        let destination = NSTextField(string: "")
        let port = NSTextField(string: "")
        let directory = NSTextField(string: "")
        name.placeholderString = String(localized: "Display name")
        destination.placeholderString = "ubuntu@example.com"
        port.placeholderString = "SSH config (default 22)"
        directory.placeholderString = String(localized: "Home directory")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Name")), name],
            [NSTextField(labelWithString: String(localized: "Host")), destination],
            [NSTextField(labelWithString: String(localized: "Port")), port],
            [NSTextField(labelWithString: String(localized: "Directory")), directory],
        ])
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 132)
        grid.column(at: 1).width = 260
        grid.rowSpacing = 8
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Add"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let host = destination.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let number = port.stringValue.isEmpty ? UInt16(0) : UInt16(port.stringValue)
            guard !host.isEmpty, !host.hasPrefix("-"), let number,
                directory.stringValue.isEmpty || directory.stringValue.hasPrefix("/")
            else {
                let error = NSAlert()
                error.messageText = "Invalid SSH host"
                error.informativeText =
                    "Enter a host, a valid port, and an absolute remote directory (or leave it empty)."
                error.beginSheetModal(for: window)
                return
            }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            HostGroups.shared.add(
                SSHHostDefinition(
                    name: title.isEmpty ? host : title, destination: host, port: number,
                    directory: directory.stringValue))
        }
    }
}
