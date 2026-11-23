import CryptoKit
import Foundation
import Network
import PassthroughCore
import notify

/// The phone accepts a linked Mac on Personal Hotspot, so an intervening
/// router can NAT the connection in the normal outbound direction.
public enum RouterRelay {
    public static let port: UInt16 = 17891
    public static let carrier = "Travel router"
    private static let proofLabel = Data("passthrough-router-link-v1".utf8)
    private static let maxHandshakeBytes = 4096

    public static func identity() throws -> MacIdentity {
        try MacIdentity.loadOrCreate(label: "\(PassthroughProtocol.identifier).router-relay",
                                     accessGroup: PassthroughProtocol.appGroup)
    }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    private static func read(_ stream: ByteStream,
                             completion: @escaping @Sendable (WirelessLink.Handshake?, Data) -> Void) {
        WirelessLink.readLine(stream, limit: maxHandshakeBytes) { result in
            guard case .success(let (line, rest)) = result, line.count <= maxHandshakeBytes,
                  let message = try? JSONDecoder().decode(WirelessLink.Handshake.self, from: line) else {
                completion(nil, Data())
                return
            }
            completion(message, rest)
        }
    }

    /// Establish a pinned TLS connection before proving the existing pairing.
    /// Wi-Fi scoping keeps the link on the router when the Mac's tunnel takes
    /// over its default route. Tests can use a loopback endpoint.
    static func dial(phone: WirelessPhone, macTag: String, queue: DispatchQueue,
                     host: NWEndpoint.Host = .init(WirelessLink.hotspotGateway), port: UInt16 = port,
                     wifiOnly: Bool = true, completion: @escaping @Sendable (Mux?) -> Void) -> ConnectionStream? {
        guard let pin = phone.routerCertificate, validFingerprint(pin), let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let params = WirelessLink.pinnedClientParameters(pin: pin, peerToPeer: false)
        if wifiOnly { params.requiredInterfaceType = .wifi }
        let stream = ConnectionStream(NWConnection(host: host, port: endpointPort, using: params), queue: queue)
        let finished = Locked(false)
        let finish: @Sendable (Mux?) -> Void = { mux in
            guard !finished.exchange(true) else { return }
            stream.onTerminated = nil
            if mux == nil { stream.cancel() }
            completion(mux)
        }
        stream.onTerminated = { _ in finish(nil) }
        queue.asyncAfter(deadline: .now() + 6) { finish(nil) }
        read(stream) { challenge, _ in
            guard !finished.get(), challenge?.t == "router-challenge",
                  let nonce = challenge?.nonce.flatMap({ Data(base64Encoded: $0) }), nonce.count == 32 else {
                finish(nil)
                return
            }
            let key = SymmetricKey(data: phone.linkKey)
            let proof = Data(HMAC<SHA256>.authenticationCode(for: proofLabel + nonce, using: key))
            WirelessLink.sendLine(.init(t: "router-proof", macTag: macTag, mac: proof.base64EncodedString()), on: stream)
            read(stream) { reply, rest in
                guard reply?.t == "router-ready", reply?.phoneID == phone.phoneID else { finish(nil); return }
                finish(Mux(transport: stream, isOpener: true, queue: queue, initialBytes: rest))
            }
        }
        return stream
    }

    public final class Server: @unchecked Sendable {
        private let identity: MacIdentity
        private let registry: PairingRegistry
        private let serve: @Sendable (UInt16, MuxStream) -> Void
        private let host: NWEndpoint.Host
        private let port: NWEndpoint.Port
        private let queue = DispatchQueue(label: "\(PassthroughProtocol.identifier).router-relay")
        private lazy var handshakes = HandshakeLimiter(queue: queue)
        private var listener: NWListener?
        private var running = false
        private var pairingsToken: Int32?
        private var sessions: [String: (mux: Mux, key: Data)] = [:]

        public convenience init(service: PassthroughService) throws {
            try self.init(identity: RouterRelay.identity(), registry: service.registry,
                          host: .init(WirelessLink.hotspotGateway), port: NWEndpoint.Port(rawValue: RouterRelay.port)!) { [weak service] port, stream in
                guard let service else { stream.cancel(); return }
                switch port {
                case service.options.socksPort:
                    if let socks = service.socks { socks.accept(stream) } else { stream.cancel() }
                case service.options.controlPort:
                    if let control = service.control { control.accept(stream) } else { stream.cancel() }
                default:
                    stream.cancel()
                }
            }
        }

