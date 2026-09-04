import AppKit

/// A host-side, always-visible escape hatch while a remote Kero owns the PTY.
/// It lives inside the AppKit terminal surface so it cannot be hidden by pane
/// reconciliation and remains clickable while terminal input is suppressed.
final class RemoteControlBannerView: NSVisualEffectView {
    var onTakeBack: (() -> Void)?
    private var isActive = false
    private var mouseMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true

        let label = NSTextField(labelWithString: String(localized: "Controlled remotely"))
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor

        let button = NSButton(
            title: String(localized: "Take Back Control"),
            target: self,
            action: #selector(takeBack)
        )
        button.bezelStyle = .rounded
        button.controlSize = .small

        let stack = NSStackView(views: [label, button])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
    }

    func activate() {
        isActive = true
        isHidden = false
        installMouseMonitorIfNeeded()
    }

    func deactivate() {
        isActive = false
        isHidden = true
        removeMouseMonitor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMouseMonitor()
        if isActive { installMouseMonitorIfNeeded() }
    }

    /// The Metal-backed terminal renderers own terminal hit testing. A monitor
    /// scoped to the one actively controlled surface keeps the local escape
    /// hatch ahead of them without adding work to ordinary terminal clicks.
    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil, window != nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self else { return event }
            let localPoint = self.convert(event.locationInWindow, from: nil)
            guard self.isActive,
                  event.window === self.window,
                  self.bounds.contains(localPoint)
            else { return event }
            self.takeBack()
            return nil
        }
    }

    private func removeMouseMonitor() {
        guard let mouseMonitor else { return }
        NSEvent.removeMonitor(mouseMonitor)
        self.mouseMonitor = nil
    }

    @objc private func takeBack() {
        onTakeBack?()
    }

    override func mouseDown(with event: NSEvent) {
        takeBack()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

}
