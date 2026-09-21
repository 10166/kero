import Foundation

/// The renderer owns pixels and input translation; the transport owns the
/// connection. Closing a view only detaches, never terminates a daemon shell.
@MainActor
protocol TerminalTransport: AnyObject {
    var sessionID: UUID { get }
    var onData: ((Data, Bool) -> Void)? { get set }
    var ownsProtocolResponses: Bool { get }
    func send(_ data: Data)
    func resize(_ resize: RemoteResize)
    func close()
}

extension RemoteTerminalConnection: TerminalTransport {
    var ownsProtocolResponses: Bool { false }
}

nonisolated struct DaemonSessionIdentity: Codable, Equatable, Sendable {
    var host: UUID
    var instance: UUID
    var session: UUID
}

nonisolated struct DaemonSize: Codable, Sendable {
    var columns: UInt16
    var rows: UInt16
    var cell_width: UInt16
    var cell_height: UInt16
    init(_ resize: RemoteResize) {
        columns = resize.columns
        rows = resize.rows
        cell_width = resize.cellWidth
        cell_height = resize.cellHeight
    }
}

nonisolated struct DaemonSessionInfo: Codable, Sendable {
    var key: DaemonSessionIdentity
    var pid: UInt32
    var directory: String
    var size: DaemonSize
    var alive: Bool
    var sequence: UInt64
}
