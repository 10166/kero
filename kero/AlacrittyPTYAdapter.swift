import AppKit
import Foundation
import GhosttyTerminal

/// Owns a real PTY while a host-managed terminal surface performs rendering
/// and terminal protocol responses. The Alacritty bridge already contains the
/// battle-tested macOS PTY launcher and poll loop; suppressing its parser's
/// automatic replies makes this handle a byte-transparent transport.
nonisolated final class AlacrittyPTYAdapter: @unchecked Sendable {
    private let lock = NSLock()
    private let token: UInt64
    private var handle: OpaquePointer?
    private var outputHandler: (@Sendable (Data, Bool) -> Void)?
    private var exitHandler: (@Sendable () -> Void)?
    private var pendingOutput: [Data] = []
    private var pendingExit = false
    private var remotelyControlled = false
    private var snapshotCapture: RemoteTerminalStateCapture?
    private var pausedOutput: [Data] = []
    private var pausedBytes = 0
    private var lastLocalViewport = InMemoryTerminalViewport(
        columns: 80,
        rows: 24,
        widthPixels: 640,
        heightPixels: 384,
        cellWidthPixels: 8,
        cellHeightPixels: 16
    )

    @MainActor
    init?(launch: TerminalLaunch) {
        token = AlacrittyPTYRegistry.shared.nextToken()
        AlacrittyPTYRegistry.shared.register(self, for: token)
        var theme = AlacrittyTheme.current()
        handle = launch.withCConfig(
            columns: 80,
            rows: 24,
            cellWidth: 8,
            cellHeight: 16,
            scrollbackLines: 1,
            cursorShape: 0,
            cursorBlinking: false,
            suppressProtocolWrites: true
        ) { config in
            withUnsafePointer(to: &theme) { themePointer in
                kero_alacritty_new(
                    config,
                    themePointer,
                    alacrittyPTYEventCallback,
                    UnsafeMutableRawPointer(bitPattern: UInt(token))
                )
            }
        }
        guard handle != nil else {
            AlacrittyPTYRegistry.shared.unregister(token)
            return nil
        }
    }

    deinit {
        detach()
    }

    var foregroundPid: pid_t? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        let pid = kero_alacritty_foreground_pid(handle)
        return pid > 0 ? pid : nil
    }

    func setHandlers(
        output: @escaping @Sendable (Data, Bool) -> Void,
        exit: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        outputHandler = output
        exitHandler = exit
        let queued = pendingOutput
        let exited = pendingExit
        pendingOutput.removeAll(keepingCapacity: false)
        pendingExit = false
        queued.forEach { output($0, false) }
        if exited { exit() }
        lock.unlock()
    }

    func writeFromSurface(_ data: Data) {
        lock.lock()
        if let snapshotCapture {
            lock.unlock()
            snapshotCapture.receive(data)
            return
        }
        guard !remotelyControlled, let handle, !data.isEmpty else {
            lock.unlock()
            return
        }
        write(data, to: handle)
        lock.unlock()
    }

    func writeFromRemote(_ data: Data) {
        lock.lock()
        guard remotelyControlled, let handle, !data.isEmpty else {
            lock.unlock()
            return
        }
        write(data, to: handle)
        lock.unlock()
    }

    func resizeFromSurface(_ viewport: InMemoryTerminalViewport) {
        lock.lock()
        lastLocalViewport = viewport
        guard !remotelyControlled, let handle else {
            lock.unlock()
            return
        }
        resize(viewport, handle: handle)
        lock.unlock()
    }

    func beginRemoteControl(_ resize: RemoteResize) {
        lock.lock()
        remotelyControlled = true
        guard let handle else {
            lock.unlock()
            return
        }
        kero_alacritty_resize(
            handle,
            resize.columns,
            resize.rows,
            resize.cellWidth,
            resize.cellHeight
        )
        lock.unlock()
    }

    func endRemoteControl() {
        lock.lock()
        snapshotCapture?.cancel()
        remotelyControlled = false
        if let handle { resize(lastLocalViewport, handle: handle) }
        lock.unlock()
    }

    func detach() {
        lock.lock()
        guard let handle else {
            lock.unlock()
            return
        }
        self.handle = nil
        snapshotCapture?.cancel()
        outputHandler = nil
        exitHandler = nil
        lock.unlock()
        AlacrittyPTYRegistry.shared.unregister(token)
        kero_alacritty_free(handle)
    }

    fileprivate func receive(kind: UInt32, data: Data) {
        lock.lock()
        if kind == KERO_EVENT_RAW_OUTPUT {
            if let snapshotCapture {
                pausedOutput.append(data)
                pausedBytes += data.count
                if pausedBytes > 8 * 1024 * 1024 { snapshotCapture.cancel() }
                lock.unlock()
            } else if let outputHandler {
                let forwardRemotely = remotelyControlled
                // Enqueuing Ghostty output under this lock makes pausing a
                // real boundary; an earlier callback cannot overtake queries.
                outputHandler(data, forwardRemotely)
                lock.unlock()
            } else {
                if pendingOutput.count < 128 { pendingOutput.append(data) }
                lock.unlock()
            }
        } else if kind == KERO_EVENT_EXIT {
            if let exitHandler {
                lock.unlock()
                exitHandler()
            } else {
                pendingExit = true
                lock.unlock()
            }
        } else {
            lock.unlock()
        }
    }

    func beginSnapshotCapture(_ capture: RemoteTerminalStateCapture) {
        lock.lock()
        snapshotCapture = capture
        lock.unlock()
    }

    func endSnapshotCapture(_ capture: RemoteTerminalStateCapture) {
        lock.lock()
        defer { lock.unlock() }
        guard snapshotCapture === capture else { return }
        snapshotCapture = nil
        let queued = pausedOutput
        pausedOutput.removeAll(keepingCapacity: false)
        pausedBytes = 0
        queued.forEach { outputHandler?($0, remotelyControlled) }
    }

    private func write(_ data: Data, to handle: OpaquePointer) {
        data.withUnsafeBytes { bytes in
            kero_alacritty_write(
                handle,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count
            )
        }
    }

    private func resize(_ viewport: InMemoryTerminalViewport, handle: OpaquePointer) {
        kero_alacritty_resize(
            handle,
            viewport.columns,
            viewport.rows,
            UInt16(clamping: viewport.cellWidthPixels),
            UInt16(clamping: viewport.cellHeightPixels)
        )
    }
}

