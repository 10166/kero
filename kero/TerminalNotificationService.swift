//
//  TerminalNotificationService.swift
//  kero
//

import Foundation
import UserNotifications

/// Delivers terminal notification requests through macOS Notification Center.
/// Authorization is intentionally deferred until a terminal first asks to
/// notify, rather than prompting at app launch.
final class TerminalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotificationService()

    private let center = UNUserNotificationCenter.current()
    private let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    private var isRequestingAuthorization = false
    private var pendingMessage: String?

    func configure() {
        center.delegate = self
        // Existing installs may have been authorized for alerts only (before
        // sound support). Re-request so System Settings gains the sound toggle
        // and delivered notifications can play audio — no prompt when already
        // authorized.
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.upgradeSoundAuthorizationIfNeeded(settings)
            }
        }
    }

    func post(message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.checkAuthorization(for: message)
        }
    }

    private func checkAuthorization(for message: String) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.handle(settings, message: message)
            }
        }
    }

    private func handle(_ settings: UNNotificationSettings, message: String) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            if settings.soundSetting == .notSupported {
                // Authorized without sound — upgrade options before delivering.
                requestAuthorization(message: message)
            } else {
                deliver(message)
            }
        case .notDetermined:
            // A terminal can emit OSC 9 repeatedly while the permission sheet
            // is open. Keep only the latest request so an untrusted process
            // cannot grow an unbounded queue or release a banner storm.
            requestAuthorization(message: message)
        case .denied:
            break
        @unknown default:
            break
        }
    }

    /// When already authorized for alerts only, `soundSetting` is
    /// `.notSupported` and Settings hides "Play sound for notifications".
    /// Requesting `.sound` again registers the type without a second prompt.
    private func upgradeSoundAuthorizationIfNeeded(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            guard settings.soundSetting == .notSupported else { return }
            requestAuthorization(message: nil)
        default:
            break
        }
    }

    private func requestAuthorization(message: String?) {
        if let message {
            pendingMessage = message
        }
        guard !isRequestingAuthorization else { return }

        isRequestingAuthorization = true
        center.requestAuthorization(options: authorizationOptions) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRequestingAuthorization = false

                let message = self.pendingMessage
                self.pendingMessage = nil

                if let error {
                    NSLog("Kero: notification authorization failed: %@", String(describing: error))
                }
                if granted, let message {
                    self.deliver(message)
                }
            }
        }
    }

    private func deliver(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Kero"
        content.body = message
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Kero: terminal notification failed: %@", String(describing: error))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
