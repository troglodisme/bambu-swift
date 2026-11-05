import Foundation

/*
 * Turns printer state into print jobs: a job opens when the printer starts
 * working and closes when it stops. Your app keeps the jobs; this decides
 * what a job is.
 */

/// What one printer reports, as the tracker needs it.
public struct PrinterUpdate: Equatable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    /// Connected and heard from recently.
    public var online: Bool
    public var details: PrinterDetails
    /// The printer's own id for the job, when it gives one.
    public var jobKey: String?
    /// When the printer says the job started.
    public var jobStart: Date?

    public init(id: String, name: String, model: String?, online: Bool, details: PrinterDetails, jobKey: String?, jobStart: Date?) {
        self.id = id
        self.name = name
        self.model = model
        self.online = online
        self.details = details
        self.jobKey = jobKey
        self.jobStart = jobStart
    }
}

public struct PrintJob: Equatable, Sendable, Codable, Identifiable {
    public enum Outcome: String, Sendable, Codable {
        case finished, failed, cancelled, unknown
    }

    public var id: String
    /// The printer's serial.
    public var printerID: String
    public var printerName: String
    /// The job name, "Print" when the printer gave none.
    public var label: String
    public var start: Date
    /// nil while still running.
    public var end: Date?
    public var outcome: Outcome?
    public var jobKey: String?
    public var material: String?
    public var color: String?
    public var totalLayers: Double?
    public var model: String?

    public var isOpen: Bool { end == nil }
}

public struct JobTracker: Equatable, Sendable {
    /// A FINISH or FAILED this long after the last working report ends the job then, not now.
    public static let finishGrace: TimeInterval = 10 * 60

    public private(set) var jobs: [PrintJob]
    private var lastWorking: [String: Date] = [:]

    public init(jobs: [PrintJob] = []) {
        self.jobs = jobs
    }

    public func openJob(for printerID: String) -> PrintJob? {
        jobs.last { $0.printerID == printerID && $0.end == nil }
    }

    /// Jobs that overlap the window.
    public func jobs(from: Date, to: Date, now: Date = Date()) -> [PrintJob] {
        jobs.filter { $0.start <= to && ($0.end ?? now) >= from }
    }

    /// On start-up: a job the last run left open was last seen working when
    /// that run was last alive. If its printer turns out to have stopped,
    /// that is the end it gets.
    public mutating func resume(lastAlive: Date) {
        for job in jobs where job.end == nil { lastWorking[job.printerID] = lastAlive }
    }

    /// Keeps the newest `keep` jobs, never dropping an open one.
    public mutating func prune(keep: Int) {
        guard jobs.count > keep else { return }
        let closed = jobs.filter { $0.end != nil }
        let drop = Set(closed.prefix(jobs.count - keep).map(\.id))
        jobs.removeAll { drop.contains($0.id) }
    }

    /// Applies one report. Returns the jobs that were opened, closed or amended.
    @discardableResult
    public mutating func update(_ u: PrinterUpdate, now: Date = Date()) -> [PrintJob] {
        // Offline says nothing about the job: it may well still be printing.
        guard u.online else { return [] }
        var changed: [PrintJob] = []

        let working = JOB_STATES.contains(u.details.gcodeState)
        let key = u.jobKey ?? u.details.jobName
        let open = openJob(for: u.id)
        let sameJob = open != nil && (key == nil || open?.jobKey == nil || key == open?.jobKey)

        if var job = open, !(working && sameJob) {
            let state = u.details.gcodeState
            let outcome: PrintJob.Outcome = state == "FINISH" ? .finished : state == "FAILED" ? .failed : working ? .unknown : .cancelled
            // The last moment it was seen working, not now: the app or the
            // printer may have been away when it actually stopped. A printer
            // reports FINISH until the next job starts, so "finished" seen long
            // after the last RUNNING report is an old finish, not a fresh one.
            let seenWorking = lastWorking[u.id] ?? now
            let fresh = now.timeIntervalSince(seenWorking) <= Self.finishGrace
            let end = (state == "FINISH" || state == "FAILED") && fresh ? now : seenWorking
            job.end = max(job.start, end)
            job.outcome = outcome
            save(job)
            changed.append(job)
        }

        if working { lastWorking[u.id] = now }

        if working && !(open != nil && sameJob) {
            let start = u.jobStart ?? now
            let job = PrintJob(
                id: "\(u.id):\(Int(start.timeIntervalSince1970)):\(String(UInt32.random(in: 0...UInt32.max), radix: 36))",
                printerID: u.id,
                printerName: u.name,
                label: u.details.jobName ?? "Print",
                start: start,
                end: nil,
                outcome: nil,
                jobKey: key,
                material: u.details.material,
                color: u.details.materialColor,
                totalLayers: u.details.totalLayers,
                model: u.model
            )
            save(job)
            changed.append(job)
        } else if var job = open, working {
            // Fill in what the first report of a job may not have had yet.
            var patched = false
            if job.material == nil, let m = u.details.material { job.material = m; patched = true }
            if job.color == nil, let c = u.details.materialColor { job.color = c; patched = true }
            if job.totalLayers == nil, let t = u.details.totalLayers, t != 0 { job.totalLayers = t; patched = true }
            if patched {
                save(job)
                changed.append(job)
            }
        }
        return changed
    }

    private mutating func save(_ job: PrintJob) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else {
            jobs.append(job)
            jobs.sort { $0.start < $1.start }
        }
    }
}
