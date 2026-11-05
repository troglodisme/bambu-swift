import XCTest
@testable import BambuCore

final class MQTTTests: XCTestCase {
    func testRemainingLength() {
        XCTAssertEqual(MQTT.encodeRemainingLength(0), [0x00])
        XCTAssertEqual(MQTT.encodeRemainingLength(127), [0x7F])
        XCTAssertEqual(MQTT.encodeRemainingLength(128), [0x80, 0x01])
        XCTAssertEqual(MQTT.encodeRemainingLength(321), [0xC1, 0x02])
        XCTAssertEqual(MQTT.encodeRemainingLength(16_383), [0xFF, 0x7F])
        XCTAssertEqual(MQTT.encodeRemainingLength(2_097_152), [0x80, 0x80, 0x80, 0x01])
        for n in [0, 1, 127, 128, 321, 16_383, 16_384, 2_097_151, 2_097_152, 268_435_455] {
            let bytes = [0x30] + MQTT.encodeRemainingLength(n)
            let r = MQTT.decodeRemainingLength(bytes, from: 1)
            XCTAssertEqual(r.value, n)
            XCTAssertEqual(r.consumed, bytes.count - 1)
            XCTAssertFalse(r.malformed)
        }
        XCTAssertEqual(MQTT.decodeRemainingLength([0x30, 0x80], from: 1).consumed, 0, "incomplete")
        XCTAssertTrue(MQTT.decodeRemainingLength([0x30, 0x80, 0x80, 0x80, 0x80, 0x01], from: 1).malformed)
    }

    func testConnectPacketBytes() {
        let packet = MQTT.connect(clientID: "a", username: "bblp", password: "x", keepAlive: 60)
        let expected: [UInt8] = [
            0x10, 0x16,
            0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, // "MQTT"
            0x04,                               // protocol level 3.1.1
            0xC2,                               // username, password, clean session
            0x00, 0x3C,                         // keep alive 60
            0x00, 0x01, 0x61,                   // client id "a"
            0x00, 0x04, 0x62, 0x62, 0x6C, 0x70, // "bblp"
            0x00, 0x01, 0x78,                   // "x"
        ]
        XCTAssertEqual(Array(packet), expected)
    }

    func testSubscribeAndPublishBytes() {
        XCTAssertEqual(Array(MQTT.subscribe(packetID: 1, topic: "a/b")), [0x82, 0x08, 0x00, 0x01, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x00])
        XCTAssertEqual(Array(MQTT.publish(topic: "a/b", payload: Data("hi".utf8))), [0x30, 0x07, 0x00, 0x03, 0x61, 0x2F, 0x62, 0x68, 0x69])
        XCTAssertEqual(Array(MQTT.puback(packetID: 0x0102)), [0x40, 0x02, 0x01, 0x02])
        XCTAssertEqual(Array(MQTT.pingreq), [0xC0, 0x00])
        XCTAssertEqual(Array(MQTT.disconnect), [0xE0, 0x00])
    }

    func testDecodesConnackPublishSubackPingresp() {
        var d = MQTTDecoder()
        XCTAssertEqual(d.feed(Data([0x20, 0x02, 0x00, 0x00])), [.connack(sessionPresent: false, returnCode: 0)])
        XCTAssertEqual(d.feed(Data([0x20, 0x02, 0x01, 0x05])), [.connack(sessionPresent: true, returnCode: 5)])
        XCTAssertEqual(d.feed(MQTT.publish(topic: "device/S/report", payload: Data("{}".utf8))),
                       [.publish(topic: "device/S/report", payload: Data("{}".utf8), qos: 0, packetID: nil)])
        // QoS 1 publish carries a packet id after the topic.
        XCTAssertEqual(d.feed(Data([0x32, 0x07, 0x00, 0x01, 0x74, 0x00, 0x2A, 0x68, 0x69])),
                       [.publish(topic: "t", payload: Data("hi".utf8), qos: 1, packetID: 42)])
        XCTAssertEqual(d.feed(Data([0x90, 0x03, 0x00, 0x01, 0x00])), [.suback(packetID: 1, returnCodes: [0])])
        XCTAssertEqual(d.feed(Data([0xD0, 0x00])), [.pingresp])
        XCTAssertEqual(d.feed(Data([0x40, 0x02, 0x00, 0x07])), [.puback(packetID: 7)])
        XCTAssertEqual(d.feed(Data([0xE0, 0x00])), [.other(type: 14)])
    }

    func testPacketsSplitAcrossChunksAndJoinedInOne() {
        var d = MQTTDecoder()
        let big = MQTT.publish(topic: "t", payload: Data(repeating: 0x41, count: 300)) // two-byte remaining length
        let bytes = Array(big)
        XCTAssertEqual(d.feed(Data(bytes[0..<1])), [])
        XCTAssertEqual(d.feed(Data(bytes[1..<2])), [], "length field still incomplete")
        XCTAssertEqual(d.feed(Data(bytes[2..<100])), [])
        let packets = d.feed(Data(bytes[100...]) + Data([0xD0, 0x00]) + Data([0x20, 0x02]))
        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[1], .pingresp)
        if case .publish(let topic, let payload, _, _) = packets[0] {
            XCTAssertEqual(topic, "t")
            XCTAssertEqual(payload.count, 300)
        } else {
            XCTFail("expected a publish")
        }
        XCTAssertEqual(d.feed(Data([0x00, 0x00])), [.connack(sessionPresent: false, returnCode: 0)], "the connack straddled two feeds")
    }

    func testMalformedLengthResets() {
        var d = MQTTDecoder()
        XCTAssertEqual(d.feed(Data([0x30, 0x80, 0x80, 0x80, 0x80, 0x01])), [.malformed])
        XCTAssertEqual(d.feed(Data([0xD0, 0x00])), [.pingresp], "fresh after the reset")
        XCTAssertEqual(d.feed(Data([0x20, 0x01, 0x00])), [.malformed], "connack too short")
    }

    func testOversizedPacketIsRefused() {
        var d = MQTTDecoder()
        let header: [UInt8] = [0x30] + MQTT.encodeRemainingLength(MQTTDecoder.maxPacketLength + 1)
        XCTAssertEqual(d.feed(Data(header)), [.malformed])
        XCTAssertEqual(d.feed(Data([0xD0, 0x00])), [.pingresp])
    }

    func testConnectReturnCodes() {
        XCTAssertTrue(MQTTConnectReturn(rawValue: 4)!.isCredentialError)
        XCTAssertTrue(MQTTConnectReturn(rawValue: 5)!.isCredentialError)
        XCTAssertFalse(MQTTConnectReturn(rawValue: 3)!.isCredentialError)
        XCTAssertNil(MQTTConnectReturn(rawValue: 9))
    }

    func testBambuTopicsAndPushAll() throws {
        XCTAssertEqual(BambuMQTT.reportTopic(serial: "S1"), "device/S1/report")
        XCTAssertEqual(BambuMQTT.requestTopic(serial: "S1"), "device/S1/request")
        let json = try JSON.parse(BambuMQTT.pushAllPayload(sequence: "7"))
        XCTAssertEqual(json["pushing"]?["command"], "pushall")
        XCTAssertEqual(json["pushing"]?["sequence_id"], "7")
        XCTAssertEqual(json["pushing"]?["version"], 1)
    }
}
