import Foundation

/*
 * Pure helpers for Bambu Lab's MQTT "report" messages.
 *
 * X1 printers push the whole state every second or so. P1 and A1 printers
 * push only the fields that changed, so the client keeps one merged object
 * per printer and reads everything from that. A "pushall" request asks for
 * the full state once (on connect, and again every few minutes).
 */

/// Merges a report delta into the accumulated state. Objects merge; arrays and scalars replace.
public func mergeReport(_ base: JSON, _ delta: JSON) -> JSON {
    guard case .object(var out) = base, case .object(let d) = delta else { return delta }
    for (key, value) in d {
        if value.isObject, let prev = out[key], prev.isObject {
            out[key] = mergeReport(prev, value)
        } else {
            out[key] = value
        }
    }
    return .object(out)
}

/// JavaScript's `Number(v)` for the values a report carries: numbers, numeric strings, booleans.
func num(_ v: JSON?) -> Double? {
    switch v {
    case .number(let d): return d.isFinite ? d : nil
    case .string(let s):
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        guard let d = Double(t), d.isFinite else { return nil }
        return d
    case .bool(let b): return b ? 1 : 0
    default: return nil
    }
}

func str(_ v: JSON?) -> String? {
    guard case .string(let s) = v else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

/// Fan speeds arrive as "0".."15" steps; shown as a percentage.
func fanPercent(_ v: JSON?) -> Double? {
    guard let n = num(v) else { return nil }
    return (min(15, max(0, n)) / 15 * 100).rounded()
}

/// "FF8800FF" -> "#ff8800".
func trayColor(_ v: JSON?) -> String? {
    guard let s = str(v), s.count >= 6 else { return nil }
    let hex = s.prefix(6)
    guard hex.allSatisfy({ $0.isHexDigit }) else { return nil }
    return "#" + hex.lowercased()
}

public struct Tray: Equatable, Sendable {
    public let type: String?
    public let color: String?
    public init(type: String?, color: String?) {
        self.type = type
        self.color = color
    }
}

/// The tray feeding the nozzle. `ams.tray_now` is "255" for none, "254" for
/// the external spool holder, otherwise AMS unit * 4 + slot.
public func activeTray(_ print: JSON) -> Tray {
    let ams = print["ams"]?.objectValue ?? [:]
    let external = print["vt_tray"].flatMap { $0.isObject ? $0 : nil }
    let now = num(ams["tray_now"])

    if now == 254, let external {
        return Tray(type: str(external["tray_type"]), color: trayColor(external["tray_color"]))
    }
    if let now, now < 254, let units = ams["ams"]?.arrayValue {
        let slot = Int(now)
        let unit = units.first { $0.isObject && num($0["id"]).map { Int($0) } == slot / 4 }
        let trays = unit?["tray"]?.arrayValue ?? []
        if let tray = trays.first(where: { num($0["id"]).map { Int($0) } == slot % 4 }) {
            return Tray(type: str(tray["tray_type"]), color: trayColor(tray["tray_color"]))
        }
    }
    // No AMS (A1 mini, P1P): the external spool is the only spool.
    if let external {
        return Tray(type: str(external["tray_type"]), color: trayColor(external["tray_color"]))
    }
    return Tray(type: nil, color: nil)
}

public struct PrinterDetails: Equatable, Sendable, Codable {
    public struct Fans: Equatable, Sendable, Codable {
        /// Part cooling, aux (side) and chamber (exhaust), 0-100 %.
        public var part: Double?
        public var aux: Double?
        public var chamber: Double?
        public init(part: Double?, aux: Double?, chamber: Double?) {
            self.part = part
            self.aux = aux
            self.chamber = chamber
        }
    }

    /// Bambu's own state word: IDLE, PREPARE, RUNNING, PAUSE, FINISH, FAILED, ...
    public var gcodeState: String
    /// 0-100.
    public var progress: Double?
    public var remainingMin: Double?
    public var layer: Double?
    public var totalLayers: Double?
    public var nozzleTemp: Double?
    public var nozzleTarget: Double?
    public var bedTemp: Double?
    public var bedTarget: Double?
    public var chamberTemp: Double?
    /// Filament type of the active tray, e.g. PLA, PETG, ABS.
    public var material: String?
    /// #rrggbb of the active tray.
    public var materialColor: String?
    public var jobName: String?
    public var fans: Fans
    /// Non-zero Bambu print_error code, as hex.
    public var errorCode: String?
    public var wifiSignal: String?

    public static let empty = toPrinterDetails(.object([:]))
}

public func toPrinterDetails(_ state: JSON) -> PrinterDetails {
    let p = state["print"].flatMap { $0.isObject ? $0 : nil } ?? .object([:])
    let tray = activeTray(p)
    let err = num(p["print_error"]) ?? 0
    return PrinterDetails(
        gcodeState: str(p["gcode_state"]) ?? "UNKNOWN",
        progress: num(p["mc_percent"]),
        remainingMin: num(p["mc_remaining_time"]),
        layer: num(p["layer_num"]),
        totalLayers: num(p["total_layer_num"]),
        nozzleTemp: num(p["nozzle_temper"]),
        nozzleTarget: num(p["nozzle_target_temper"]),
        bedTemp: num(p["bed_temper"]),
        bedTarget: num(p["bed_target_temper"]),
        chamberTemp: num(p["chamber_temper"]),
        material: tray.type,
        materialColor: tray.color,
        jobName: str(p["subtask_name"]) ?? str(p["gcode_file"]),
        fans: PrinterDetails.Fans(
            part: fanPercent(p["cooling_fan_speed"]),
            aux: fanPercent(p["big_fan1_speed"]),
            chamber: fanPercent(p["big_fan2_speed"])
        ),
        errorCode: err != 0 ? hex8(err) : nil,
        wifiSignal: str(p["wifi_signal"])
    )
}

private func hex8(_ v: Double) -> String {
    let s = String(UInt64(max(0, v)), radix: 16).uppercased()
    return String(repeating: "0", count: max(0, 8 - s.count)) + s
}

/// gcode_state values during which the machine is working on a job.
public let JOB_STATES: Set<String> = ["PREPARE", "SLICING", "RUNNING", "PAUSE"]

public enum PrinterActivity: String, Sendable, Equatable, Codable {
    case active, paused, idle, error, offline
}

public func activityOf(_ d: PrinterDetails, online: Bool) -> PrinterActivity {
    if !online { return .offline }
    switch d.gcodeState {
    case "RUNNING", "PREPARE", "SLICING": return .active
    case "PAUSE": return .paused
    case "FAILED": return .error
    default: return .idle
    }
}

/// A number the way JavaScript prints it: "37", not "37.0".
func plain(_ d: Double) -> String {
    d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
}

public func summaryOf(_ d: PrinterDetails, online: Bool) -> String {
    if !online { return "Offline" }
    let job = d.jobName ?? "print"
    switch d.gcodeState {
    case "RUNNING": return "Printing \(job)" + (d.progress.map { " — \(plain($0)) %" } ?? "")
    case "PREPARE", "SLICING": return "Preparing \(job)"
    case "PAUSE": return "Paused \(job)"
    case "FINISH": return "Finished \(job)"
    case "FAILED": return "Failed \(job)"
    case "IDLE": return "Idle"
    default:
        guard let first = d.gcodeState.first else { return "" }
        return String(first) + d.gcodeState.dropFirst().lowercased()
    }
}

/// When the current job started, from the printer's own clock if it says.
/// `gcode_start_time` is unix seconds (as a string); 0 or missing on some models.
public func reportedJobStart(_ state: JSON, now: Date = Date()) -> Date? {
    let p = state["print"] ?? .null
    guard let s = num(p["gcode_start_time"]), s != 0, s >= 1_600_000_000 else { return nil }
    let d = Date(timeIntervalSince1970: s)
    // A clock far in the future or a start days ago is not believable.
    if d > now.addingTimeInterval(60) || d < now.addingTimeInterval(-3 * 86_400) { return nil }
    return d
}

/// A stable id for "this job", so a restart mid-print picks the same job back up.
public func reportedJobKey(_ state: JSON) -> String? {
    let p = state["print"] ?? .null
    let task = stringified(p["task_id"]) ?? stringified(p["job_id"])
    if let task, task != "0" { return task }
    return str(p["subtask_name"]) ?? str(p["gcode_file"])
}

/// JavaScript's `String(v)` for a string or number, then `str()`.
private func stringified(_ v: JSON?) -> String? {
    switch v {
    case .string: return str(v)
    case .number(let d): return plain(d)
    default: return nil
    }
}
