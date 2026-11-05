import Foundation

/*
 * MQTT 3.1.1, the part a Bambu printer needs: CONNECT with a username and
 * password, SUBSCRIBE at QoS 0, PUBLISH at QoS 0, PINGREQ, DISCONNECT, and
 * decoding what comes back. Hand-rolled over Network.framework so the app
 * carries no third-party networking code and owns the certificate check.
 * Spec: OASIS MQTT 3.1.1, sections 2 and 3.
 */

public enum MQTTConnectReturn: UInt8, Sendable {
    case accepted = 0
    case unacceptableProtocolVersion = 1
    case identifierRejected = 2
    case serverUnavailable = 3
    case badCredentials = 4
    case notAuthorized = 5

    public var isCredentialError: Bool { self == .badCredentials || self == .notAuthorized }
}

public enum MQTTPacket: Equatable, Sendable {
    case connack(sessionPresent: Bool, returnCode: UInt8)
    case publish(topic: String, payload: Data, qos: UInt8, packetID: UInt16?)
    case puback(packetID: UInt16)
    case suback(packetID: UInt16, returnCodes: [UInt8])
    case pingresp
    case other(type: UInt8)
    case malformed
}

public enum MQTT {
    /// Variable-length remaining-length field (section 2.2.3).
    public static func encodeRemainingLength(_ length: Int) -> [UInt8] {
        precondition(length >= 0 && length <= 268_435_455)
        var x = length
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    /// Returns (value, bytes consumed), nil while incomplete; `malformed` set when over 4 bytes.
    static func decodeRemainingLength(_ bytes: [UInt8], from index: Int) -> (value: Int, consumed: Int, malformed: Bool) {
        var multiplier = 1
        var value = 0
        var i = index
        while i < bytes.count {
            let b = bytes[i]
            value += Int(b & 0x7F) * multiplier
            i += 1
            if b & 0x80 == 0 { return (value, i - index, false) }
            multiplier *= 128
            if i - index >= 4 { return (0, 0, true) }
        }
        return (0, 0, false)
    }

    static func utf8String(_ s: String) -> [UInt8] {
        let u = Array(s.utf8)
        return [UInt8(u.count >> 8), UInt8(u.count & 0xFF)] + u
    }

    static func packet(type: UInt8, flags: UInt8 = 0, body: [UInt8]) -> Data {
        Data([type << 4 | flags] + encodeRemainingLength(body.count) + body)
    }

    public static func connect(clientID: String, username: String?, password: String?, keepAlive: UInt16, cleanSession: Bool = true) -> Data {
        var flags: UInt8 = cleanSession ? 0x02 : 0
        if username != nil { flags |= 0x80 }
        if password != nil { flags |= 0x40 }
        var body = utf8String("MQTT") + [0x04, flags, UInt8(keepAlive >> 8), UInt8(keepAlive & 0xFF)]
        body += utf8String(clientID)
        if let username { body += utf8String(username) }
        if let password { body += utf8String(password) }
        return packet(type: 1, body: body)
    }

    public static func subscribe(packetID: UInt16, topic: String, qos: UInt8 = 0) -> Data {
        packet(type: 8, flags: 0x02, body: [UInt8(packetID >> 8), UInt8(packetID & 0xFF)] + utf8String(topic) + [qos])
    }

    /// QoS 0, not retained.
    public static func publish(topic: String, payload: Data) -> Data {
        packet(type: 3, body: utf8String(topic) + Array(payload))
    }

    /// Acknowledges a QoS 1 PUBLISH. We subscribe at QoS 0, but a broker may still send QoS 1.
    public static func puback(packetID: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
    }

    public static let pingreq = Data([0xC0, 0x00])
    public static let disconnect = Data([0xE0, 0x00])
}

/// Accumulates bytes from the socket and yields whole packets.
public struct MQTTDecoder: Sendable {
    /// A pushall is 10-30 KB; anything claiming more than this is not a printer talking.
    public static let maxPacketLength = 1_048_576

    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ data: Data) -> [MQTTPacket] {
        buffer.append(contentsOf: data)
        var out: [MQTTPacket] = []
        while buffer.count >= 2 {
            let (length, consumed, malformed) = MQTT.decodeRemainingLength(buffer, from: 1)
            if malformed || (consumed > 0 && length > Self.maxPacketLength) {
                buffer.removeAll()
                out.append(.malformed)
                break
            }
            guard consumed > 0 else { break }                  // length field incomplete
            let total = 1 + consumed + length
            guard buffer.count >= total else { break }         // body incomplete
            let first = buffer[0]
            let body = Array(buffer[(1 + consumed)..<total])
            buffer.removeFirst(total)
            out.append(Self.decode(first: first, body: body))
        }
        return out
    }

    static func decode(first: UInt8, body: [UInt8]) -> MQTTPacket {
        switch first >> 4 {
        case 2:
            guard body.count >= 2 else { return .malformed }
            return .connack(sessionPresent: body[0] & 0x01 == 1, returnCode: body[1])
        case 3:
            let qos = (first >> 1) & 0x03
            guard body.count >= 2 else { return .malformed }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            guard body.count >= 2 + topicLength, let topic = String(bytes: body[2..<(2 + topicLength)], encoding: .utf8) else { return .malformed }
            var i = 2 + topicLength
            var packetID: UInt16?
            if qos > 0 {
                guard body.count >= i + 2 else { return .malformed }
                packetID = UInt16(body[i]) << 8 | UInt16(body[i + 1])
                i += 2
            }
            return .publish(topic: topic, payload: Data(body[i...]), qos: qos, packetID: packetID)
        case 4:
            guard body.count >= 2 else { return .malformed }
            return .puback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]))
        case 9:
            guard body.count >= 2 else { return .malformed }
            return .suback(packetID: UInt16(body[0]) << 8 | UInt16(body[1]), returnCodes: Array(body[2...]))
        case 13:
            return .pingresp
        default:
            return .other(type: first >> 4)
        }
    }
}

/// The printer's topics and the one request we send.
public enum BambuMQTT {
    public static let port: UInt16 = 8883
    public static let username = "bblp"
    public static let keepAlive: UInt16 = 60
    /// P1-series boards struggle with pushall more often than every few minutes.
    public static let pushAllInterval: TimeInterval = 5 * 60

    public static func reportTopic(serial: String) -> String { "device/\(serial)/report" }
    public static func requestTopic(serial: String) -> String { "device/\(serial)/request" }

    public static func pushAllPayload(sequence: String) -> Data {
        let json: JSON = ["pushing": ["sequence_id": .string(sequence), "command": "pushall", "version": 1, "push_target": 1]]
        return (try? json.serialized()) ?? Data()
    }
}
