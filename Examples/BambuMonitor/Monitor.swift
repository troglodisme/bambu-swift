import Foundation
import Observation
import BambuLAN
import PrintersFile

/// The printers from printers.json, each with a live connection.
@MainActor
@Observable
final class Monitor {
    private(set) var entries: [PrinterEntry] = []
    private(set) var printers: [String: BambuPrinter] = [:]
    private(set) var found: [DiscoveredPrinter] = []
    var fileError: String?

    @ObservationIgnored private var table = DiscoveryTable()
    @ObservationIgnored private var discovery: BambuDiscovery?
    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?

    init() {
        reload()
    }

    /// Reads printers.json again and reconnects anything that changed.
    func reload() {
        do {
            let loaded = try PrintersFile.load()
            fileError = nil
            apply(loaded)
        } catch {
            fileError = "Couldn't read printers.json: \(error.localizedDescription)"
        }
    }

    func add(_ entry: PrinterEntry) {
        var next = entries.filter { $0.serial != entry.serial }
        next.append(entry)
        save(next)
    }

    func remove(_ entry: PrinterEntry) {
        save(entries.filter { $0.serial != entry.serial })
    }

    // MARK: Discovery, while the add sheet is open

    func startDiscovery() {
        guard discovery == nil else { return }
        let d = BambuDiscovery { [weak self] printer in
            Task { @MainActor in self?.noteFound(printer) }
        }
        discovery = d
        d.start()
    }

    func stopDiscovery() {
        discovery?.stop()
        discovery = nil
    }

    private func noteFound(_ printer: DiscoveredPrinter) {
        table.note(printer)
        found = table.list()
    }

    // MARK: Private

    private func save(_ next: [PrinterEntry]) {
        do {
            try PrintersFile.save(next)
            fileError = nil
        } catch {
            fileError = "Couldn't save printers.json: \(error.localizedDescription)"
        }
        apply(next)
    }

    private func apply(_ next: [PrinterEntry]) {
        let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.serial, $0) })
        for entry in next where old[entry.serial] != entry {
            printers[entry.serial]?.stop()
            let printer = BambuPrinter(host: entry.host, serial: entry.serial, accessCode: entry.accessCode, name: entry.name)
            printers[entry.serial] = printer
            printer.start()
        }
        for serial in old.keys where !next.contains(where: { $0.serial == serial }) {
            printers[serial]?.stop()
            printers[serial] = nil
        }
        entries = next
    }
}
