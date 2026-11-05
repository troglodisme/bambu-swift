import Foundation
import Network
import BambuCore

/// Finds Bambu Lab printers on the local network by listening on UDP 2021
/// for their announcements.
///
/// Apps need the `com.apple.security.network.server` entitlement when
/// sandboxed and, on macOS 15+ and iOS, the Local Network permission
/// (`NSLocalNetworkUsageDescription`). Another app (Bambu Studio, Home
/// Assistant) may already hold the port; connecting by IP still works then.
///
/// ```swift
/// let discovery = BambuDiscovery { printer in
///     print(printer.displayName, printer.host)
/// }
/// discovery.start()
/// ```
public final class BambuDiscovery: @unchecked Sendable {
    public static let port: NWEndpoint.Port = 2021

    private let queue = DispatchQueue(label: "bambu-swift.discovery")
    private var listener: NWListener?
    private let onPrinter: @Sendable (DiscoveredPrinter) -> Void
    private let onState: @Sendable (_ listening: Bool, _ error: String?) -> Void

    /// - Parameters:
    ///   - onPrinter: called for every announcement, on a background queue.
    ///     Feed them to a ``BambuCore/DiscoveryTable`` to get a list without duplicates.
    ///   - onState: whether the listener is ready, or why not.
    public init(
        onPrinter: @escaping @Sendable (DiscoveredPrinter) -> Void,
        onState: @escaping @Sendable (_ listening: Bool, _ error: String?) -> Void = { _, _ in }
    ) {
        self.onPrinter = onPrinter
        self.onState = onState
    }

    public func start() {
        queue.async { [self] in
            do {
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                let l = try NWListener(using: parameters, on: Self.port)
                l.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.onState(true, nil)
                    case .failed(let error): self?.onState(false, error.localizedDescription)
                    case .cancelled: self?.onState(false, nil)
                    default: break
                    }
                }
                l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener = l
                l.start(queue: queue)
            } catch {
                onState(false, error.localizedDescription)
            }
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    /// One datagram per inbound flow, then the flow is closed: a printer that
    /// announces from a fresh port each time would otherwise leave thousands
    /// of idle flows behind.
    private func accept(_ connection: NWConnection) {
        var from = ""
        if case .hostPort(let host, _) = connection.endpoint { from = "\(host)" }
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: queue)
        connection.receiveMessage { [weak self] data, _, _, _ in
            if let self, let data, let text = String(data: data, encoding: .utf8), let printer = parseNotify(text, from: from) {
                onPrinter(printer)
            }
            connection.cancel()
        }
    }
}
