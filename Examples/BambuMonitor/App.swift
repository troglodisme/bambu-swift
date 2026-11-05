import AppKit
import SwiftUI
import BambuLAN
import PrintersFile

// A small Mac app that shows your printers' live status.
// swift run bambu-monitor

@main
struct BambuMonitorApp: App {
    @State private var monitor = Monitor()

    init() {
        // Started from Terminal there's no app bundle, so ask to be a normal app with a window.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Printers") {
            PrinterList(monitor: monitor)
                .frame(minWidth: 420, minHeight: 280)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open printers file") {
                    NSWorkspace.shared.activateFileViewerSelecting([PrintersFile.url])
                }
                Button("Reload printers file") { monitor.reload() }
                    .keyboardShortcut("r")
            }
        }
    }
}

struct PrinterList: View {
    let monitor: Monitor
    @State private var adding = false
    @State private var editing: PrinterEntry?

    var body: some View {
        Group {
            if monitor.entries.isEmpty {
                ContentUnavailableView {
                    Label("No printers yet", systemImage: "printer")
                } description: {
                    Text("Add one, or edit printers.json and reload.")
                } actions: {
                    Button("Add printer") { adding = true }
                }
            } else {
                List(monitor.entries) { entry in
                    if let printer = monitor.printers[entry.serial] {
                        PrinterRow(printer: printer)
                            .contextMenu {
                                Button("Edit…") { editing = entry }
                                if printer.status == .certificateChanged {
                                    Button("Trust new certificate") { printer.trustNewCertificate() }
                                }
                                Button("Remove", role: .destructive) { monitor.remove(entry) }
                            }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = monitor.fileError {
                Text(error).font(.callout).foregroundStyle(.red).padding(8)
            }
        }
        .toolbar {
            Button { adding = true } label: { Label("Add printer", systemImage: "plus") }
        }
        .sheet(isPresented: $adding) {
            PrinterForm(monitor: monitor, entry: nil)
        }
        .sheet(item: $editing) { entry in
            PrinterForm(monitor: monitor, entry: entry)
        }
    }
}

struct PrinterRow: View {
    let printer: BambuPrinter

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(printer.name).font(.headline)
                Spacer()
                Text(printer.host).font(.caption).foregroundStyle(.secondary)
            }
            Text(printer.status == .online ? printer.summary : printer.status.label)
            if printer.activity == .active, let progress = printer.details.progress {
                ProgressView(value: progress, total: 100)
            }
            if printer.status == .online {
                Text(temperatures).font(.caption).foregroundStyle(.secondary)
            }
            if printer.status != .online, let error = printer.lastError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch printer.activity {
        case .active: return .green
        case .paused: return .yellow
        case .error: return .red
        case .idle: return .blue
        case .offline: return .gray
        }
    }

    private var temperatures: String {
        let d = printer.details
        var parts: [String] = []
        if let t = d.nozzleTemp { parts.append("Nozzle \(Int(t))°") }
        if let t = d.bedTemp { parts.append("Bed \(Int(t))°") }
        if let t = d.chamberTemp { parts.append("Chamber \(Int(t))°") }
        if let m = d.material { parts.append(m) }
        return parts.joined(separator: " · ")
    }
}

/// Add a printer, or edit one. Printers found on the network fill in the IP and serial.
struct PrinterForm: View {
    let monitor: Monitor
    let entry: PrinterEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = ""
    @State private var serial = ""
    @State private var accessCode = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry == nil ? "Add printer" : "Edit printer").font(.title2)

            if entry == nil {
                GroupBox("On your network") {
                    if monitor.found.isEmpty {
                        Text("Looking for printers… If none show up, type the details below.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(monitor.found) { printer in
                            Button {
                                name = printer.displayName
                                host = printer.host
                                serial = printer.serial
                            } label: {
                                HStack {
                                    Text(printer.displayName)
                                    Text(printer.model ?? "").foregroundStyle(.secondary)
                                    Spacer()
                                    Text(printer.host).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Workshop"))
                TextField("IP address", text: $host, prompt: Text("192.168.1.143"))
                TextField("Serial", text: $serial, prompt: Text("Settings → Device"))
                    .disabled(entry != nil)
                SecureField("Access code", text: $accessCode, prompt: Text("Settings → Network, 8 characters"))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    monitor.add(PrinterEntry(
                        name: name.isEmpty ? serial : name,
                        host: cleanedHost(host) ?? host,
                        serial: serial.trimmingCharacters(in: .whitespaces),
                        accessCode: accessCode.trimmingCharacters(in: .whitespaces)
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(cleanedHost(host) == nil || serial.isEmpty || accessCode.count < 8)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let entry {
                name = entry.name
                host = entry.host
                serial = entry.serial
                accessCode = entry.accessCode
            } else {
                monitor.startDiscovery()
            }
        }
        .onDisappear { monitor.stopDiscovery() }
    }
}
