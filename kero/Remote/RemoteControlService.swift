import Combine
import Foundation

struct RemoteHost: Identifiable, Equatable {
    let id: UUID
    var name: String
    var isOnline: Bool
    var isHostEnabled: Bool
    var topology: RemoteTopology?
}

@MainActor
final class RemoteControlService: ObservableObject {
    static let shared = RemoteControlService()

    enum State: Equatable {
        case signedOut
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var hosts: [RemoteHost] = []
    @Published private(set) var devices: [RemoteDeviceRecord] = []

    var isSignedIn: Bool { tokens != nil }
    var localDeviceID: UUID? { identity?.id }

    private var identity: RemoteDeviceIdentity?
    private var tokens: RemoteTokens?
    private var api: RemoteAPIClient?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var topologyRevision: UInt64 = 0
    private var sequences: [SequenceKey: UInt64] = [:]
    private var receivedSequences: [SequenceKey: UInt64] = [:]
    private var controlStreamID = UUID()
    private var helloByDevice: [UUID: RemoteDeviceHello] = [:]
    private var helloStreamByDevice: [UUID: UUID] = [:]
    private var topologyByDevice: [UUID: RemoteTopology] = [:]
    private var onlineDeviceIDs = Set<UUID>()
    private var hostControls: [UUID: HostControl] = [:]
    private var remoteConnections: [RemoteConnectionKey: RemoteTerminalConnection] = [:]
    private var outboundFrames: [Data] = []
    private var outboundFrameIndex = 0
    private var outboundBytes = 0
    private var isSendingFrame = false

    private static let maximumQueuedFrames = 512
    private static let maximumQueuedBytes = 8 * 1024 * 1024

    private init() {}

