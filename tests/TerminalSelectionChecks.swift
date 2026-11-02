import AppKit
@testable import GhosttyTerminal
@testable import kero

final class SelectionInputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        bytes.append(data)
    }

    func take() -> Data {
        lock.lock()
        defer { lock.unlock() }
        let result = bytes
        bytes.removeAll()
        return result
    }
}

@MainActor
final class SelectionFixture {
    let input = SelectionInputSink()
    let view = KeroTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    let controller = TerminalController(configSource: .none, terminalConfiguration: TerminalConfiguration {
        $0.withCustom("mouse-shift-capture", "never")
        $0.withCustom("copy-on-select", "false")
        $0.withCustom("click-repeat-interval", "100")
    })
    let window: NSWindow
    let session: InMemoryTerminalSession

    init() {
        let input = input
        session = InMemoryTerminalSession(write: { input.receive($0) }, resize: { _ in })
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        window.contentView = view
        window.title = "Kero terminal selection checks"
        window.makeKeyAndOrderFront(nil)
        view.setSurfaceVisible(true)
    }

    func event(_ type: NSEvent.EventType, column: Int, row: Int,
               flags: NSEvent.ModifierFlags = [], clickCount: Int = 1, dx: CGFloat = 0) -> NSEvent {
        let size = view.surface!.size()!
        let scale = window.backingScaleFactor
        let point = NSPoint(
            x: (CGFloat(column) + 0.25) * CGFloat(size.cellWidthPixels) / scale + dx,
            y: view.bounds.height - (CGFloat(row) + 0.5) * CGFloat(size.cellHeightPixels) / scale
        )
        return NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1
        )!
    }

    func drag(row: Int, from: Int, to: Int) {
        view.mouseDown(with: event(.leftMouseDown, column: from, row: row))
        view.mouseDragged(with: event(.leftMouseDragged, column: to, row: row))
        view.mouseUp(with: event(.leftMouseUp, column: to, row: row))
    }

    func click(column: Int, row: Int, dx: CGFloat = 0) {
        view.mouseDown(with: event(.leftMouseDown, column: column, row: row, dx: dx))
        view.mouseUp(with: event(.leftMouseUp, column: column, row: row, dx: dx))
    }

    /// Presses and releases one hardware key, like AppKit delivers it.
    func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            )!
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    var selected: String? { view.surface?.readSelection() }

    func close() {
        view.controller = nil
        window.orderOut(nil)
    }
}

