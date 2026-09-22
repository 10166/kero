import AppKit

/// SSH host modals can be requested from short-lived connection tasks while a
/// configuration sheet is closing. Presenting directly from `NSApp.keyWindow`
/// can therefore attach a new sheet to the sheet that is being dismissed and
/// strand AppKit's dimming view. This queue gives every physical window one
/// modal lane and resolves sheet anchors back to that window.
@MainActor
final class SheetPresenter {
    static let shared = SheetPresenter()

    private struct Request {
        let run: (NSWindow, @escaping () -> Void) -> Void
    }

    private var queues: [ObjectIdentifier: [Request]] = [:]
    private var isPresenting: [ObjectIdentifier: Bool] = [:]
    private var dismissCompletions: [ObjectIdentifier: [() -> Void]] = [:]

    private init() {}

    func present(
        _ controller: NSViewController,
        title: String,
        on preferredWindow: NSWindow?,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        enqueue(on: preferredWindow) { window, finish in
            let sheet = NSWindow(
                contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.title = title
            sheet.contentViewController = controller
            window.beginSheet(sheet) { response in
                // Break the window/controller cycle only after AppKit has
                // fully ended the sheet and removed its dimming view.
                sheet.contentViewController = nil
                self.completeDismissal(of: sheet)
                completion?(response)
                finish()
            }
        }
    }

    func present(
        _ alert: NSAlert,
        on preferredWindow: NSWindow?,
        completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        enqueue(on: preferredWindow) { window, finish in
            alert.beginSheetModal(for: window) { response in
                completion?(response)
                finish()
            }
        }
    }

    func dismiss(_ sheet: NSWindow?, completion: @escaping () -> Void) {
        guard let sheet, let parent = sheet.sheetParent else {
            completion()
            return
        }

        // `NSWindow.endSheet` has no completion handler. Register with the
        // presenting lane, whose own `beginSheet` completion is the reliable
        // signal that the sheet has ended and its dimming view is going away.
        dismissCompletions[ObjectIdentifier(sheet), default: []].append(completion)
        parent.endSheet(sheet)
    }

    private func completeDismissal(of sheet: NSWindow) {
        let completions = dismissCompletions.removeValue(forKey: ObjectIdentifier(sheet)) ?? []
        completions.forEach { $0() }
    }

    private func enqueue(
        on preferredWindow: NSWindow?,
        run: @escaping (NSWindow, @escaping () -> Void) -> Void
    ) {
        guard let window = anchor(from: preferredWindow) else { return }
        let key = ObjectIdentifier(window)
        queues[key, default: []].append(Request(run: run))
        drain(window)
    }

    private func anchor(from preferredWindow: NSWindow?) -> NSWindow? {
        var window =
            preferredWindow
            ?? NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first

        // A request made while a sheet is closing (or from that sheet itself)
        // still belongs to the physical window underneath it.
        while let parent = window?.sheetParent { window = parent }
        guard let window, window.isVisible else { return nil }
        return window
    }

    private func drain(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        guard isPresenting[key] != true, let request = queues[key]?.first else { return }

        isPresenting[key] = true
        request.run(window) { [weak self, weak window] in
            guard let self, let window else { return }
            let windowKey = ObjectIdentifier(window)
            self.queues[windowKey]?.removeFirst()
            if self.queues[windowKey]?.isEmpty == true {
                self.queues.removeValue(forKey: windowKey)
            }

            // Defer the next lane until AppKit has restored the parent window's
            // key status and torn down the previous sheet's visual state.
            Task { @MainActor [weak self, weak window] in
                guard let self, let window else { return }
                self.isPresenting[ObjectIdentifier(window)] = false
                self.drain(window)
            }
        }
    }
}
