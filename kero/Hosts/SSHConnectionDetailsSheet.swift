import AppKit
import Combine

@MainActor
enum SSHConnectionDetailsSheet {
    static func present(hostID: UUID, on window: NSWindow?) {
        guard let window, window.attachedSheet == nil else { return }
        let sheet = NSWindow(
            contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = String(localized: "SSH Connection Details")
        let controller = SSHConnectionDetailsController(hostID: hostID)
        sheet.contentViewController = controller
        window.beginSheet(sheet)
    }
}

@MainActor
final class SSHConnectionDetailsController: NSViewController {
    private let hostID: UUID
    private var observations = Set<AnyCancellable>()
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let detailsText = NSTextView()
    private let retryButton = NSButton(title: String(localized: "Retry"), target: nil, action: nil)

    init(hostID: UUID) {
        self.hostID = hostID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        summary.textColor = .secondaryLabelColor
        summary.font = .systemFont(ofSize: 12, weight: .medium)
        summary.translatesAutoresizingMaskIntoConstraints = false

        let detailsScroll = NSScrollView()
        detailsScroll.hasVerticalScroller = true
        detailsScroll.autohidesScrollers = true
        detailsScroll.borderType = .bezelBorder
        detailsScroll.translatesAutoresizingMaskIntoConstraints = false
        detailsText.isEditable = false
        detailsText.isSelectable = true
        detailsText.isRichText = false
        detailsText.isHorizontallyResizable = false
        detailsText.isVerticallyResizable = true
        detailsText.autoresizingMask = [.width]
        detailsText.textContainer?.widthTracksTextView = true
        detailsText.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        detailsScroll.documentView = detailsText

        let close = NSButton(title: String(localized: "Close"), target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        close.bezelStyle = .regularSquare
        retryButton.bezelStyle = .regularSquare
        retryButton.target = self
        retryButton.action = #selector(retry)

        let buttons = NSStackView(views: [close, retryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(summary)
        view.addSubview(detailsScroll)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            summary.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            summary.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            detailsScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            detailsScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            detailsScroll.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 12),
            detailsScroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

        HostGroups.shared.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &observations)
        reload()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        detailsText.isSelectable = true
    }

    private func reload() {
        let groups = HostGroups.shared
        guard let host = groups.definition(hostID) else {
            summary.stringValue = String(localized: "This SSH host has been deleted.")
            detailsText.string = ""
            retryButton.isEnabled = false
            return
        }
        let connection = groups.connection(hostID)
        let stateText: String
        switch connection?.state {
        case .disconnected: stateText = String(localized: "Disconnected")
        case .connecting: stateText = String(localized: "Connecting…")
        case .reconnecting: stateText = String(localized: "Reconnecting…")
        case .installing: stateText = String(localized: "Installing…")
        case .connected: stateText = String(localized: "Connected")
        case .failed: stateText = String(localized: "Failed")
        case nil: stateText = String(localized: "Disconnected")
        }
        let portText =
            host.port.map { String($0) }
            ?? String(localized: "from ~/.ssh/config or SSH default")
        // SSH only populates these facts after daemon negotiation. A failed or
        // never-opened connection still has a placeholder shell, so showing it
        // would falsely imply that Kero contacted the remote side.
        let isConnected = connection?.state == .connected
        summary.stringValue = "\(host.name)\n\(stateText)\n\(host.destination)\n"
            + String(localized: "Port: \(portText)")

        var lines: [String] = []
        if isConnected, let home = connection?.home, !home.isEmpty {
            lines.append(String(localized: "Remote home: \(home)"))
        }
        if isConnected, let shell = connection?.shell, !shell.isEmpty {
            lines.append(String(localized: "Remote shell: \(shell)"))
        }
        if let failure = connection?.lastFailure {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            lines.append("")
            lines.append(String(localized: "Last failure"))
            lines.append("\(formatter.string(from: failure.occurredAt)) · \(failure.stage.rawValue)")
            lines.append(failure.message)
            if let diagnostics = failure.diagnostics, !diagnostics.isEmpty {
                lines.append("")
                lines.append(String(localized: "Technical diagnostics"))
                lines.append(diagnostics)
            }
        } else if lines.isEmpty {
            lines.append(String(localized: "No connection failure has been recorded for this host."))
        }
        detailsText.string = lines.joined(separator: "\n")
        detailsText.isEditable = false
        retryButton.isEnabled = true
    }

    @objc private func closeSheet() {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
    }

    @objc private func retry() {
        guard let sheet = view.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet)
        if HostGroups.shared.isExpanded(hostID), let connection = HostGroups.shared.connection(hostID) {
            connection.retry(notifyFailure: true)
        } else {
            HostGroups.shared.setExpanded(hostID, true, userInitiated: true)
        }
    }
}
