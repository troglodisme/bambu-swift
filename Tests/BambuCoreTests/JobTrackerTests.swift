import XCTest
@testable import BambuCore

final class JobTrackerTests: XCTestCase {
    private func update(_ state: String, online: Bool = true, jobKey: String? = "j1", jobStart: Date? = nil) -> PrinterUpdate {
        var d = toPrinterDetails(pushall)
        d.gcodeState = state
        return PrinterUpdate(id: "p1", name: "P1", model: nil, online: online, details: d, jobKey: jobKey, jobStart: jobStart)
    }

    func testRunningThenFinishedBecomesOneClosedJob() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)

        tracker.update(update("IDLE", jobKey: nil), now: t0)
        XCTAssertEqual(tracker.jobs.count, 0)
        tracker.update(update("PREPARE"), now: t0.addingTimeInterval(10))
        tracker.update(update("RUNNING"), now: t0.addingTimeInterval(20))
        tracker.update(update("RUNNING", online: false), now: t0.addingTimeInterval(30))
        tracker.update(update("PAUSE"), now: t0.addingTimeInterval(40))
        XCTAssertEqual(tracker.jobs.count, 1)
        XCTAssertNil(tracker.jobs[0].end)
        XCTAssertEqual(tracker.jobs[0].material, "PETG")
        XCTAssertEqual(tracker.jobs[0].label, "Cable clip")
        XCTAssertEqual(tracker.jobs[0].start, t0.addingTimeInterval(10))

        let closed = tracker.update(update("FINISH"), now: t0.addingTimeInterval(50))
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(tracker.jobs[0].outcome, .finished)
        XCTAssertEqual(tracker.jobs[0].end, t0.addingTimeInterval(50))

        tracker.update(update("RUNNING", jobKey: "j2"), now: t0.addingTimeInterval(60))
        tracker.update(update("FAILED", jobKey: "j2"), now: t0.addingTimeInterval(70))
        XCTAssertEqual(tracker.jobs.map { [$0.jobKey, $0.outcome?.rawValue] }, [["j1", "finished"], ["j2", "failed"]])
    }

    func testANewKeyWhileWorkingClosesTheOldJobAsUnknown() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        tracker.update(update("RUNNING", jobKey: "a"), now: t0)
        tracker.update(update("RUNNING", jobKey: "b"), now: t0.addingTimeInterval(600))
        XCTAssertEqual(tracker.jobs.count, 2)
        XCTAssertEqual(tracker.jobs[0].outcome, .unknown)
        XCTAssertEqual(tracker.jobs[0].end, t0, "closed at the last moment it was seen working")
        XCTAssertNil(tracker.jobs[1].end)
    }

    func testIdleAfterAGapIsCancelledAtTheLastWorkingMoment() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        tracker.update(update("RUNNING"), now: t0)
        tracker.update(update("RUNNING"), now: t0.addingTimeInterval(300))
        tracker.update(update("IDLE", jobKey: nil), now: t0.addingTimeInterval(3600))
        XCTAssertEqual(tracker.jobs[0].outcome, .cancelled)
        XCTAssertEqual(tracker.jobs[0].end, t0.addingTimeInterval(300))
    }

    func testFinishSeenAfterAGapEndsAtTheLastWorkingReport() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        tracker.update(update("RUNNING"), now: t0)
        tracker.update(update("RUNNING"), now: t0.addingTimeInterval(600))
        // The Mac was asleep for six hours; the printer still says FINISH.
        tracker.update(update("FINISH"), now: t0.addingTimeInterval(6 * 3600))
        XCTAssertEqual(tracker.jobs[0].outcome, .finished)
        XCTAssertEqual(tracker.jobs[0].end, t0.addingTimeInterval(600))
        // Within the grace period the finish is fresh and ends now.
        var fresh = JobTracker()
        fresh.update(update("RUNNING"), now: t0)
        fresh.update(update("FINISH"), now: t0.addingTimeInterval(120))
        XCTAssertEqual(fresh.jobs[0].end, t0.addingTimeInterval(120))
    }

    func testPrinterClockStartsTheJob() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        tracker.update(update("RUNNING", jobStart: t0.addingTimeInterval(-900)), now: t0)
        XCTAssertEqual(tracker.jobs[0].start, t0.addingTimeInterval(-900))
    }

    func testFirstReportMissingMaterialIsFilledInLater() {
        var tracker = JobTracker()
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        var first = update("RUNNING")
        first.details.material = nil
        first.details.totalLayers = nil
        tracker.update(first, now: t0)
        XCTAssertNil(tracker.jobs[0].material)
        let changed = tracker.update(update("RUNNING"), now: t0.addingTimeInterval(5))
        XCTAssertEqual(changed.count, 1)
        XCTAssertEqual(tracker.jobs[0].material, "PETG")
        XCTAssertEqual(tracker.jobs[0].totalLayers, 240)
        XCTAssertEqual(tracker.update(update("RUNNING"), now: t0.addingTimeInterval(6)).count, 0, "nothing more to amend")
    }

    func testResumeUsesLastAliveAsTheEnd() {
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        let open = PrintJob(id: "x", printerID: "p1", printerName: "P1", label: "lid", start: t0, end: nil, outcome: nil,
                            jobKey: "j1", material: nil, color: nil, totalLayers: nil, model: nil)
        var tracker = JobTracker(jobs: [open])
        tracker.resume(lastAlive: t0.addingTimeInterval(1000))
        tracker.update(update("IDLE", jobKey: nil), now: t0.addingTimeInterval(5000))
        XCTAssertEqual(tracker.jobs[0].end, t0.addingTimeInterval(1000))
        XCTAssertEqual(tracker.jobs[0].outcome, .cancelled)
    }

    func testPruneKeepsOpenJobs() {
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        var jobs: [PrintJob] = []
        for i in 0..<5 {
            let start: Date = t0.addingTimeInterval(Double(i))
            let end: Date? = i == 0 ? nil : start.addingTimeInterval(1)
            let outcome: PrintJob.Outcome? = i == 0 ? nil : .finished
            jobs.append(PrintJob(id: String(i), printerID: "p", printerName: "P", label: "l", start: start, end: end,
                                 outcome: outcome, jobKey: nil, material: nil, color: nil, totalLayers: nil, model: nil))
        }
        var tracker = JobTracker(jobs: jobs)
        tracker.prune(keep: 2)
        let ids: [String] = tracker.jobs.map { $0.id }
        XCTAssertEqual(ids, ["0", "4"])
    }

    func testJobsCodable() throws {
        let t0 = Date(timeIntervalSince1970: 1_792_014_400)
        let job = PrintJob(id: "x", printerID: "p1", printerName: "P1", label: "lid", start: t0, end: nil, outcome: nil,
                           jobKey: "j1", material: "ABS", color: "#000000", totalLayers: 10, model: "P2S")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try dec.decode([PrintJob].self, from: enc.encode([job])), [job])
    }
}
