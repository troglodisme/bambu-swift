import XCTest
@testable import BambuCore

final class ReportTests: XCTestCase {
    func testReadsAFullReport() {
        let d = toPrinterDetails(pushall)
        XCTAssertEqual(d.gcodeState, "RUNNING")
        XCTAssertEqual(d.progress, 37)
        XCTAssertEqual(d.material, "PETG")
        XCTAssertEqual(d.materialColor, "#00ae42")
        XCTAssertEqual(d.jobName, "Cable clip")
        XCTAssertEqual(d.fans, PrinterDetails.Fans(part: 100, aux: 0, chamber: 67))
        XCTAssertNil(d.errorCode)
        XCTAssertEqual(d.wifiSignal, "-52dBm")
        XCTAssertEqual(d.nozzleTemp, 219.8)
        XCTAssertEqual(d.layer, 88)
        XCTAssertEqual(reportedJobKey(pushall), "412345678")
    }

    func testDeltasMergeIntoTheLastFullState() {
        let merged = mergeReport(pushall, ["print": ["mc_percent": 38, "layer_num": 90]])
        let d = toPrinterDetails(merged)
        XCTAssertEqual(d.progress, 38)
        XCTAssertEqual(d.layer, 90)
        XCTAssertEqual(d.material, "PETG", "untouched fields survive a delta")
    }

    func testArraysAndScalarsReplaceObjectsMerge() {
        let base: JSON = ["a": ["x": 1, "y": [1, 2]], "b": "old"]
        let out = mergeReport(base, ["a": ["y": [3]], "b": ["now": "object"]])
        XCTAssertEqual(out, ["a": ["x": 1, "y": [3]], "b": ["now": "object"]])
        XCTAssertEqual(mergeReport("scalar", ["k": 1]), ["k": 1], "a non-object base is replaced")
    }

    func testExternalSpoolAndNoAMSPrinters() {
        var print = pushall["print"]!.objectValue!
        var ams = print["ams"]!.objectValue!
        ams["tray_now"] = "254"
        print["ams"] = .object(ams)
        XCTAssertEqual(activeTray(.object(print)).type, "ABS")
        XCTAssertEqual(activeTray(["vt_tray": ["tray_type": "PLA", "tray_color": "FF0000FF"]]).color, "#ff0000")
        XCTAssertNil(activeTray([:]).type)
        XCTAssertNil(activeTray(["ams": ["tray_now": "255"]]).type)
    }

    func testSecondAMSUnit() {
        let print: JSON = [
            "ams": [
                "tray_now": "6",
                "ams": [
                    ["id": "0", "tray": [["id": "2", "tray_type": "PLA"]]],
                    ["id": "1", "tray": [["id": "2", "tray_type": "TPU", "tray_color": "123456FF"]]],
                ],
            ],
        ]
        XCTAssertEqual(activeTray(print), Tray(type: "TPU", color: "#123456"))
    }

    func testNumbersAndStringsCoerceLikeJavaScript() {
        XCTAssertEqual(num("37"), 37)
        XCTAssertEqual(num(" 12 "), 12)
        XCTAssertNil(num("-52dBm"))
        XCTAssertNil(num(""))
        XCTAssertNil(num(nil))
        XCTAssertNil(num(.null))
        XCTAssertEqual(num(true), 1)
        XCTAssertEqual(fanPercent("10"), 67)
        XCTAssertEqual(fanPercent("99"), 100)
        XCTAssertNil(str("   "))
        XCTAssertEqual(str(" x "), "x")
        XCTAssertNil(trayColor("zz0000FF"))
        XCTAssertEqual(trayColor("ABCDEF"), "#abcdef")
    }

    func testErrorCodeIsHex() {
        // 0x0300400C: the leading zero checks the padding to eight digits.
        let d = toPrinterDetails(["print": ["print_error": 50_348_044]])
        XCTAssertEqual(d.errorCode, "0300400C")
        XCTAssertEqual(toPrinterDetails(["print": ["print_error": 805_568_524]]).errorCode, "3004000C")
        XCTAssertEqual(toPrinterDetails(["print": ["print_error": "0"]]).errorCode, nil)
    }

