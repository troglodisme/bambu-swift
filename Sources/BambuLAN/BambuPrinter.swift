@_exported import BambuCore
import Foundation
import Observation

/// One Bambu Lab printer over its local MQTT broker.
///
/// The printer runs an MQTT broker on port 8883 (TLS, self-signed
/// certificate). The username is always `bblp`; the password is the LAN
/// access code shown on the printer's screen (Settings → Network / WLAN).
///
/// This only reads state. Newer firmware refuses most commands from
/// third-party clients unless LAN-only mode and Developer Mode are on, but
/// status reports still flow. "pushall" is the one request sent; if it's
/// ignored, the state fills in as the printer pushes changes.
///
/// ```swift
/// let printer = BambuPrinter(host: "192.168.1.40", serial: "01P00A000000000", accessCode: "12345678")
/// printer.onUpdate = { update in print(summaryOf(update.details, online: update.online)) }
/// printer.start()
/// ```
///
/// `BambuPrinter` is `@Observable`, so SwiftUI views can read ``status``,
/// ``details`` and ``summary`` directly.
@MainActor
@Observable
public final class BambuPrinter {
    public enum Status: String, Sendable {
        case connecting, connected, online, authFailed, unreachable, certificateChanged, stopped

        public var label: String {
            switch self {
            case .connecting: return "Connecting…"
            case .connected: return "Connected, waiting for status"
            case .online: return "Online"
            case .authFailed: return "Access code refused"
            case .unreachable: return "Unreachable"
            case .certificateChanged: return "Certificate changed"
            case .stopped: return "Stopped"
            }
        }
    }

    public let host: String
    public let serial: String
    public var name: String
    public var model: String?

    public private(set) var status: Status = .connecting
    public private(set) var lastError: String?
    public private(set) var details = PrinterDetails.empty
    public private(set) var lastMessage: Date?
    /// The current job, as the printer reports it (task id or file name).
    public private(set) var jobKey: String?
    public private(set) var jobStart: Date?

    /// Called on the main actor whenever the status or details change.
    /// Feed these to a ``BambuCore/JobTracker`` to keep a print history.
    @ObservationIgnored public var onUpdate: ((PrinterUpdate) -> Void)?

    private static let firstReconnectDelay: TimeInterval = 5
    private static let maxReconnectDelay: TimeInterval = 120
    /// This many silent closes before CONNACK in a row and we stop: the printer
    /// is refusing us without saying so (wrong code on some firmware, or it is
    /// out of client slots), and hammering it gets the client blocked.
    private static let silentClosesBeforeGivingUp = 3

    @ObservationIgnored private let accessCode: String
    @ObservationIgnored private let pins: any CertificatePinStore
    @ObservationIgnored private let clientIDPrefix: String
    @ObservationIgnored private let reports = ReportAccumulator()
    @ObservationIgnored private var session: MQTTSession?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectDelay: TimeInterval = BambuPrinter.firstReconnectDelay
    @ObservationIgnored private var silentCloses = 0
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var stopped = false

    /// - Parameters:
    ///   - host: the printer's IP address or host name on your network.
    ///   - serial: the printer's serial number (on its screen, or from ``BambuDiscovery``).
    ///   - accessCode: the LAN access code from the printer's network settings.
    ///   - pins: where to remember the printer's certificate. Defaults to `UserDefaults`.
    ///   - clientIDPrefix: the start of the MQTT client ID, so the printer can tell clients apart.
    public init(
        host: String,
        serial: String,
        accessCode: String,
        name: String? = nil,
        model: String? = nil,
        pins: any CertificatePinStore = UserDefaultsPinStore(),
        clientIDPrefix: String = "bambu-swift-"
    ) {
        self.host = host
        self.serial = serial
        self.accessCode = accessCode
        self.name = name ?? serial
        self.model = model
        self.pins = pins
        self.clientIDPrefix = clientIDPrefix
    }

    /// Connected and heard from on this session. Until the first report arrives there is nothing to show.
    public var online: Bool { connected && lastMessage != nil }
    public var activity: PrinterActivity { activityOf(details, online: online) }
    /// One line for a menu or a list, like "Printing 42% · 1h 10m left".
    public var summary: String { summaryOf(details, online: online) }

    public func start() {
        stopped = false
        silentCloses = 0
        reconnectDelay = Self.firstReconnectDelay
        connect()
    }

    public func stop() {
        stopped = true
        reconnectTask?.cancel()
        pushTask?.cancel()
        eventTask?.cancel()
        session?.stop()
        session = nil
        connected = false
        status = .stopped
        emit()
    }

    /// After a printer was replaced or reset: forget its certificate and connect again.
    public func trustNewCertificate() {
        pins.forget(serial)
        if status == .certificateChanged || status == .unreachable || status == .authFailed {
            status = .connecting
            lastError = nil
            start()
        }
    }