private nonisolated final class AlacrittyPTYRegistry: @unchecked Sendable {
    static let shared = AlacrittyPTYRegistry()

    private let lock = NSLock()
    private var next: UInt64 = 1 << 48
    private var adapters: [UInt64: WeakAdapter] = [:]

    private struct WeakAdapter {
        weak var value: AlacrittyPTYAdapter?
    }

    func nextToken() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = next
        next &+= 1
        return value
    }

    func register(_ adapter: AlacrittyPTYAdapter, for token: UInt64) {
        lock.lock()
        adapters[token] = WeakAdapter(value: adapter)
        lock.unlock()
    }

    func unregister(_ token: UInt64) {
        lock.lock()
        adapters[token] = nil
        lock.unlock()
    }

    func deliver(token: UInt64, kind: UInt32, data: Data) {
        lock.lock()
        let adapter = adapters[token]?.value
        lock.unlock()
        adapter?.receive(kind: kind, data: data)
    }
}

private nonisolated func alacrittyPTYEventCallback(
    context: UnsafeMutableRawPointer?,
    kind: UInt32,
    data: UnsafePointer<UInt8>?,
    length: Int
) {
    let token = UInt64(UInt(bitPattern: context))
    guard token != 0 else { return }
    let payload = data.map { Data(bytes: $0, count: length) } ?? Data()
    AlacrittyPTYRegistry.shared.deliver(token: token, kind: kind, data: payload)
}
