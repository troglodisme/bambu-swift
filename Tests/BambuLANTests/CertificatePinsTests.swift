import Foundation
import XCTest
@testable import BambuLAN

final class CertificatePinsTests: XCTestCase {
    let first = Data("first certificate".utf8)
    let second = Data("second certificate".utf8)

    func testFingerprintIsLowercaseHexSHA256() {
        // SHA-256 of the empty string.
        XCTAssertEqual(certificateFingerprint(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testFirstCertificateIsTrustedUntilCommitted() {
        let pins = MemoryPinStore()
        XCTAssertTrue(pins.matches(serial: "A", leafDER: first))
        XCTAssertTrue(pins.matches(serial: "A", leafDER: second))
        XCTAssertFalse(pins.has("A"), "matching never records a pin")
    }

    func testCommittedPinRejectsADifferentCertificate() {
        let pins = MemoryPinStore()
        pins.commit(serial: "A", leafDER: first)
        XCTAssertTrue(pins.matches(serial: "A", leafDER: first))
        XCTAssertFalse(pins.matches(serial: "A", leafDER: second))
        XCTAssertTrue(pins.matches(serial: "B", leafDER: second), "pins are per serial")
    }

    func testCommitDoesNotOverwriteAnExistingPin() {
        let pins = MemoryPinStore()
        pins.commit(serial: "A", leafDER: first)
        pins.commit(serial: "A", leafDER: second)
        XCTAssertEqual(pins.pin(for: "A"), certificateFingerprint(first))
    }

    func testForgetTrustsTheNextCertificate() {
        let pins = MemoryPinStore()
        pins.commit(serial: "A", leafDER: first)
        pins.forget("A")
        XCTAssertTrue(pins.matches(serial: "A", leafDER: second))
        pins.commit(serial: "A", leafDER: second)
        XCTAssertEqual(pins.pin(for: "A"), certificateFingerprint(second))
    }

    func testUserDefaultsStoreSurvivesANewInstance() throws {
        let suite = "bambu-swift-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        UserDefaultsPinStore(defaults: defaults).commit(serial: "A", leafDER: first)
        let reopened = UserDefaultsPinStore(defaults: defaults)
        XCTAssertTrue(reopened.has("A"))
        XCTAssertFalse(reopened.matches(serial: "A", leafDER: second))
    }
}
