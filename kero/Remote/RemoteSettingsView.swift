import AppKit
import Combine
import SwiftUI

struct RemoteSettingsRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoteSettingsView {
        RemoteSettingsView()
    }

    func updateNSView(_ view: RemoteSettingsView, context: Context) {
        view.reload()
    }
}

@MainActor
final class RemoteSettingsView: NSView, NSTextFieldDelegate {
    private let relayField = NSTextField()
    private let accountButton = NSButton()
    private let hostToggle = NSButton(
        checkboxWithTitle: String(localized: "Allow remote control on this Mac"),
        target: nil,
        action: nil
    )
    private let stateLabel = NSTextField(labelWithString: "")
    private let devicesButton = NSPopUpButton()
    private var observations = Set<AnyCancellable>()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let relayLabel = NSTextField(labelWithString: String(localized: "Relay URL"))
        relayField.placeholderString = "https://relay.example.com"
        relayField.delegate = self
        relayField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        accountButton.bezelStyle = .rounded
        accountButton.target = self
        accountButton.action = #selector(toggleAccount)

        hostToggle.target = self
        hostToggle.action = #selector(toggleHosting)

        stateLabel.textColor = .secondaryLabelColor
        stateLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stateLabel.lineBreakMode = .byTruncatingTail

        devicesButton.target = self
        devicesButton.action = #selector(deviceAction)

        let relayRow = NSStackView(views: [relayLabel, relayField])
        relayRow.orientation = .horizontal
        relayRow.spacing = 12
        relayLabel.setContentHuggingPriority(.required, for: .horizontal)

        let accountRow = NSStackView(views: [accountButton, devicesButton])
        accountRow.orientation = .horizontal
        accountRow.spacing = 8

        let stack = NSStackView(views: [relayRow, accountRow, hostToggle, stateLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            relayRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        RemoteControlService.shared.$state
            .combineLatest(RemoteControlService.shared.$devices)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &observations)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reload() {
        let service = RemoteControlService.shared
        if relayField.currentEditor() == nil {
            relayField.stringValue = AppSettings.shared.remoteRelayURL
        }
        accountButton.title = service.isSignedIn
            ? String(localized: "Sign Out")
            : String(localized: "Sign in with Google")
        accountButton.isEnabled = service.state != .connecting
        hostToggle.state = AppSettings.shared.remoteHostEnabled ? .on : .off
        hostToggle.isEnabled = service.isSignedIn

        switch service.state {
        case .signedOut:
            stateLabel.stringValue = String(localized: "Signed out")
        case .connecting:
            stateLabel.stringValue = String(localized: "Connecting…")
        case .connected:
            stateLabel.stringValue = String(localized: "Connected with end-to-end encryption")
        case .failed(let message):
            stateLabel.stringValue = message
        }

        devicesButton.removeAllItems()
        devicesButton.addItem(withTitle: String(localized: "Manage Devices"))
        devicesButton.menu?.addItem(.separator())
        let localID = service.localDeviceID
        for device in service.devices {
            let suffix = device.id.uuidString.prefix(8)
            let title = device.id == localID
                ? String(localized: "This Mac") + " · \(suffix)"
                : String(localized: "Revoke") + " · \(suffix)"
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = device.id.uuidString
            item.isEnabled = device.id != localID
            devicesButton.menu?.addItem(item)
        }
        devicesButton.isHidden = !service.isSignedIn
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        AppSettings.shared.remoteRelayURL = relayField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func toggleAccount() {
        let service = RemoteControlService.shared
        if service.isSignedIn {
            service.signOut()
        } else {
            window?.makeFirstResponder(nil)
            Task { await service.signIn() }
        }
    }

    @objc private func toggleHosting() {
        AppSettings.shared.remoteHostEnabled = hostToggle.state == .on
    }

    @objc private func deviceAction() {
        guard devicesButton.indexOfSelectedItem > 0,
              let rawID = devicesButton.selectedItem?.representedObject as? String,
              let id = UUID(uuidString: rawID),
              let device = RemoteControlService.shared.devices.first(where: { $0.id == id })
        else { return }
        Task { await RemoteControlService.shared.revoke(device) }
    }
}