    private func connect() {
        guard !stopped else { return }
        session?.stop()
        connected = false
        // A fresh session has no current reading yet, whatever the last one said.
        lastMessage = nil
        if status != .unreachable { status = .connecting }
        let serial = self.serial
        let pins = self.pins
        let mqtt = MQTTSession(
            host: host,
            port: BambuMQTT.port,
            credentials: .init(
                clientID: clientIDPrefix + String(UInt32.random(in: 0...UInt32.max), radix: 16),
                username: BambuMQTT.username,
                password: accessCode
            ),
            keepAlive: BambuMQTT.keepAlive
        ) { der in pins.matches(serial: serial, leafDER: der) }
        session = mqtt
        mqtt.start()
        eventTask = Task { [weak self] in
            for await event in mqtt.events {
                guard let self else { return }
                await self.handle(event, from: mqtt)
            }
        }
    }

    private func handle(_ event: MQTTSession.Event, from mqtt: MQTTSession) async {
        guard mqtt === session else { return }   // a stale session after a reconnect
        switch event {
        case .connected(let leafDER):
            connected = true
            silentCloses = 0
            status = .connected
            lastError = nil
            // The broker accepted the access code: now this certificate is the printer's.
            if let leafDER { pins.commit(serial: serial, leafDER: leafDER) }
            mqtt.subscribe(BambuMQTT.reportTopic(serial: serial))
            pushAll()
            pushTask?.cancel()
            pushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(BambuMQTT.pushAllInterval))
                    self?.pushAll()
                }
            }

        case .refused(let code):
            connected = false
            if MQTTConnectReturn(rawValue: code)?.isCredentialError == true {
                // Retrying a wrong code only gets the client blocked; wait for it to be fixed.
                status = .authFailed
                lastError = "The printer refused the access code."
            } else {
                // The socket closes next; that event schedules the reconnect.
                status = .unreachable
                lastError = "The printer refused the connection (code \(code))."
            }
            emit()

        case .subscriptionRefused:
            lastError = "The printer refused the report topic. Check the serial number."

        case .message(_, let payload):
            guard let snapshot = await reports.apply(payload), mqtt === session else { return }
            lastMessage = Date()
            reconnectDelay = Self.firstReconnectDelay
            if status != .online { status = .online }
            jobKey = snapshot.jobKey
            jobStart = snapshot.jobStart
            if snapshot.changed {
                details = snapshot.details
                emit()
            }

        case .certificateRejected:
            connected = false
            status = .certificateChanged
            lastError = "The printer's certificate is not the one it had before. If you replaced or reset the printer, call trustNewCertificate()."
            emit()

        case .disconnected(let reason, let beforeConnack):
            connected = false
            pushTask?.cancel()
            guard status != .authFailed, status != .stopped, status != .certificateChanged else {
                emit()
                return
            }
            if beforeConnack {
                silentCloses += 1
                if silentCloses >= Self.silentClosesBeforeGivingUp {
                    status = .authFailed
                    lastError = "The printer closed the connection \(silentCloses) times without answering. Check the access code, and that LAN mode is on."
                    emit()
                    return
                }
            }
            status = .unreachable
            lastError = reason
            scheduleReconnect()
            emit()
        }
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(Self.maxReconnectDelay, reconnectDelay * 2)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.connect()
        }
    }

    private func pushAll() {
        guard connected, let session else { return }
        session.publish(
            BambuMQTT.requestTopic(serial: serial),
            BambuMQTT.pushAllPayload(sequence: String(Int(Date().timeIntervalSince1970 * 1000)))
        )
    }

    private func emit() {
        onUpdate?(PrinterUpdate(
            id: serial,
            name: name,
            model: model,
            online: online,
            details: details,
            jobKey: jobKey,
            jobStart: jobStart
        ))
    }
}

/// Merges reports and derives details off the main actor. An X1 sends a full
/// report about once a second; the UI shouldn't pay for every one.
actor ReportAccumulator {
    private var state: JSON = .object([:])
    private var last = PrinterDetails.empty

    struct Snapshot: Sendable {
        let details: PrinterDetails
        let changed: Bool
        let jobKey: String?
        let jobStart: Date?
    }

    func apply(_ payload: Data) -> Snapshot? {
        guard let msg = try? JSON.parse(payload), let print = msg["print"], print.isObject else { return nil }
        state = mergeReport(state, .object(["print": print]))
        let details = toPrinterDetails(state)
        let changed = details != last
        last = details
        return Snapshot(details: details, changed: changed, jobKey: reportedJobKey(state), jobStart: reportedJobStart(state))
    }
}