    func start() {
        guard api == nil else { return }
        do {
            identity = try RemoteDeviceIdentity.loadOrCreate()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        restoreSessionAndConnect()
    }

    func settingsDidChange() {
        guard api != nil || !AppSettings.shared.remoteRelayURL.isEmpty else { return }
        disconnect(keepSession: true)
        restoreSessionAndConnect()
    }

    func signIn() async {
        guard let relayURL = validatedRelayURL else {
            state = .failed(String(localized: "Enter a valid relay URL first."))
            return
        }
        state = .connecting
        let client = RemoteAPIClient(relayURL: relayURL)
        api = client
        do {
            guard let identity else { throw RemoteServiceError.missingIdentity }
            let signedIn = try await client.signIn(identity: identity)
            try persist(tokens: signedIn, relayURL: relayURL)
            tokens = signedIn
            try await connect()
        } catch {
            state = .failed(error.localizedDescription)
            if tokens != nil { scheduleReconnect() }
        }
    }

    func signOut() {
        if let relayURL = validatedRelayURL {
            RemoteKeychain.remove(tokenKey(for: relayURL))
        }
        disconnect(keepSession: false)
        tokens = nil
        state = .signedOut
    }

    func revoke(_ device: RemoteDeviceRecord) async {
        do {
            guard let api else { return }
            let token = try await validAccessToken()
            try await api.revoke(deviceID: device.id, accessToken: token)
            if device.id == identity?.id { signOut() }
            else { try await refreshDevices() }
        } catch {
            if tokens != nil { state = .failed(error.localizedDescription) }
        }
    }

    func topologyDidChange() {
        guard state == .connected, AppSettings.shared.remoteHostEnabled else { return }
        topologyRevision &+= 1
        let topology = TerminalManager.remoteTopology(revision: topologyRevision)
        guard let payload = try? JSONEncoder().encode(topology) else { return }
        let streamID = controlStreamID
        for device in devices where onlineDeviceIDs.contains(device.id)
            && device.id != identity?.id
            && helloStreamByDevice[device.id] != nil {
            send(payload, kind: .topology, to: device, streamID: streamID)
        }
    }

    func connection(
        hostID: UUID,
        sessionID: UUID,
        viewport: RemoteResize
    ) -> RemoteTerminalConnection? {
        let key = RemoteConnectionKey(hostID: hostID, sessionID: sessionID)
        if let existing = remoteConnections[key] {
            return existing
        }
        guard let host = devices.first(where: { $0.id == hostID }),
              onlineDeviceIDs.contains(hostID),
              let hostEpoch = helloStreamByDevice[hostID] else { return nil }
        let connection = RemoteTerminalConnection(
            hostID: hostID,
            sessionID: sessionID,
            service: self
        )
        remoteConnections[key] = connection
        let request = RemoteAttachRequest(
            requestID: connection.streamID,
            sessionID: sessionID,
            controllerEpoch: controlStreamID,
            hostEpoch: hostEpoch,
            columns: viewport.columns,
            rows: viewport.rows,
            cellWidth: viewport.cellWidth,
            cellHeight: viewport.cellHeight
        )
        if let payload = try? JSONEncoder().encode(request) {
            send(payload, kind: .attach, to: host, streamID: connection.streamID)
        }
        return connection
    }

    func release(_ connection: RemoteTerminalConnection) {
        let key = RemoteConnectionKey(
            hostID: connection.hostID,
            sessionID: connection.sessionID
        )
        guard remoteConnections[key] === connection else { return }
        remoteConnections[key] = nil
        guard let host = devices.first(where: { $0.id == connection.hostID }) else { return }
        if let payload = try? JSONEncoder().encode(
            RemoteSessionReference(sessionID: connection.sessionID)
        ) {
            send(payload, kind: .release, to: host, streamID: connection.streamID)
        }
    }

    func sendInput(_ data: Data, for connection: RemoteTerminalConnection) {
        guard connection.state == .connected,
              let host = devices.first(where: { $0.id == connection.hostID }) else { return }
        send(data, kind: .input, to: host, streamID: connection.streamID)
    }

    func sendResize(_ resize: RemoteResize, for connection: RemoteTerminalConnection) {
        guard connection.state == .connected,
              let host = devices.first(where: { $0.id == connection.hostID }),
              let payload = try? JSONEncoder().encode(resize) else { return }
        send(payload, kind: .resize, to: host, streamID: connection.streamID)
    }

    /// Local input is always allowed to reclaim a hosted PTY. The controller
    /// receives an authenticated release before the host restores its own
    /// keyboard and geometry authority.
    func reclaim(sessionID: UUID) {
        guard let control = hostControls.removeValue(forKey: sessionID) else { return }
        if let controller = devices.first(where: { $0.id == control.controllerID }),
           let payload = try? JSONEncoder().encode(
               RemoteSessionReference(sessionID: sessionID)
           ) {
            send(payload, kind: .release, to: controller, streamID: control.streamID)
        }
        control.release()
    }

    private var validatedRelayURL: URL? {
        guard let url = URL(string: AppSettings.shared.remoteRelayURL),
              url.host != nil else { return nil }
        let loopbackHosts = Set(["localhost", "127.0.0.1", "::1"])
        guard url.scheme == "https"
            || (url.scheme == "http" && loopbackHosts.contains(url.host!))
        else { return nil }
        return url
    }

    private func restoreSessionAndConnect() {
        guard let relayURL = validatedRelayURL else {
            tokens = nil
            state = .signedOut
            return
        }
        api = RemoteAPIClient(relayURL: relayURL)
        if let data = RemoteKeychain.data(for: tokenKey(for: relayURL)),
           let restored = try? JSONDecoder().decode(RemoteTokens.self, from: data) {
            tokens = restored
            Task {
                do { try await connect() }
                catch {
                    guard tokens != nil else { return }
                    state = .failed(error.localizedDescription)
                    scheduleReconnect()
                }
            }
        } else {
            tokens = nil
            state = .signedOut
        }
    }

    private func persist(tokens: RemoteTokens, relayURL: URL) throws {
        try RemoteKeychain.set(
            try JSONEncoder().encode(tokens),
            for: tokenKey(for: relayURL)
        )
    }

    private func tokenKey(for relayURL: URL) -> String {
        "tokens:" + relayURL.absoluteString
    }

    private func connect() async throws {
        guard let identity, let api else {
            throw RemoteServiceError.signedOut
        }
        let accessToken = try await validAccessToken()
        state = .connecting
        try await api.register(identity: identity, accessToken: accessToken)
        try await refreshDevices()
        let socket = api.socket(deviceID: identity.id, accessToken: accessToken)
        controlStreamID = UUID()
        self.socket = socket
        socket.resume()
        state = .connected
        startKeepalive(on: socket)
        receiveTask?.cancel()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket)
        }
    }

    private func validAccessToken() async throws -> String {
        guard var current = tokens else { throw RemoteServiceError.signedOut }
        if current.expiresAt.timeIntervalSinceNow < 60 {
            guard let api else { throw RemoteServiceError.signedOut }
            do {
                current = try await api.refresh(current.refreshToken)
                tokens = current
                if let relayURL = validatedRelayURL {
                    try persist(tokens: current, relayURL: relayURL)
                }
            } catch {
                // A timeout or relay outage says nothing about whether the
                // refresh token is valid. Preserve it for the reconnect loop.
                if RemoteAPIError.invalidatesRefreshToken(error) { signOut() }
                throw error
            }
        }
        return current.accessToken
    }

