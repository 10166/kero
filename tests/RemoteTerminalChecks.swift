import AppKit
import GhosttyTerminal

final class ReplySink: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: RemoteTerminalStateCapture?
    private var dimensions = InMemoryTerminalViewport(columns:80,rows:24)
    func resize(_ size: InMemoryTerminalViewport) { lock.lock(); dimensions=size; lock.unlock() }
    func viewport() -> InMemoryTerminalViewport { lock.lock(); defer { lock.unlock() }; return dimensions }
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
        session = InMemoryTerminalSession(write: { sink.receive($0) }, resize: { sink.resize($0) })
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

    static func verifyDaemonCheckpoints() async throws {
        guard let executable=ProcessInfo.processInfo.environment["KERO_CHECKPOINT_FIXTURE"] else {
            throw NSError(domain:"checks",code:1,userInfo:[NSLocalizedDescriptionKey:"KERO_CHECKPOINT_FIXTURE is required"])
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("kero-checkpoints-\(UUID())")
        defer { try? FileManager.default.removeItem(at:directory) }
        let host=TerminalFixture(), restored=TerminalFixture()
        defer {host.close();restored.close()}
        try await Task.sleep(for:.milliseconds(300))
        let size=host.sink.viewport()
        let process=Process();process.executableURL=URL(fileURLWithPath:executable)
        process.arguments=[String(size.columns),String(size.rows),directory.path]
        try process.run();process.waitUntilExit();precondition(process.terminationStatus==0)
        let names=try JSONDecoder().decode([String].self,from:Data(contentsOf:directory.appendingPathComponent("names.json")))
        for name in names {
            let initial=try Data(contentsOf:directory.appendingPathComponent(name+".initial"))
            let checkpoint=try Data(contentsOf:directory.appendingPathComponent(name+".checkpoint"))
            let next=try Data(contentsOf:directory.appendingPathComponent(name+".next"))
            host.session.receive(Data("\u{1b}c".utf8)+initial+next)
            restored.session.receive(checkpoint+next)
            let originalReports=await host.reports(), restoredReports=await restored.reports()
            if host.session.readViewportText() != restored.session.readViewportText() {
                FileHandle.standardError.write(Data("Ghostty text original \(name): \(host.session.readViewportText().debugDescription)\nrestored: \(restored.session.readViewportText().debugDescription)\n".utf8))
                throw NSError(domain:"checkpoint-text",code:1)
            }
            if RemoteTerminalStateCapture.bootstrap(screen:Data(),reports:originalReports) != RemoteTerminalStateCapture.bootstrap(screen:Data(),reports:restoredReports) {
                FileHandle.standardError.write(Data("Ghostty original \(name): \(String(decoding:originalReports,as:UTF8.self).debugDescription)\nrestored: \(String(decoding:restoredReports,as:UTF8.self).debugDescription)\n".utf8))
                throw NSError(domain:"checkpoint",code:1)
            }
            verifyAlacrittyCheckpoint(initial:initial,checkpoint:checkpoint,next:next,columns:size.columns,rows:size.rows,name:name)
            print("PASS: canonical checkpoint in Ghostty + Alacritty: \(name)")
        }
    }

    static func verifyAlacrittyCheckpoint(initial:Data,checkpoint:Data,next:Data,columns:UInt16,rows:UInt16,name:String) {
        var config=KeroConfig();config.columns=columns;config.rows=rows;config.cell_width=8;config.cell_height=16
        config.scrollback_lines=10000;config.suppress_protocol_writes=true
        var theme=KeroTheme();theme.foreground=0xffffff
        let original=kero_alacritty_new_remote(&config,&theme,{_,_,_,_ in},nil)!
        let restored=kero_alacritty_new_remote(&config,&theme,{_,_,_,_ in},nil)!
        defer {kero_alacritty_free(original);kero_alacritty_free(restored)}
        func feed(_ handle:OpaquePointer,_ data:Data) {data.withUnsafeBytes { kero_alacritty_feed(handle,$0.bindMemory(to:UInt8.self).baseAddress,$0.count) }}
        feed(original,initial+next);feed(restored,checkpoint+next)
        var left=KeroSnapshot(),right=KeroSnapshot()
        kero_alacritty_snapshot(original,&left);kero_alacritty_snapshot(restored,&right)
        precondition(left.columns==right.columns && left.rows==right.rows,"Alacritty dimensions: \(name)")
        for index in 0..<(left.columns*left.rows) {
            let a=left.cells![index],b=right.cells![index]
            precondition(a.ch==b.ch && a.fg==b.fg && a.bg==b.bg && a.flags==b.flags,"Alacritty checkpoint cells: \(name) cell \(index)")
        }
        precondition(left.cursor_line==right.cursor_line && left.cursor_column==right.cursor_column,"Alacritty cursor: \(name)")
        precondition(kero_alacritty_mode(original)==kero_alacritty_mode(restored),"Alacritty modes: \(name)")
        var leftImages=KeroKittySnapshot(), rightImages=KeroKittySnapshot()
        kero_alacritty_kitty_snapshot(original,&leftImages);kero_alacritty_kitty_snapshot(restored,&rightImages)
        precondition(leftImages.placements_len==rightImages.placements_len,"Alacritty image count: \(name)")
        for index in 0..<leftImages.placements_len {
            let a=leftImages.placements![index], b=rightImages.placements![index]
            precondition(a.image_id==b.image_id && a.placement_id==b.placement_id && a.viewport_row==b.viewport_row && a.column==b.column && a.display_columns==b.display_columns && a.display_rows==b.display_rows && a.source_x==b.source_x && a.source_y==b.source_y && a.source_width==b.source_width && a.source_height==b.source_height && a.z_index==b.z_index,"Alacritty image placement: \(name)")
            precondition(Data(bytes:a.png!,count:a.png_len)==Data(bytes:b.png!,count:b.png_len),"Alacritty image pixels: \(name)")
        }
        // A reconnect must also discard an interrupted old renderer parser.
        feed(restored,Data("\u{1b}]unfinished".utf8));kero_alacritty_reset_remote(restored)
        feed(restored,checkpoint+next);kero_alacritty_snapshot(restored,&right)
        for index in 0..<(left.columns*left.rows) {precondition(left.cells![index].ch==right.cells![index].ch,"Alacritty parser reset: \(name)")}
    }

    static func runChecks() async throws {
        try await RemoteControlService.verifyRefreshFailures()
        try await verifyDaemonCheckpoints()
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
