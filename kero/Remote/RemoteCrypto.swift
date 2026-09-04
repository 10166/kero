import CryptoKit
import Foundation

struct RemoteDeviceIdentity: Sendable {
    let id: UUID
    let agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey
    let signingPrivateKey: Curve25519.Signing.PrivateKey

    var record: RemoteDeviceRecord {
        RemoteDeviceRecord(
            id: id,
            agreementKey: agreementPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            signingKey: signingPrivateKey.publicKey.rawRepresentation.base64EncodedString(),
            lastSeenAt: ""
        )
    }

    static func loadOrCreate() throws -> Self {
        if let data = RemoteKeychain.data(for: "device-identity"),
           let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
           let id = UUID(uuidString: stored.id),
           let agreementData = Data(base64Encoded: stored.agreementPrivateKey),
           let signingData = Data(base64Encoded: stored.signingPrivateKey),
           let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: agreementData),
           let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: signingData) {
            return Self(id: id, agreementPrivateKey: agreement, signingPrivateKey: signing)
        }

        let identity = Self(
            id: UUID(),
            agreementPrivateKey: Curve25519.KeyAgreement.PrivateKey(),
            signingPrivateKey: Curve25519.Signing.PrivateKey()
        )
        let stored = StoredIdentity(
            id: identity.id.uuidString,
            agreementPrivateKey: identity.agreementPrivateKey.rawRepresentation.base64EncodedString(),
            signingPrivateKey: identity.signingPrivateKey.rawRepresentation.base64EncodedString()
        )
        try RemoteKeychain.set(try JSONEncoder().encode(stored), for: "device-identity")
        return identity
    }

    private struct StoredIdentity: Codable {
        let id: String
        let agreementPrivateKey: String
        let signingPrivateKey: String
    }
}

enum RemoteCrypto {
    static func seal(
        _ plaintext: Data,
        kind: RemoteFrameKind,
        recipient: RemoteDeviceRecord,
        sender: RemoteDeviceIdentity,
        streamID: UUID,
        sequence: UInt64
    ) throws -> Data {
        let header = makeHeader(
            kind: kind,
            recipientID: recipient.id,
            senderID: sender.id,
            streamID: streamID,
            sequence: sequence
        )
        let key = try pairKey(identity: sender, peer: recipient)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: header)
        return header + box.combined
    }

    static func open(
        _ data: Data,
        recipient: RemoteDeviceIdentity,
        sender: RemoteDeviceRecord
    ) throws -> (RemoteFrame, Data) {
        guard data.count >= RemoteFrame.headerLength + RemoteFrame.sealedOverhead,
              data[0] == RemoteFrame.version,
              let kind = RemoteFrameKind(rawValue: data[1])
        else { throw RemoteCryptoError.invalidFrame }

        let recipientID = try UUID(remoteBytes: data[2..<18])
        let senderID = try UUID(remoteBytes: data[18..<34])
        let streamID = try UUID(remoteBytes: data[34..<50])
        let sequence = data[50..<58].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard recipientID == recipient.id, senderID == sender.id else {
            throw RemoteCryptoError.wrongRoute
        }
        let header = data.prefix(RemoteFrame.headerLength)
        let box = try ChaChaPoly.SealedBox(combined: data.dropFirst(RemoteFrame.headerLength))
        let plaintext = try ChaChaPoly.open(
            box,
            using: pairKey(identity: recipient, peer: sender),
            authenticating: header
        )
        return (
            RemoteFrame(
                kind: kind,
                recipientID: recipientID,
                senderID: senderID,
                streamID: streamID,
                sequence: sequence,
                ciphertext: Data(data.dropFirst(RemoteFrame.headerLength))
            ),
            plaintext
        )
    }

    private static func pairKey(
        identity: RemoteDeviceIdentity,
        peer: RemoteDeviceRecord
    ) throws -> SymmetricKey {
        guard let rawKey = Data(base64Encoded: peer.agreementKey) else {
            throw RemoteCryptoError.invalidKey
        }
        let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: rawKey)
        let secret = try identity.agreementPrivateKey.sharedSecretFromKeyAgreement(with: publicKey)
        let ids = [identity.id.uuidString.lowercased(), peer.id.uuidString.lowercased()].sorted()
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(ids.joined(separator: "\0").utf8),
            sharedInfo: Data("kero-remote-v1".utf8),
            outputByteCount: 32
        )
    }

    private static func makeHeader(
        kind: RemoteFrameKind,
        recipientID: UUID,
        senderID: UUID,
        streamID: UUID,
        sequence: UInt64
    ) -> Data {
        var data = Data([RemoteFrame.version, kind.rawValue])
        data.append(recipientID.remoteBytes)
        data.append(senderID.remoteBytes)
        data.append(streamID.remoteBytes)
        data.append(contentsOf: withUnsafeBytes(of: sequence.bigEndian, Array.init))
        return data
    }
}

enum RemoteCryptoError: Error {
    case invalidFrame
    case invalidKey
    case wrongRoute
}

extension UUID {
    var remoteBytes: Data {
        var value = uuid
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    init(remoteBytes bytes: Data.SubSequence) throws {
        guard bytes.count == 16 else { throw RemoteCryptoError.invalidFrame }
        var value: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &value) { target in
            target.copyBytes(from: bytes)
        }
        self.init(uuid: value)
    }
}
