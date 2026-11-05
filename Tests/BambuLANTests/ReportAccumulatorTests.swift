import Foundation
import XCTest
@testable import BambuLAN

final class ReportAccumulatorTests: XCTestCase {
    func testMergesPartialReportsAndFlagsChanges() async throws {
        let reports = ReportAccumulator()

        let full = Data(#"{"print":{"gcode_state":"RUNNING","mc_percent":10,"nozzle_temper":220,"subtask_name":"benchy"}}"#.utf8)
        let firstResult = await reports.apply(full)
        let first = try XCTUnwrap(firstResult)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.details.gcodeState, "RUNNING")
        XCTAssertEqual(first.details.progress, 10)

        // A partial update keeps everything it doesn't mention.
        let delta = Data(#"{"print":{"mc_percent":11}}"#.utf8)
        let secondResult = await reports.apply(delta)
        let second = try XCTUnwrap(secondResult)
        XCTAssertTrue(second.changed)
        XCTAssertEqual(second.details.progress, 11)
        XCTAssertEqual(second.details.nozzleTemp, 220)

        // The same values again: nothing changed.
        let thirdResult = await reports.apply(delta)
        let third = try XCTUnwrap(thirdResult)
        XCTAssertFalse(third.changed)
    }

    func testIgnoresMessagesWithoutAPrintObject() async {
        let reports = ReportAccumulator()
        let none = await reports.apply(Data(#"{"info":{"command":"get_version"}}"#.utf8))
        XCTAssertNil(none)
        let garbage = await reports.apply(Data("not json".utf8))
        XCTAssertNil(garbage)
    }
}
