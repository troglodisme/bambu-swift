import Foundation
import BambuLAN
import PrintersFile

// bambu-status
//   Watches every printer in printers.json and prints a line when one changes.
// bambu-status <host> <serial> <access-code>
//   Watches one printer.
// bambu-status --discover
//   Lists printers announcing themselves on this network for 15 seconds.

let args = Array(CommandLine.arguments.dropFirst())

func line(_ text: String) {
    let time = Date().formatted(date: .omitted, time: .standard)
    print("[\(time)] \(text)")
    fflush(stdout)
}

if args == ["--discover"] {
    let discovery = BambuDiscovery(
        onPrinter: { printer in
            line("\(printer.displayName)  \(printer.model ?? "?")  \(printer.host)  serial \(printer.serial)")
        },
        onState: { listening, error in
            if listening { line("Listening for printers on UDP 2021…") }
            if let error { line("Can't listen: \(error)") }
        }
    )
    discovery.start()
    try await Task.sleep(for: .seconds(15))
    discovery.stop()
    exit(0)
}

var entries: [PrinterEntry]
switch args.count {
case 0:
    entries = try PrintersFile.load()
    if entries.isEmpty {
        print("""
        No printers in \(PrintersFile.url.path)
        Add one with `swift run bambu-monitor`, or run:
          bambu-status <host> <serial> <access-code>
          bambu-status --discover
        """)
        exit(1)
    }
case 3:
    entries = [PrinterEntry(name: args[1], host: args[0], serial: args[1], accessCode: args[2])]
default:
    print("""
    usage: bambu-status                                  every printer in printers.json
           bambu-status <host> <serial> <access-code>    one printer
           bambu-status --discover                       printers on the network
    """)
    exit(2)
}

// Kept here so the printers stay alive until Ctrl-C.
let printers = await MainActor.run {
    entries.map { entry in
        // Pins in memory: each run trusts the printer afresh.
        let printer = BambuPrinter(host: entry.host, serial: entry.serial, accessCode: entry.accessCode,
                                   name: entry.name, pins: MemoryPinStore())
        let label = entries.count > 1 ? "\(entry.name): " : ""
        var lastStatus: BambuPrinter.Status?
        printer.onUpdate = { update in
            let d = update.details
            var parts = [summaryOf(d, online: update.online)]
            if let nozzle = d.nozzleTemp { parts.append("nozzle \(Int(nozzle))°") }
            if let bed = d.bedTemp { parts.append("bed \(Int(bed))°") }
            line(label + parts.joined(separator: " · "))
            if printer.status != lastStatus {
                lastStatus = printer.status
                if let error = printer.lastError { line(label + "\(printer.status.label): \(error)") }
            }
        }
        line(label + "Connecting to \(entry.host)…")
        printer.start()
        return printer
    }
}

while true { try await Task.sleep(for: .seconds(3600)) }
_ = printers