    private func refreshDevices() async throws {
        guard let api else {
            throw RemoteServiceError.signedOut
        }
        let accessToken = try await validAccessToken()
        devices = try await api.devices(accessToken: accessToken)
        rebuildHosts()
    }

    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .string(let string):
                    await receivePresence(string)
                case .data(let data):
                    await receiveEncrypted(data)
                @unknown default:
                    break
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            connectionLost(socket)
        }
    }

    private func receivePresence(_ string: String) async {
        guard let data = string.data(using: .utf8),
              let presence = try? JSONDecoder().decode(Presence.self, from: data)
        else { return }
        let newOnlineDeviceIDs = Set(presence.onlineDeviceIDs)
        reconnectAttempt = 0
        let newlyOnline = newOnlineDeviceIDs.subtracting(onlineDeviceIDs)
        onlineDeviceIDs = newOnlineDeviceIDs
        for deviceID in newlyOnline where deviceID != identity?.id {
            helloByDevice[deviceID] = nil
            helloStreamByDevice[deviceID] = nil
            topologyByDevice[deviceID] = nil
        }
        let staleControls = hostControls.filter {
            !onlineDeviceIDs.contains($0.value.controllerID)
        }
        for (sessionID, control) in staleControls {
            hostControls[sessionID] = nil
            control.release()
        }
        let staleConnections = remoteConnections.filter {
            !onlineDeviceIDs.contains($0.value.hostID)
        }
        for (key, connection) in staleConnections {
            remoteConnections[key] = nil
            connection.disconnected()
        }
        // Presence also changes when a peer is revoked. Refreshing the small
        // account-scoped device list keeps revoked hosts from lingering as
        // permanent offline rows on other connected Macs.
        try? await refreshDevices()
        rebuildHosts()
        for device in devices where device.id != identity?.id
            && onlineDeviceIDs.contains(device.id) {
            sendHello(to: device)
        }
        topologyDidChange()
    }

    private func receiveEncrypted(_ data: Data) async {
        guard let identity,
              data.count >= RemoteFrame.headerLength,
              let senderID = try? UUID(remoteBytes: data[18..<34]),
              let sender = devices.first(where: { $0.id == senderID }),
              let (frame, plaintext) = try? RemoteCrypto.open(
                data,
                recipient: identity,
                sender: sender
              ) else { return }

        let key = SequenceKey(deviceID: sender.id, streamID: frame.streamID)
        if let last = receivedSequences[key], frame.sequence <= last { return }
        receivedSequences[key] = frame.sequence

        switch frame.kind {
        case .hello:
            guard let hello = try? JSONDecoder().decode(RemoteDeviceHello.self, from: plaintext)
            else { return }
            let epochChanged = helloStreamByDevice[sender.id] != frame.streamID
            if epochChanged {
                topologyByDevice[sender.id] = nil
                helloStreamByDevice[sender.id] = frame.streamID
            }
            helloByDevice[sender.id] = hello
            if !hello.hostEnabled { topologyByDevice[sender.id] = nil }
            rebuildHosts()
            if epochChanged {
                // This acknowledgement lets the peer publish topology only
                // after both sides know one another's current socket epoch.
                sendHello(to: sender)
                sendCurrentTopology(to: sender)
            }
        case .topology:
            guard let topology = try? JSONDecoder().decode(RemoteTopology.self, from: plaintext),
                  helloByDevice[sender.id]?.hostEnabled == true,
                  helloStreamByDevice[sender.id] == frame.streamID else { return }
            if topology.revision >= (topologyByDevice[sender.id]?.revision ?? 0) {
                topologyByDevice[sender.id] = topology
                rebuildHosts()
            }
        case .attach:
            await receiveAttach(plaintext, frame: frame, sender: sender)
        case .granted:
            guard let response = try? JSONDecoder().decode(RemoteAttachResponse.self, from: plaintext),
                  let connection = remoteConnections[
                      RemoteConnectionKey(hostID: sender.id, sessionID: response.sessionID)
                  ],
                  connection.streamID == frame.streamID else { return }
            connection.granted()
        case .busy:
            guard let response = try? JSONDecoder().decode(RemoteAttachResponse.self, from: plaintext),
                  let connection = remoteConnections[
                      RemoteConnectionKey(hostID: sender.id, sessionID: response.sessionID)
                  ],
                  connection.streamID == frame.streamID,
                  response.requestID == frame.streamID else { return }
            connection.failed(response.reason ?? String(localized: "Terminal is already controlled."))
        case .bootstrap, .output:
            remoteConnections.values.first {
                $0.streamID == frame.streamID && $0.hostID == sender.id
            }?.receive(plaintext, bootstrap: frame.kind == .bootstrap)
        case .input:
            guard let control = hostControls.values.first(where: {
                $0.streamID == frame.streamID && $0.controllerID == sender.id
            }) else { return }
            control.session.receiveRemoteInput(plaintext)
        case .resize:
            guard let resize = try? JSONDecoder().decode(RemoteResize.self, from: plaintext),
                  let control = hostControls[resize.sessionID],
                  control.streamID == frame.streamID,
                  control.controllerID == sender.id else { return }
            control.session.applyRemoteResize(resize)
        case .release:
            guard let reference = try? JSONDecoder().decode(RemoteSessionReference.self, from: plaintext)
            else { return }
            if let control = hostControls[reference.sessionID],
               control.streamID == frame.streamID,
               control.controllerID == sender.id {
                hostControls[reference.sessionID] = nil
                control.release()
                return
            }
            let key = RemoteConnectionKey(hostID: sender.id, sessionID: reference.sessionID)
            guard let connection = remoteConnections[key],
                  connection.streamID == frame.streamID else { return }
            remoteConnections[key] = nil
            connection.failed(String(localized: "Control was reclaimed on the host."))
        }
    }

    private func receiveAttach(
        _ data: Data,
        frame: RemoteFrame,
        sender: RemoteDeviceRecord
    ) async {
        guard AppSettings.shared.remoteHostEnabled,
              let request = try? JSONDecoder().decode(RemoteAttachRequest.self, from: data),
              request.requestID == frame.streamID,
              request.controllerEpoch == helloStreamByDevice[sender.id],
              request.hostEpoch == controlStreamID,
              let session = TerminalManager.remoteSession(id: request.sessionID),
              !session.hasExited else {
            sendAttachResponse(
                kind: .busy,
                sessionID: (try? JSONDecoder().decode(RemoteAttachRequest.self, from: data).sessionID) ?? UUID(),
                reason: String(localized: "Terminal is unavailable."),
                to: sender,
                streamID: frame.streamID
            )
            return
        }
        guard hostControls[session.id] == nil else {
            sendAttachResponse(
                kind: .busy,
                sessionID: session.id,
                reason: String(localized: "Terminal is already controlled."),
                to: sender,
                streamID: frame.streamID
            )
            return
        }

        let control = HostControl(
            session: session,
            controllerID: sender.id,
            streamID: frame.streamID
        ) { [weak self] output in
            self?.send(output, kind: .output, to: sender, streamID: frame.streamID)
        }
        hostControls[session.id] = control
        session.beginRemoteControl(
            resize: RemoteResize(
                sessionID: session.id,
                columns: request.columns,
                rows: request.rows,
                cellWidth: request.cellWidth,
                cellHeight: request.cellHeight
            ),
            output: control.output
        )
        let bootstrap = await session.remoteBootstrap()
        guard hostControls[session.id] === control else { return }
        guard let bootstrap else {
            hostControls[session.id] = nil
            control.release()
            sendAttachResponse(
                kind: .busy, sessionID: session.id,
                reason: String(localized: "Terminal is unavailable."),
                to: sender, streamID: frame.streamID
            )
            return
        }
        sendAttachResponse(
            kind: .granted,
            sessionID: session.id,
            reason: nil,
            to: sender,
            streamID: frame.streamID
        )
        send(bootstrap, kind: .bootstrap, to: sender, streamID: frame.streamID)
        control.activate()
    }

    private func sendAttachResponse(
        kind: RemoteFrameKind,
        sessionID: UUID,
        reason: String?,
        to device: RemoteDeviceRecord,
        streamID: UUID
    ) {
        let response = RemoteAttachResponse(
            requestID: streamID,
            sessionID: sessionID,
            reason: reason
        )
        guard let payload = try? JSONEncoder().encode(response) else { return }
        send(payload, kind: kind, to: device, streamID: streamID)
    }

    private func sendHello(to device: RemoteDeviceRecord) {
        let hello = RemoteDeviceHello(
            name: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            hostEnabled: AppSettings.shared.remoteHostEnabled
        )
        guard let payload = try? JSONEncoder().encode(hello) else { return }
        send(payload, kind: .hello, to: device, streamID: controlStreamID)
    }

    private func sendCurrentTopology(to device: RemoteDeviceRecord) {
        guard AppSettings.shared.remoteHostEnabled else { return }
        topologyRevision &+= 1
        let topology = TerminalManager.remoteTopology(revision: topologyRevision)
        guard let payload = try? JSONEncoder().encode(topology) else { return }
        send(payload, kind: .topology, to: device, streamID: controlStreamID)
    }

    private func send(
        _ plaintext: Data,
        kind: RemoteFrameKind,
        to device: RemoteDeviceRecord,
        streamID: UUID
    ) {
        guard let identity, let socket, onlineDeviceIDs.contains(device.id) else { return }
        let key = SequenceKey(deviceID: device.id, streamID: streamID)
        let sequence = sequences[key, default: 0]
        sequences[key] = sequence &+ 1
        guard let frame = try? RemoteCrypto.seal(
            plaintext,
            kind: kind,
            recipient: device,
            sender: identity,
            streamID: streamID,
            sequence: sequence
        ) else { return }
        enqueue(frame, on: socket)
    }

    private func enqueue(_ frame: Data, on socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        let queuedCount = outboundFrames.count - outboundFrameIndex
        guard queuedCount < Self.maximumQueuedFrames,
              outboundBytes + frame.count <= Self.maximumQueuedBytes else {
            connectionLost(socket)
            socket.cancel(with: .policyViolation, reason: nil)
            return
        }
        outboundFrames.append(frame)
        outboundBytes += frame.count
        sendNextFrame(on: socket)
    }

    private func sendNextFrame(on socket: URLSessionWebSocketTask) {
        guard self.socket === socket, !isSendingFrame,
              outboundFrameIndex < outboundFrames.count else { return }
        isSendingFrame = true
        socket.send(.data(outboundFrames[outboundFrameIndex])) { [weak self, weak socket] error in
            guard let socket else { return }
            Task { @MainActor [weak self] in
                self?.completedSend(on: socket, error: error)
            }
        }
    }

    private func completedSend(on socket: URLSessionWebSocketTask, error: Error?) {
        guard self.socket === socket, isSendingFrame else { return }
        isSendingFrame = false
        guard error == nil else {
            connectionLost(socket)
            socket.cancel(with: .goingAway, reason: nil)
            return
        }
        outboundBytes -= outboundFrames[outboundFrameIndex].count
        outboundFrameIndex += 1
        if outboundFrameIndex >= 8,
           outboundFrameIndex * 2 >= outboundFrames.count {
            outboundFrames.removeFirst(outboundFrameIndex)
            outboundFrameIndex = 0
        }
        sendNextFrame(on: socket)
    }

    private func connectionLost(_ socket: URLSessionWebSocketTask) {
        guard self.socket === socket else { return }
        self.socket = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        clearOutboundFrames()
        onlineDeviceIDs = []
        rebuildHosts()
        for connection in remoteConnections.values { connection.disconnected() }
        remoteConnections = [:]
        for control in hostControls.values { control.release() }
        hostControls = [:]
        state = .connecting
        scheduleReconnect()
    }

    private func startKeepalive(on socket: URLSessionWebSocketTask) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self, weak socket] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled, let socket, self?.socket === socket else { return }
                socket.sendPing { [weak self, weak socket] error in
                    guard error != nil, let socket else { return }
                    Task { @MainActor [weak self] in
                        self?.connectionLost(socket)
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                }
            }
        }
    }

    private func clearOutboundFrames() {
        outboundFrames.removeAll(keepingCapacity: false)
        outboundFrameIndex = 0
        outboundBytes = 0
        isSendingFrame = false
    }

    private func rebuildHosts() {
        hosts = devices.compactMap { device in
            guard device.id != identity?.id else { return nil }
            let hello = helloByDevice[device.id]
            return RemoteHost(
                id: device.id,
                name: hello?.name ?? String(localized: "Kero Device"),
                isOnline: onlineDeviceIDs.contains(device.id),
                isHostEnabled: hello?.hostEnabled ?? false,
                topology: topologyByDevice[device.id]
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delaySeconds = min(30, 2 << min(reconnectAttempt, 4))
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delaySeconds))
            guard !Task.isCancelled else { return }
            do { try await self?.connect() }
            catch {
                guard self?.tokens != nil else { return }
                self?.state = .failed(error.localizedDescription)
                self?.scheduleReconnect()
            }
        }
    }

    private func disconnect(keepSession: Bool) {
        reconnectTask?.cancel()
        reconnectAttempt = 0
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        clearOutboundFrames()
        for connection in remoteConnections.values { connection.disconnected() }
        remoteConnections = [:]
        for control in hostControls.values { control.release() }
        hostControls = [:]
        hosts = []
        devices = []
        onlineDeviceIDs = []
        helloByDevice = [:]
        helloStreamByDevice = [:]
        topologyByDevice = [:]
        sequences = [:]
        receivedSequences = [:]
        if !keepSession { api = nil }
    }

    private struct Presence: Codable {
        let onlineDeviceIDs: [UUID]

        enum CodingKeys: String, CodingKey {
            case onlineDeviceIDs = "online_device_ids"
        }
    }

    private struct SequenceKey: Hashable {
        let deviceID: UUID
        let streamID: UUID
    }

    private struct RemoteConnectionKey: Hashable {
        let hostID: UUID
        let sessionID: UUID
    }
}

