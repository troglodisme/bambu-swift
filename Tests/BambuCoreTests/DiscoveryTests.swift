import XCTest
@testable import BambuCore

final class DiscoveryTests: XCTestCase {
    let notify = [
        "NOTIFY * HTTP/1.1",
        "HOST: 239.255.255.250:1990",
        "Server: UPnP/1.0",
        "Location: 192.168.1.50",
        "NT: urn:bambulab-com:device:3dprinter:1",
        "USN: 01P00A123456789",
        "DevModel.bambu.com: C12",
        "DevName.bambu.com: Workshop P1S",
        "DevConnect.bambu.com: lan",
    ].joined(separator: "\r\n")

    func testReadsAPrinterAnnouncement() {
        let d = parseNotify(notify, from: "192.168.1.50")
        XCTAssertEqual(d?.serial, "01P00A123456789")
        XCTAssertEqual(d?.model, "P1S")
        XCTAssertEqual(d?.name, "Workshop P1S")
        XCTAssertEqual(d?.host, "192.168.1.50")
        XCTAssertEqual(d?.connection, "lan")
    }

    func testOtherSSDPDevicesAreIgnored() {
        XCTAssertNil(parseNotify("NOTIFY * HTTP/1.1\r\nUSN: x", from: "1.2.3.4"))
        XCTAssertNil(parseNotify("M-SEARCH * HTTP/1.1\r\nST: bambu", from: "1.2.3.4"))
        XCTAssertNil(parseNotify("NOTIFY * HTTP/1.1\r\nNT: urn:bambulab-com:device:3dprinter:1", from: "1.2.3.4"), "no serial")
    }

    func testFallsBackToTheSenderAndKeepsUnknownModelCodes() {
        let text = "NOTIFY * HTTP/1.1\nNT: urn:bambulab-com:device:3dprinter:1\nUSN: S1\nDevModel.bambu.com: Z9"
        let d = parseNotify(text, from: "10.0.0.7")
        XCTAssertEqual(d?.host, "10.0.0.7")
        XCTAssertEqual(d?.model, "Z9")
        XCTAssertNil(d?.name)
        XCTAssertEqual(d?.displayName, "S1")
    }

    func testLocationMustBeAPrivateAddress() {
        let header = "NOTIFY * HTTP/1.1\r\nNT: urn:bambulab-com:device:3dprinter:1\r\nUSN: S1\r\nLocation: "
        XCTAssertEqual(parseNotify(header + "http://evil.example/path", from: "10.0.0.9")?.host, "10.0.0.9", "falls back to the sender")
        XCTAssertEqual(parseNotify(header + "8.8.8.8", from: "10.0.0.9")?.host, "10.0.0.9", "a public address is not a printer")
        XCTAssertEqual(parseNotify(header + "192.168.1.50", from: "10.0.0.9")?.host, "192.168.1.50")
        XCTAssertTrue(isPrivateAddress("10.1.2.3"))
        XCTAssertTrue(isPrivateAddress("172.20.0.1"))
        XCTAssertFalse(isPrivateAddress("172.32.0.1"))
        XCTAssertTrue(isPrivateAddress("169.254.10.10"))
        XCTAssertTrue(isPrivateAddress("fe80::1"))
        XCTAssertTrue(isPrivateAddress("fd12:3456::1"))
        XCTAssertFalse(isPrivateAddress("2001:db8::1"))
        XCTAssertFalse(isPrivateAddress("p1s.local"))
        XCTAssertFalse(isPrivateAddress("192.168.1"))
        XCTAssertFalse(isPrivateAddress(""))
    }

    func testCleanedHost() {
        XCTAssertEqual(cleanedHost(" 192.168.1.50 "), "192.168.1.50")
        XCTAssertEqual(cleanedHost("192.168.1.50:8883"), "192.168.1.50")
        XCTAssertEqual(cleanedHost("mqtts://192.168.1.50:8883/"), "192.168.1.50")
        XCTAssertEqual(cleanedHost("p1s.local"), "p1s.local")
        XCTAssertEqual(cleanedHost("fe80::1"), "fe80::1")
        XCTAssertNil(cleanedHost(""))
        XCTAssertNil(cleanedHost("192.168.1.50 x"))
    }

    func testTableForgetsQuietPrintersAndSortsByName() {
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        var table = DiscoveryTable()
        table.note(parseNotify(notify, from: "192.168.1.50", now: t0)!)
        table.note(DiscoveredPrinter(host: "192.168.1.51", serial: "A1", name: "Attic A1", model: "A1", connection: nil, lastSeen: t0.addingTimeInterval(60)))
        XCTAssertEqual(table.list(now: t0.addingTimeInterval(90)).map(\.serial), ["A1", "01P00A123456789"])
        XCTAssertEqual(table.list(now: t0.addingTimeInterval(150)).map(\.serial), ["A1"], "the P1S has been quiet for over two minutes")
        table.note(parseNotify(notify, from: "192.168.1.50", now: t0.addingTimeInterval(150))!)
        XCTAssertEqual(table.list(now: t0.addingTimeInterval(150)).count, 2)
    }
}
