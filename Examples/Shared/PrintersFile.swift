import Foundation

/// One printer in printers.json.
public struct PrinterEntry: Codable, Identifiable, Hashable, Sendable {
    public var name: String
    public var host: String
    public var serial: String
    public var accessCode: String

    public var id: String { serial }

    public init(name: String, host: String, serial: String, accessCode: String) {
        self.name = name
        self.host = host
        self.serial = serial
        self.accessCode = accessCode
    }
}

/// The printers the examples know about, in a JSON file you can edit by hand:
/// ~/Library/Application Support/bambu-swift/printers.json
public enum PrintersFile {
    public static var url: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("bambu-swift", isDirectory: true).appendingPathComponent("printers.json")
    }

    /// An empty list when the file doesn't exist yet.
    public static func load() throws -> [PrinterEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([PrinterEntry].self, from: Data(contentsOf: url))
    }

    public static func save(_ printers: [PrinterEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(printers).write(to: url, options: .atomic)
    }
}