@MainActor
final class RemoteTerminalConnection {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case disconnected
    }

    let hostID: UUID
    let sessionID: UUID
    let streamID = UUID()
    private(set) var state: State = .connecting
    var onStateChange: ((State) -> Void)? {
        didSet { onStateChange?(state) }
    }
    var onData: ((Data, Bool) -> Void)? {
        didSet {
            guard let onData, !pendingData.isEmpty else { return }
            let pending = pendingData
            pendingData.removeAll(keepingCapacity: false)
            pending.forEach { onData($0.data, $0.bootstrap) }
        }
    }
    weak var service: RemoteControlService?
    private var pendingData: [(data: Data, bootstrap: Bool)] = []
    private var pendingInput: [Data] = []
    private var pendingResize: RemoteResize?

    init(hostID: UUID, sessionID: UUID, service: RemoteControlService) {
        self.hostID = hostID
        self.sessionID = sessionID
        self.service = service
    }

    func granted() {
        state = .connected
        onStateChange?(state)
        if let pendingResize {
            service?.sendResize(pendingResize, for: self)
            self.pendingResize = nil
        }
        let input = pendingInput
        pendingInput.removeAll(keepingCapacity: false)
        input.forEach { service?.sendInput($0, for: self) }
    }
    func failed(_ reason: String) {
        state = .failed(reason)
        onStateChange?(state)
    }
    func disconnected() {
        state = .disconnected
        onStateChange?(state)
    }
    func receive(_ data: Data, bootstrap: Bool) {
        if let onData { onData(data, bootstrap) }
        else if pendingData.count < 256 { pendingData.append((data, bootstrap)) }
    }
    func send(_ data: Data) {
        switch state {
        case .connected:
            service?.sendInput(data, for: self)
        case .connecting where pendingInput.reduce(0, { $0 + $1.count }) < 64 * 1024:
            pendingInput.append(data)
        case .connecting, .failed, .disconnected:
            break
        }
    }
    func resize(_ resize: RemoteResize) {
        if state == .connected { service?.sendResize(resize, for: self) }
        else if state == .connecting { pendingResize = resize }
    }
    func close() { service?.release(self) }
}

@MainActor
private final class HostControl {
    let session: TerminalSession
    let controllerID: UUID
    let streamID: UUID
    private let sendOutput: (Data) -> Void
    private var bufferedOutput: [Data] = []
    private var isActive = false
    lazy var output: (Data) -> Void = { [weak self] data in
        guard let self else { return }
        if isActive { sendOutput(data) }
        else if bufferedOutput.count < 256 { bufferedOutput.append(data) }
    }

    init(
        session: TerminalSession,
        controllerID: UUID,
        streamID: UUID,
        output: @escaping (Data) -> Void
    ) {
        self.session = session
        self.controllerID = controllerID
        self.streamID = streamID
        sendOutput = output
    }

    func activate() {
        isActive = true
        let buffered = bufferedOutput
        bufferedOutput.removeAll(keepingCapacity: false)
        buffered.forEach(sendOutput)
    }

    func release() { session.endRemoteControl() }
}

enum RemoteServiceError: Error {
    case signedOut
    case missingIdentity
}

extension RemoteServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .signedOut:
            String(localized: "Signed out")
        case .missingIdentity:
            String(localized: "Device identity is unavailable.")
        }
    }
}

private extension JSONDecoder {
    static var remote: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
