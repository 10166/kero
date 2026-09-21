import Darwin
import Foundation

/// Blocking socket work runs off the main actor. A distinct read descriptor
/// lets cancellation interrupt recv without racing descriptor reuse.
nonisolated final class DaemonWire: @unchecked Sendable {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var descriptor: Int32
    private let reader: Int32
    private let writeQueue = DispatchQueue(label: "sh.kero.daemon.write")
    private var queuedBytes = 0
    static let maximumFrame = 8 * 1024 * 1024

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw Failure("Daemon socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        var enabled: Int32 = 1
        setsockopt(
            fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        descriptor = fd
        reader = dup(fd)
        guard reader >= 0 else {
            Darwin.close(fd)
            throw POSIXError(.EMFILE)
        }
    }
    deinit {
        close()
        Darwin.close(reader)
    }
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { return }
        shutdown(descriptor, SHUT_RDWR)
        Darwin.close(descriptor)
        descriptor = -1
    }
    func setReadTimeout(_ seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(
            reader, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    func readFrame() throws -> (UInt8, Data) {
        let header = try readExactly(5)
        let count = header.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
        guard count <= Self.maximumFrame else { throw Failure("Daemon frame exceeds the limit") }
        return (header[4], try readExactly(count))
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                let read = Darwin.read(reader, buffer.baseAddress!.advanced(by: offset), count - offset)
                if read < 0 && errno == EINTR { continue }
                guard read > 0 else { throw Failure("Daemon connection closed") }
                offset += read
            }
        }
        return data
    }
    func request(_ object: [String: Any]) throws {
        try writeFrame(1, JSONSerialization.data(withJSONObject: object))
    }
    func event() throws -> [String: Any] {
        let (kind, data) = try readFrame()
        guard kind == 1, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure("Unexpected daemon reply") }
        if value["event"] as? String == "error" {
            throw Failure(value["message"] as? String ?? "Daemon request failed")
        }
        return value
    }
    func enqueue(_ kind: UInt8, _ data: Data) {
        lock.lock()
        let allowed = descriptor >= 0 && queuedBytes + data.count <= 1024 * 1024
        if allowed { queuedBytes += data.count }
        lock.unlock()
        guard allowed else {
            close()
            return
        }
        writeQueue.async { [self] in
            do { try writeFrame(kind, data) } catch { close() }
            lock.lock()
            queuedBytes -= data.count
            lock.unlock()
        }
    }
    func enqueue(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        enqueue(1, data)
    }
    func writeFrame(_ kind: UInt8, _ payload: Data) throws {
        guard payload.count <= Self.maximumFrame else {
            throw Failure("Daemon frame exceeds the limit")
        }
        var count = UInt32(payload.count).littleEndian
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(kind)
        data.append(payload)
        writeLock.lock()
        defer { writeLock.unlock() }
        lock.lock()
        let writer = descriptor >= 0 ? dup(descriptor) : -1
        lock.unlock()
        guard writer >= 0 else { throw Failure("Daemon is disconnected") }
        defer { Darwin.close(writer) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    writer, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw Failure("Daemon write failed; result may be unknown") }
                offset += written
            }
        }
    }
    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
    }
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
