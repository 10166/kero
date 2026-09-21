import AppKit

/// Keeps a disconnected pane in the layout, including any selection and
/// unsaved editor state beside it. It never reconnects as a side effect of focus.
@MainActor
final class SessionConnectionView: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let notice = NSButton(
        title: "New shell — previous tasks were not restarted.  ×", target: nil, action: nil)
    private var restarted = false
    private var connected = false
    func markRestart() { restarted = true }
    @objc private func dismissNotice() {
        restarted = false
        notice.isHidden = true
        if connected { isHidden = true }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if connected { return notice.isHidden ? nil : notice.hitTest(convert(point, to: notice)) }
        return super.hitTest(point)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        notice.target = self
        notice.action = #selector(dismissNotice)
        notice.bezelStyle = .inline
        notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            notice.centerXAnchor.constraint(equalTo: centerXAnchor),
            notice.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -16),
        ])
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
        connected = state == .connected
        layer?.backgroundColor = connected ? NSColor.clear.cgColor : Theme.background.cgColor
        label.isHidden = connected
        notice.isHidden = !connected || !restarted
        isHidden = (connected && !restarted) || state == .exited
        switch state {
        case .disconnected:
            label.stringValue = String(
                localized: "Disconnected\nExpand the host group to resume this terminal.")
        case .connecting: label.stringValue = String(localized: "Connecting…")
        case .failed(let message):
            label.stringValue =
                String(localized: "Connection failed") + "\n" + message + "\n"
                + String(localized: "Collapse and expand the host group to retry.")
        case .connected, .exited: label.stringValue = ""
        }
    }
}