        init(identity: MacIdentity, registry: PairingRegistry, host: NWEndpoint.Host, port: NWEndpoint.Port,
             serve: @escaping @Sendable (UInt16, MuxStream) -> Void) {
            self.identity = identity
            self.registry = registry
            self.host = host
            self.port = port
            self.serve = serve
        }

        public func start() throws {
            try start(onReady: nil)
        }

        func start(onReady: (@Sendable (UInt16) -> Void)?) throws {
            try queue.sync {
                guard !running else { return }
                try listen(onReady: onReady)
                running = true
                var token: Int32 = 0
                if notify_register_dispatch(PairingRegistry.changedNotification, &token, queue, { [weak self] _ in
                    self?.dropRevokedSessions()
                }) == NOTIFY_STATUS_OK {
                    pairingsToken = token
                }
            }
        }

        public func stop() {
            queue.sync {
                running = false
                if let pairingsToken { notify_cancel(pairingsToken) }
                pairingsToken = nil
                listener?.cancel()
                listener = nil
                for session in sessions.values { session.mux.close() }
                sessions.removeAll()
            }
        }

        private func listen(onReady: (@Sendable (UInt16) -> Void)?) throws {
            let params = try identity.tlsListenerParameters()
            params.requiredLocalEndpoint = .hostPort(host: host, port: port)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                if let self { self.accept(connection) } else { connection.cancel() }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { onReady?(port) }
                    ptLog(.info, "Travel router link ready")
                case .failed(let error), .waiting(let error):
                    ptLog(.debug, "Travel router link waiting for Personal Hotspot: \(error)")
                    // The hotspot address may appear after the extension starts.
                    self.listener = nil
                    listener.cancel()
                    self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                        guard let self, self.running, self.listener == nil else { return }
                        do { try self.listen(onReady: onReady) }
                        catch { ptLog(.warning, "Travel router link could not restart: \(error.localizedDescription)") }
                    }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }

        private func accept(_ connection: NWConnection) {
            let peer = PeerAddress.host(of: connection)
            guard running, let slot = handshakes.acquire(host: peer, onTimeout: { connection.cancel() }) else {
                connection.cancel()
                return
            }
            let pendingSlot = Locked(slot)
            let stream = ConnectionStream(connection, queue: queue)
            let nonce = WirelessLink.randomBytes(32)
            WirelessLink.sendLine(.init(t: "router-challenge", nonce: nonce.base64EncodedString()), on: stream)
            RouterRelay.read(stream) { [weak self] message, rest in
                guard let self else { stream.cancel(); return }
                self.queue.async {
                    self.finishHandshake(message, rest: rest, nonce: nonce, peer: peer, stream: stream, slot: pendingSlot.get())
                }
            }
        }

        private func finishHandshake(_ message: WirelessLink.Handshake?, rest: Data, nonce: Data, peer: String,
                                     stream: ConnectionStream, slot: HandshakeLimiter.Slot) {
            guard slot.release(), running, message?.t == "router-proof", let tag = message?.macTag,
                  let proof = message?.mac.flatMap({ Data(base64Encoded: $0) }), proof.count == 32,
                  let key = key(for: tag),
                  HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofLabel + nonce,
                                                         using: SymmetricKey(data: key)) else {
                stream.cancel()
                return
            }
            handshakes.proven(peer)
            sessions[tag]?.mux.close()
            let mux = Mux(transport: stream, isOpener: false, queue: queue, initialBytes: rest)
            mux.onOpen = { [weak self] port, child in
                guard let self, self.running else { child.cancel(); return }
                self.serve(port, child)
            }
            mux.onClose = { [weak self, weak mux] _ in
                guard let self, self.sessions[tag]?.mux === mux else { return }
                self.sessions[tag] = nil
            }
            sessions[tag] = (mux, key)
            WirelessLink.sendLine(.init(t: "router-ready", phoneID: registry.phoneID), on: stream)
            mux.start()
        }

        private func key(for macTag: String) -> Data? {
            registry.linkCredentials().first { $0.macTag == macTag && $0.hotspotOnly != true }?.linkKey
        }

        private func dropRevokedSessions() {
            for (tag, session) in sessions where key(for: tag) != session.key {
                session.mux.close()
            }
        }
    }
}