    func testEmptyReport() {
        let d = toPrinterDetails([:])
        XCTAssertEqual(d.gcodeState, "UNKNOWN")
        XCTAssertNil(d.progress)
        XCTAssertNil(d.jobName)
        XCTAssertEqual(PrinterDetails.empty, d)
    }

    func testActivityAndSummary() {
        var d = toPrinterDetails(pushall)
        XCTAssertEqual(activityOf(d, online: false), .offline)
        XCTAssertEqual(summaryOf(d, online: false), "Offline")
        XCTAssertEqual(activityOf(d, online: true), .active)
        XCTAssertEqual(summaryOf(d, online: true), "Printing Cable clip — 37 %")
        d.gcodeState = "PAUSE"
        XCTAssertEqual(activityOf(d, online: true), .paused)
        XCTAssertEqual(summaryOf(d, online: true), "Paused Cable clip")
        d.gcodeState = "FAILED"
        XCTAssertEqual(activityOf(d, online: true), .error)
        XCTAssertEqual(summaryOf(d, online: true), "Failed Cable clip")
        d.gcodeState = "FINISH"
        XCTAssertEqual(summaryOf(d, online: true), "Finished Cable clip")
        d.gcodeState = "IDLE"
        XCTAssertEqual(activityOf(d, online: true), .idle)
        XCTAssertEqual(summaryOf(d, online: true), "Idle")
        d.gcodeState = "PREPARE"
        XCTAssertEqual(summaryOf(d, online: true), "Preparing Cable clip")
        d.gcodeState = "UNKNOWN"
        XCTAssertEqual(summaryOf(d, online: true), "Unknown")
        d.jobName = nil
        d.gcodeState = "RUNNING"
        d.progress = nil
        XCTAssertEqual(summaryOf(d, online: true), "Printing print")
    }

    func testReportedJobStart() {
        let now = Date(timeIntervalSince1970: 1_792_014_400)
        XCTAssertNil(reportedJobStart(["print": ["gcode_start_time": "0"]], now: now))
        XCTAssertNil(reportedJobStart([:], now: now))
        XCTAssertEqual(reportedJobStart(["print": ["gcode_start_time": "1792010800"]], now: now), Date(timeIntervalSince1970: 1_792_010_800))
        XCTAssertNil(reportedJobStart(["print": ["gcode_start_time": "1792014500"]], now: now), "a minute and more in the future")
        XCTAssertNil(reportedJobStart(["print": ["gcode_start_time": "1791000000"]], now: now), "days ago")
    }

    func testReportedJobKeyFallsBack() {
        XCTAssertEqual(reportedJobKey(["print": ["task_id": 412_345_678]]), "412345678")
        XCTAssertEqual(reportedJobKey(["print": ["job_id": "77"]]), "77")
        // A task_id of "0" is "no task", and job_id is only read when task_id is absent.
        XCTAssertEqual(reportedJobKey(["print": ["task_id": "0", "job_id": "77", "subtask_name": "lid.3mf"]]), "lid.3mf")
        XCTAssertEqual(reportedJobKey(["print": ["task_id": "0", "subtask_name": "lid.3mf"]]), "lid.3mf")
        XCTAssertEqual(reportedJobKey(["print": ["gcode_file": "/data/x.gcode"]]), "/data/x.gcode")
        XCTAssertNil(reportedJobKey([:]))
    }

    func testJSONRoundTrip() throws {
        let data = try pushall.serialized()
        XCTAssertEqual(try JSON.parse(data), pushall)
        XCTAssertEqual(try JSON.parse(Data(#"{"a":[1,"x",true,null,{"b":2.5}]}"#.utf8)), ["a": [1, "x", true, nil, ["b": 2.5]]])
    }
}
