import Foundation

/// Queries the host-managed Ghostty emulator only while PTY delivery is
/// paused. Replies are intercepted by the adapter and never reach the shell.
/// This avoids running a second emulator during ordinary local terminal use.
nonisolated final class RemoteTerminalStateCapture: @unchecked Sendable {
    private let lock = NSLock()
    // Ghostty reserves the high bit of its 16-bit mode identifier for ANSI
    // versus DEC modes. Stay below it so the reported identifier round trips.
    private let marker = Int.random(in: 20_000...30_000)
    private var bytes = Data()
    private var continuation: CheckedContinuation<Data?, Never>?
    private var finished = false

    static let privateModes = [1, 6, 7, 25, 47, 66, 1047, 1049, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 2004]

    func read(send: (Data) -> Void) async -> Data? {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
            self.continuation = continuation
            lock.unlock()
            let modes = Self.privateModes.map { "\u{1b}[?\($0)$p" }.joined()
            // An unsupported private mode has a deterministic DECRPM reply.
            // It fences all earlier replies without changing emulator state.
            send(Data((modes + "\u{1b}[4$p\u{1b}[20$p"
                + "\u{1b}P$qm\u{1b}\\\u{1b}P$qr\u{1b}\\\u{1b}P$q q\u{1b}\\"
                + "\u{1b}[?u\u{1b}[6n\u{1b}[?\(marker)$p").utf8))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.finish(nil)
            }
        }
    }

    func receive(_ data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        bytes.append(data)
        let complete = bytes.range(of: Data("\u{1b}[?\(marker);0$y".utf8)) != nil
        let overflow = bytes.count > 64 * 1024
        let result = bytes
        lock.unlock()
        if complete || overflow { finish(overflow ? nil : result) }
    }

    func cancel() { finish(nil) }

    private func finish(_ data: Data?) {
        lock.lock()
        finished = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: data)
    }

    /// Translate reports into setters. A screen export is drawn with reset
    /// modes, then the live margins, input modes, style and cursor are restored.
    static func bootstrap(screen: Data, reports: Data) -> Data? {
        let text = String(decoding: reports, as: UTF8.self)
        func matches(_ pattern: String) -> [[String]] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let string = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: string.length)).map { match in
                (1..<match.numberOfRanges).map { string.substring(with: match.range(at: $0)) }
            }
        }
        guard let cursor = matches("\u{1b}\\[([0-9]+);([0-9]+)R").last else { return nil }
        var modes: [Int: Bool] = [:]
        for match in matches("\u{1b}\\[\\?([0-9]+);([1-4])\\$y") {
            if let mode = Int(match[0]) { modes[mode] = match[1] == "1" || match[1] == "3" }
        }
        // Missing essential reports cannot safely seed an interactive client.
        guard modes[1] != nil, modes[6] != nil, modes[2004] != nil else { return nil }
        var result = Data("\u{1b}c".utf8)
        if [47, 1047, 1049].contains(where: { modes[$0] == true }) {
            result.append(Data("\u{1b}[?1049h".utf8))
        }
        var screen = screen
        if screen.suffix(2) == Data("\r\n".utf8) { screen.removeLast(2) }
        else if screen.last == 10 { screen.removeLast() }
        result.append(screen)
        var suffix = ""
        for match in matches("\u{1b}P1\\$r([^\u{1b}]+)\u{1b}\\\\") {
            // Only the requested SGR, margins, and cursor-style reports.
            if match[0].hasSuffix("m") || match[0].hasSuffix("r") || match[0].hasSuffix(" q") {
                suffix += "\u{1b}[" + match[0]
            }
        }
        for mode in Self.privateModes where ![47, 1047, 1049].contains(mode) {
            if let enabled = modes[mode] { suffix += "\u{1b}[?\(mode)\(enabled ? "h" : "l")" }
        }
        for match in matches("\u{1b}\\[(4|20);([1-4])\\$y") {
            suffix += "\u{1b}[\(match[0])\(match[1] == "1" || match[1] == "3" ? "h" : "l")"
        }
        if let keyboard = matches("\u{1b}\\[\\?([0-9]+)u").last {
            suffix += "\u{1b}[=\(keyboard[0])u"
        }
        suffix += "\u{1b}[\(cursor[0]);\(cursor[1])H"
        result.append(Data(suffix.utf8))
        return result
    }
}