@main @MainActor
struct TerminalSelectionChecks {
    static func main() {
        _ = NSApplication.shared
        // A bare executable defaults to .prohibited, whose windows can never be key.
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await runChecks()
            exit(0)
        }
        NSApp.run()
    }

    /// Bytes the program receives for one key, once the async PTY write lands.
    static func keyBytes(_ fixture: SelectionFixture, _ code: UInt16, _ characters: String,
                         flags: NSEvent.ModifierFlags) async -> String {
        fixture.key(code, characters, flags: flags)
        try! await Task.sleep(for: .milliseconds(40))
        return String(decoding: fixture.input.take(), as: UTF8.self)
    }

    static func runChecks() async {
        let fixture = SelectionFixture()
        defer { fixture.close() }
        try! await Task.sleep(for: .milliseconds(300))
        fixture.window.makeFirstResponder(fixture.view)

        // Unmodified navigation keys must go through Ghostty's encoder so they
        // follow DECCKM, like the stock app. (name, key code, characters, normal, application)
        let fn: NSEvent.ModifierFlags = .function
        let keys: [(String, UInt16, String, NSEvent.ModifierFlags, String, String)] = [
            ("Up", 0x7E, "\u{F700}", [fn, .numericPad], "\u{1b}[A", "\u{1b}OA"),
            ("Down", 0x7D, "\u{F701}", [fn, .numericPad], "\u{1b}[B", "\u{1b}OB"),
            ("Left", 0x7B, "\u{F702}", [fn, .numericPad], "\u{1b}[D", "\u{1b}OD"),
            ("Right", 0x7C, "\u{F703}", [fn, .numericPad], "\u{1b}[C", "\u{1b}OC"),
            ("Home", 0x73, "\u{F729}", fn, "\u{1b}[H", "\u{1b}OH"),
            ("End", 0x77, "\u{F72B}", fn, "\u{1b}[F", "\u{1b}OF"),
            ("PageUp", 0x74, "\u{F72C}", fn, "\u{1b}[5~", "\u{1b}[5~"),
            ("PageDown", 0x79, "\u{F72D}", fn, "\u{1b}[6~", "\u{1b}[6~"),
            ("Delete", 0x75, "\u{F728}", fn, "\u{1b}[3~", "\u{1b}[3~"),
            ("Backspace", 0x33, "\u{7F}", [], "\u{7F}", "\u{7F}"),
            ("Tab", 0x30, "\t", [], "\t", "\t"),
        ]
        for application in [false, true] {
            fixture.session.receive(Data((application ? "\u{1b}[?1h" : "\u{1b}[?1l").utf8))
            try! await Task.sleep(for: .milliseconds(100))
            _ = fixture.input.take()
            for (name, code, characters, flags, normal, applicationBytes) in keys {
                let got = await keyBytes(fixture, code, characters, flags: flags)
                let want = application ? applicationBytes : normal
                precondition(got == want, "\(name) in \(application ? "application" : "normal") cursor mode sent \(got.debugDescription), expected \(want.debugDescription)")
            }
        }
        fixture.session.receive(Data("\u{1b}[?1l".utf8))
        print("PASS: navigation keys are encoded by Ghostty and follow application cursor mode")

        fixture.session.receive(Data((
            "\u{1b}[2J\u{1b}[HFIRST-ANCHOR\r\nSECOND-TARGET\r\nTHIRD-LINE"
            + "\u{1b}[?1002h\u{1b}[?1006h"
        ).utf8))
        try! await Task.sleep(for: .milliseconds(200))
        precondition(fixture.view.isMouseCapturedByProgram, "fixture did not enable TUI mouse capture")
        _ = fixture.input.take()

        fixture.drag(row: 0, from: 0, to: 5)
        precondition(fixture.selected == "FIRST", "first drag selected the wrong text")
        fixture.view.mouseMoved(with: fixture.event(.mouseMoved, column: 9, row: 2))
        precondition(fixture.selected == "FIRST", "selection continued moving after mouse-up")
        // Cross the click interval: synthetic Shift presses used to resume the
        // previous anchor only once Ghostty no longer treated them as a multi-click.
        try! await Task.sleep(for: .milliseconds(150))
        fixture.drag(row: 1, from: 0, to: 6)
        precondition(fixture.selected == "SECOND", "second drag extended the previous selection")
        try! await Task.sleep(for: .milliseconds(150))
        precondition(fixture.input.take().isEmpty, "native selection leaked mouse events to the TUI")
        print("PASS: release ends selection; the next plain drag starts a fresh anchor without TUI mouse reports")

        fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 9, row: 1, flags: .shift))
        fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 9, row: 1, flags: .shift))
        precondition(fixture.selected == "SECOND-TA", "explicit Shift-click no longer extends the selection")
        try! await Task.sleep(for: .milliseconds(150))
        precondition(fixture.input.take().isEmpty, "Shift selection leaked mouse events to the TUI")
        print("PASS: explicit Shift-click still extends an existing selection")

        fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 0, row: 2))
        fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 0, row: 2))
        try! await Task.sleep(for: .milliseconds(100))
        precondition(!fixture.view.hasSelection, "plain TUI click did not clear the selection")
        let expected = Data("\u{1b}[<0;1;3M\u{1b}[<0;1;3m".utf8)
        precondition(fixture.input.take() == expected, "plain click did not report its press and release to the TUI")
        print("PASS: plain clicks still reach the TUI after native selection")

        // A TUI detects double-clicks itself (e.g. to expand a block), so both
        // presses must reach it rather than being taken for native word selection.
        for count in 1...2 {
            fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 0, row: 0, clickCount: count))
            fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 0, row: 0, clickCount: count))
        }
        try! await Task.sleep(for: .milliseconds(100))
        precondition(!fixture.view.hasSelection, "double-click selected a word instead of reaching the TUI")
        let pair = "\u{1b}[<0;1;1M\u{1b}[<0;1;1m"
        precondition(fixture.input.take() == Data((pair + pair).utf8), "double-click did not report both clicks to the TUI")
        print("PASS: double-clicks reach the TUI as two clicks")

        // Shift is the native bypass, matching Ghostty: it selects the word.
        fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 2, row: 1, flags: .shift, clickCount: 1))
        fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 2, row: 1, flags: .shift, clickCount: 1))
        fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 2, row: 1, flags: .shift, clickCount: 2))
        fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 2, row: 1, flags: .shift, clickCount: 2))
        try! await Task.sleep(for: .milliseconds(100))
        precondition(fixture.selected == "SECOND-TARGET", "Shift-double-click did not select the word natively")
        precondition(fixture.input.take().isEmpty, "Shift-double-click leaked mouse events to the TUI")
        print("PASS: Shift-double-click selects a word natively")

        // A trackpad click wobbles a pixel or two. That is still a click for the
        // program, not the start of a selection drag.
        fixture.view.mouseDown(with: fixture.event(.leftMouseDown, column: 0, row: 0))
        fixture.view.mouseDragged(with: fixture.event(.leftMouseDragged, column: 0, row: 0, dx: 2))
        fixture.view.mouseUp(with: fixture.event(.leftMouseUp, column: 0, row: 0, dx: 2))
        try! await Task.sleep(for: .milliseconds(100))
        precondition(!fixture.view.hasSelection, "a click with finger jitter started a selection")
        precondition(fixture.input.take() == Data(pair.utf8), "a click with finger jitter was not reported to the TUI")
        print("PASS: a click with sub-threshold jitter still reaches the TUI")

        // Clicking a pane to focus it must not also press a button in the program.
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        try! await Task.sleep(for: .milliseconds(300))
        if fixture.window.isKeyWindow {
            fixture.window.makeFirstResponder(nil)
            fixture.click(column: 0, row: 2)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(fixture.window.firstResponder === fixture.view, "the click did not focus the pane")
            precondition(fixture.input.take().isEmpty, "a click that only focused the pane reached the TUI")
            fixture.click(column: 0, row: 2)
            try! await Task.sleep(for: .milliseconds(100))
            precondition(fixture.input.take() == expected, "a click on the focused pane did not reach the TUI")
            // The focusing press can still start a selection drag.
            fixture.window.makeFirstResponder(nil)
            try! await Task.sleep(for: .milliseconds(150))
            fixture.drag(row: 0, from: 0, to: 5)
            precondition(fixture.selected == "FIRST", "dragging from an unfocused pane did not select")
            precondition(fixture.input.take().isEmpty, "dragging from an unfocused pane reached the TUI")
            print("PASS: a click that only focuses the pane stays out of the TUI, but its drag still selects")
        } else {
            print("SKIP: the window never became key, so the focus-only click check did not run")
        }

        // A program that captured the mouse owns right-click, even over a selection.
        try! await Task.sleep(for: .milliseconds(150))
        fixture.drag(row: 1, from: 0, to: 6)
        precondition(fixture.view.hasSelection, "fixture lost its selection")
        _ = fixture.input.take()
        fixture.view.rightMouseDown(with: fixture.event(.rightMouseDown, column: 3, row: 1))
        fixture.view.rightMouseUp(with: fixture.event(.rightMouseUp, column: 3, row: 1))
        try! await Task.sleep(for: .milliseconds(100))
        precondition(
            fixture.input.take() == Data("\u{1b}[<2;4;2M\u{1b}[<2;4;2m".utf8),
            "right-click did not reach the TUI"
        )
        print("PASS: right-click reaches a program that captured the mouse")
    }
}
