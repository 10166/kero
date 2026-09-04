import Foundation

enum RemoteFrameKind: UInt8, Sendable {
    case topology = 1
    case attach = 2
    case granted = 3
    case busy = 4
    case bootstrap = 5
    case output = 6
    case input = 7
    case resize = 8
    case release = 9
    case hello = 10
}

struct RemoteDeviceRecord: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let agreementKey: String
    let signingKey: String
    let lastSeenAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case agreementKey = "agreement_key"
        case signingKey = "signing_key"
        case lastSeenAt = "last_seen_at"
    }
}

struct RemoteTopology: Codable, Equatable, Sendable {
    let revision: UInt64
    let hostName: String
    let projects: [RemoteProjectDescriptor]
}

struct RemoteProjectDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let tabs: [RemoteTabDescriptor]
    let selectedTabID: UUID?
}

struct RemoteTabDescriptor: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let title: String
    let layout: RemotePaneNode
    let focusedPaneID: UUID
}

indirect enum RemotePaneNode: Codable, Equatable, Sendable {
    case pane(RemotePaneDescriptor)
    case split(id: UUID, axis: PaneSplitAxis, fraction: Double, first: RemotePaneNode, second: RemotePaneNode)

    private enum CodingKeys: String, CodingKey {
        case kind, pane, id, axis, fraction, first, second
    }

    private enum Kind: String, Codable {
        case pane, split
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .pane:
            self = .pane(try values.decode(RemotePaneDescriptor.self, forKey: .pane))
        case .split:
            self = .split(
                id: try values.decode(UUID.self, forKey: .id),
                axis: try values.decode(PaneSplitAxis.self, forKey: .axis),
                fraction: try values.decode(Double.self, forKey: .fraction),
                first: try values.decode(RemotePaneNode.self, forKey: .first),
                second: try values.decode(RemotePaneNode.self, forKey: .second)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try values.encode(Kind.pane, forKey: .kind)
            try values.encode(pane, forKey: .pane)
        case let .split(id, axis, fraction, first, second):
            try values.encode(Kind.split, forKey: .kind)
            try values.encode(id, forKey: .id)
            try values.encode(axis, forKey: .axis)
            try values.encode(fraction, forKey: .fraction)
            try values.encode(first, forKey: .first)
            try values.encode(second, forKey: .second)
        }
    }
}

struct RemotePaneDescriptor: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case terminal, file, browser, diff
    }

    let id: UUID
    let kind: Kind
    let title: String
    let sessionID: UUID?
}

struct RemoteAttachRequest: Codable, Sendable {
    let requestID: UUID
    let sessionID: UUID
    let controllerEpoch: UUID
    let hostEpoch: UUID
    let columns: UInt16
    let rows: UInt16
    let cellWidth: UInt16
    let cellHeight: UInt16
}

struct RemoteAttachResponse: Codable, Sendable {
    let requestID: UUID
    let sessionID: UUID
    let reason: String?
}

struct RemoteResize: Codable, Sendable {
    let sessionID: UUID
    let columns: UInt16
    let rows: UInt16
    let cellWidth: UInt16
    let cellHeight: UInt16
}

struct RemoteSessionReference: Codable, Sendable {
    let sessionID: UUID
}

struct RemoteDeviceHello: Codable, Sendable {
    let name: String
    let hostEnabled: Bool
}

struct RemoteFrame: Sendable {
    static let version: UInt8 = 1
    static let headerLength = 58
    static let sealedOverhead = 28

    let kind: RemoteFrameKind
    let recipientID: UUID
    let senderID: UUID
    let streamID: UUID
    let sequence: UInt64
    let ciphertext: Data
}
