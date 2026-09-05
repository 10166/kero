import AppKit
import GhosttyTerminal

final class ReplySink: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: RemoteTerminalStateCapture?
    func set(_ capture: RemoteTerminalStateCapture?) { lock.lock(); self.capture = capture; lock.unlock() }
    func receive(_ data: Data) { lock.lock(); let capture = capture; lock.unlock(); capture?.receive(data) }
}

@MainActor
final class TerminalFixture: NSObject, TerminalSurfaceOpenURLDelegate {
    let sink = ReplySink()
    let session: InMemoryTerminalSession
    let controller = TerminalController(configSource: .none)
    let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    let window: NSWindow
    var outputFilter: RemoteOutputFilter?
    var exportPath: String?

    override init() {
        let sink = sink
        session = InMemoryTerminalSession(write: { sink.receive($0) }, resize: { _ in })
        window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        view.delegate = self
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        view.controller = controller
        window.contentView = view
        window.orderFront(nil)
        view.setSurfaceVisible(true)
    }

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) { exportPath = url }

    func reports(after data: Data = Data()) async -> Data {
        let capture = RemoteTerminalStateCapture()
        sink.set(capture)
        defer { sink.set(nil) }
        let reports = await capture.read { session.receive(outputFilter?.receive(data + $0) ?? (data + $0)) }
        precondition(reports != nil, "Ghostty did not complete state queries")
        return reports!
    }

    func screen() throws -> Data {
        exportPath = nil
        precondition(view.performBindingAction("write_screen_file:open,vt"))
        let path = URL(fileURLWithPath: exportPath!)
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        return try Data(contentsOf: path)
    }

    func close() { view.controller = nil; window.orderOut(nil) }
}

@main @MainActor
struct RemoteChecks {
    static func main() {
        _ = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func runChecks() async throws {
        try await RemoteControlService.verifyRefreshFailures()
        for initial in [
            "\u{1b}[?1h\u{1b}[?2004h\u{1b}[10;5HPrompt> ",
            "\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[3;14r\u{1b}[?6h\u{1b}[4;7H\u{1b}[32mTUI\u{1b}[6;9H\u{1b}[4 q",
        ] {
            let host = TerminalFixture()
            let remote = TerminalFixture()
            remote.outputFilter = RemoteOutputFilter()
            defer { host.close(); remote.close() }
            // AppKit publishes backing scale and the first fitted grid on
            // its next display cycle; compare settled, equal viewports.
            try await Task.sleep(for: .milliseconds(250))
            // Kitty's temporary-file transport deletes its source on read.
            // Only a fixture-owned file is exposed to the attack stream.
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("tty-graphics-protocol-\(UUID())")
            try Data([1, 2, 3]).write(to: path)
            defer { try? FileManager.default.removeItem(at: path) }
            let encoded = Data(path.path.utf8).base64EncodedString()
            _ = await remote.reports(after: Data("\u{1b}_Ga=T,t=t,f=24,s=1,v=1;\(encoded)\u{1b}\\".utf8))
            let remaining = try Data(contentsOf: path)
            precondition(remaining == Data([1, 2, 3]), "remote output accessed a controller-local file")
            let hostReports = await host.reports(after: Data(initial.utf8))
            let bootstrap = RemoteTerminalStateCapture.bootstrap(screen: try host.screen(), reports: hostReports)!
            let remoteReports = await remote.reports(after: bootstrap)
            precondition(RemoteTerminalStateCapture.bootstrap(screen: Data(), reports: hostReports)
                == RemoteTerminalStateCapture.bootstrap(screen: Data(), reports: remoteReports), "cursor or terminal modes changed on attachment")
            precondition(host.session.readViewportText() == remote.session.readViewportText(), "bootstrap changed viewport text")
            let next = Data("next\r\n\u{1b}[12;1H\n\n\n".utf8)
            let nextHost = await host.reports(after: next)
            let nextRemote = await remote.reports(after: next)
            precondition(RemoteTerminalStateCapture.bootstrap(screen: Data(), reports: nextHost)
                == RemoteTerminalStateCapture.bootstrap(screen: Data(), reports: nextRemote))
            precondition(host.session.readViewportText() == remote.session.readViewportText(), "subsequent output diverged")
        }
        print("PASS: filtered Ghostty output protects local files and preserves bootstrap state and following output")
    }
}
