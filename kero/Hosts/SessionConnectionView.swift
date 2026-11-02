import AppKit

/// Keeps a disconnected pane in the layout, including any selection and
/// unsaved editor state beside it. It never reconnects as a side effect of focus.
@MainActor
final class SessionConnectionView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isHidden { return nil }
        return super.hitTest(point)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(_ state: DaemonTerminalTransport.State) {
        let connected = state == .connected
        layer?.backgroundColor = connected ? NSColor.clear.cgColor : Theme.background.cgColor
        isHidden = connected || state == .exited
        switch state {
        case .disconnected:
            label.stringValue = String(
                localized: "Disconnected\nExpand the host group to resume this terminal.")
        case .connecting: label.stringValue = String(localized: "Connecting…")
        case .failed(let message):
            label.stringValue =
                String(localized: "Connection failed") + "\n" + message + "\n"
                + String(localized: "Retry the SSH host connection from the sidebar.")
        case .connected, .exited: label.stringValue = ""
        }
    }
}
