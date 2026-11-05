import Foundation
import Network
import Security
import BambuCore

/// One MQTT 3.1.1 session over TLS, on Network.framework.
///
/// The packet codec is ``BambuCore/MQTT``; this owns the socket, the
/// keep-alive and the certificate check, and reports what happens through
/// ``events``. Most apps want ``BambuPrinter`` instead, which adds reconnects
/// and status parsing on top.
public final class MQTTSession: @unchecked Sendable {
    public enum Event: Sendable {
        /// CONNACK 0. Carries the leaf certificate the session was made with, for pinning.
        case connected(leafDER: Data?)
        /// CONNACK with a non-zero return code (4 and 5 mean the access code is wrong).
        case refused(UInt8)
        /// The broker refused the subscription (SUBACK 0x80).
        case subscriptionRefused
        case message(topic: String, payload: Data)
        /// The server presented a certificate that `verify` rejected.
        case certificateRejected
        /// The session ended. `beforeConnack`: the socket closed before the broker answered CONNECT.
        case disconnected(reason: String?, beforeConnack: Bool)
    }

    public struct Credentials: Sendable {
        public var clientID: String
        public var username: String
        public var password: String

        public init(clientID: String, username: String, password: String) {
            self.clientID = clientID
            self.username = username
            self.password = password
        }
    }

    /// Every event of this session, ending after `.disconnected` or `.certificateRejected`.
    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "bambu-swift.mqtt")
    private let host: String
    private let port: UInt16
    private let credentials: Credentials
    private let keepAlive: UInt16
    private let verify: @Sendable (Data) -> Bool

    private var connection: NWConnection?
    private var decoder = MQTTDecoder()
    private var ping: DispatchSourceTimer?
    private var lastReceived = Date()
    private var nextPacketID: UInt16 = 1
    private var finished = false
    private var certificateRejected = false
    private var leafDER: Data?
    private var connacked = false

    /// - Parameter verify: gets the server's leaf certificate (DER) and says whether to continue.
    ///   It runs on the TLS queue for every handshake.
    public init(host: String, port: UInt16, credentials: Credentials, keepAlive: UInt16, verify: @escaping @Sendable (Data) -> Bool) {
        self.host = host
        self.port = port
        self.credentials = credentials
        self.keepAlive = keepAlive
        self.verify = verify
        (events, continuation) = AsyncStream<Event>.makeStream()
    }

    public func start() {
        queue.async { [self] in
            let tls = NWProtocolTLS.Options()
            let verify = self.verify
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { [weak self] _, secTrust, complete in
                let trust = sec_trust_copy_ref(secTrust).takeRetainedValue()
                guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
                    complete(false)
                    return
                }
                let der = SecCertificateCopyData(leaf) as Data
                let ok = verify(der)
                if ok { self?.leafDER = der } else { self?.certificateRejected = true }
                complete(ok)
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.connectionTimeout = 10
            let parameters = NWParameters(tls: tls, tcp: tcp)
            guard let port = NWEndpoint.Port(rawValue: self.port) else { return }
            let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in self?.handle(state: state) }
            conn.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            guard let connection, connection.state == .ready else {
                self.connection?.cancel()
                finish(nil)
                return
            }
            // Let the DISCONNECT leave before the socket closes.
            connection.send(content: MQTT.disconnect, completion: .contentProcessed { [weak self] _ in
                self?.connection?.cancel()
                self?.finish(nil)
            })
        }
    }

    public func subscribe(_ topic: String) {
        queue.async { [self] in
            let id = nextPacketID
            nextPacketID = nextPacketID == .max ? 1 : nextPacketID + 1
            send(MQTT.subscribe(packetID: id, topic: topic))
        }
    }

    public func publish(_ topic: String, _ payload: Data) {
        queue.async { [self] in send(MQTT.publish(topic: topic, payload: payload)) }
    }

    // MARK: Queue-side

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            lastReceived = Date()
            send(MQTT.connect(clientID: credentials.clientID, username: credentials.username,
                              password: credentials.password, keepAlive: keepAlive))
            startPing()
            receive()
        case .waiting(let error):
            // No route to a LAN device will not fix itself soon; fail now and let the caller retry.
            connection?.cancel()
            finish(error.localizedDescription)
        case .failed(let error):
            finish(error.localizedDescription)
        case .cancelled:
            finish(nil)
        default:
            break
        }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(error.localizedDescription) }
        })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                lastReceived = Date()
                for packet in decoder.feed(data) { handle(packet: packet) }
            }
            if let error {
                finish(error.localizedDescription)
            } else if isComplete {
                finish("The printer closed the connection.")
            } else if !finished {
                receive()
            }
        }
    }

    private func handle(packet: MQTTPacket) {
        switch packet {
        case .connack(_, let code):
            connacked = true
            if code == 0 {
                continuation.yield(.connected(leafDER: leafDER))
            } else {
                // The broker answered, so this is not a silent close.
                continuation.yield(.refused(code))
                connection?.cancel()
            }
        case .publish(let topic, let payload, let qos, let packetID):
            if qos == 1, let packetID { send(MQTT.puback(packetID: packetID)) }
            continuation.yield(.message(topic: topic, payload: payload))
        case .suback(_, let codes):
            if codes.contains(where: { $0 >= 0x80 }) { continuation.yield(.subscriptionRefused) }
        case .malformed:
            connection?.cancel()
            finish("Garbled data from the printer.")
        case .pingresp, .puback, .other:
            break
        }
    }

    private func startPing() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = max(5, Int(keepAlive) / 2)
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if Date().timeIntervalSince(lastReceived) > Double(keepAlive) * 1.5 {
                connection?.cancel()
                finish("No answer from the printer.")
            } else {
                send(MQTT.pingreq)
            }
        }
        timer.resume()
        ping = timer
    }

    private func finish(_ reason: String?) {
        guard !finished else { return }
        finished = true
        ping?.cancel()
        ping = nil
        if certificateRejected {
            continuation.yield(.certificateRejected)
        } else {
            continuation.yield(.disconnected(reason: reason, beforeConnack: !connacked))
        }
        continuation.finish()
    }
}
