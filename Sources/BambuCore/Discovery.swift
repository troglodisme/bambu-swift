import Foundation

/*
 * Finds Bambu printers on the local network. They announce themselves every
 * few seconds with an SSDP-style NOTIFY broadcast on UDP 2021, carrying the
 * IP, serial, model code and the name set in the Bambu app. Everything except
 * the LAN access code, which only the printer's screen shows.
 * This is the parsing; BambuLAN's BambuDiscovery does the listening.
 */

public struct DiscoveredPrinter: Equatable, Sendable, Identifiable {
    public var host: String
    public var serial: String
    public var name: String?
    public var model: String?
    /// "lan" when the printer is in LAN-only mode, "cloud" otherwise.
    public var connection: String?
    public var lastSeen: Date

    public var id: String { serial }
    public var displayName: String { name ?? serial }
}

/// Bambu's model codes, as the printers announce them.
public let BAMBU_MODELS: [String: String] = [
    "3DPrinter-X1-Carbon": "X1 Carbon",
    "3DPrinter-X1": "X1",
    "BL-P001": "X1 Carbon",
    "BL-P002": "X1",
    "C13": "X1E",
    "C11": "P1P",
    "C12": "P1S",
    "N7": "P2S",
    "N1": "A1 mini",
    "N2S": "A1",
    "O1D": "H2D",
    "O1S": "H2S",
]

public func parseNotify(_ text: String, from: String, now: Date = Date()) -> DiscoveredPrinter? {
    let lower = text.lowercased()
    guard lower.hasPrefix("notify") || lower.hasPrefix("http/1.1 200"), lower.contains("bambu") else { return nil }
    var headers: [String: String] = [:]
    for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
        guard let i = line.firstIndex(of: ":"), i > line.startIndex else { continue }
        let name = line[..<i].trimmingCharacters(in: .whitespaces).lowercased()
        headers[name] = line[line.index(after: i)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let serial = headers["usn"], !serial.isEmpty else { return nil }
    let code = headers["devmodel.bambu.com"]
    let location = headers["location"] ?? ""
    // The printer puts its own LAN IP here. The datagram is unauthenticated, so
    // anything that is not a private address (a URL, a public IP, a hostname)
    // must not become the address the app connects and sends an access code to.
    let host = isPrivateAddress(location) ? location : from
    return DiscoveredPrinter(
        host: host,
        serial: serial,
        name: headers["devname.bambu.com"].flatMap { $0.isEmpty ? nil : $0 },
        model: code.map { BAMBU_MODELS[$0] ?? $0 },
        connection: headers["devconnect.bambu.com"],
        lastSeen: now
    )
}

/// An IPv4 or IPv6 literal in a range that only exists on a local network:
/// 10/8, 172.16/12, 192.168/16, 169.254/16, fe80::/10, fc00::/7.
public func isPrivateAddress(_ s: String) -> Bool {
    let parts = s.split(separator: ".", omittingEmptySubsequences: false)
    if parts.count == 4, let o = Optional(parts.compactMap { UInt8($0) }), o.count == 4 {
        if o[0] == 10 { return true }
        if o[0] == 172, (16...31).contains(o[1]) { return true }
        if o[0] == 192, o[1] == 168 { return true }
        if o[0] == 169, o[1] == 254 { return true }
        return false
    }
    let lower = s.lowercased()
    guard lower.contains(":"), lower.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return false }
    if lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
    if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
    return false
}

/// What the person typed as a host: strips a scheme, a path and the MQTT port,
/// keeps an address or a plain hostname, or returns nil.
public func cleanedHost(_ raw: String) -> String? {
    var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for scheme in ["mqtts://", "mqtt://", "https://", "http://"] where s.lowercased().hasPrefix(scheme) {
        s = String(s.dropFirst(scheme.count))
    }
    if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
    // "host:8883" but not an IPv6 literal.
    if s.filter({ $0 == ":" }).count == 1, let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
    guard !s.isEmpty, s.count <= 253,
          s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == ":" || $0 == "-") })
    else { return nil }
    return s
}

/// What has announced itself lately, by serial.
public struct DiscoveryTable: Equatable, Sendable {
    public static let forgetAfter: TimeInterval = 2 * 60
    private var found: [String: DiscoveredPrinter] = [:]

    public init() {}

    public mutating func note(_ d: DiscoveredPrinter) {
        found[d.serial] = d
    }

    public func list(now: Date = Date()) -> [DiscoveredPrinter] {
        let cutoff = now.addingTimeInterval(-Self.forgetAfter)
        return found.values
            .filter { $0.lastSeen > cutoff }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
