// swift-tools-version: 5.9
import PackageDescription

// BambuCore: parsing only. MQTT packets, printer reports, print history, discovery messages.
// BambuLAN: connects to printers with Network.framework. Includes BambuCore.
// Examples: bambu-monitor (Mac app) and bambu-status (command line), run with `swift run`.
let package = Package(
    name: "bambu-swift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BambuCore", targets: ["BambuCore"]),
        .library(name: "BambuLAN", targets: ["BambuLAN"]),
    ],
    targets: [
        .target(name: "BambuCore"),
        .target(name: "BambuLAN", dependencies: ["BambuCore"]),

        .target(name: "PrintersFile", path: "Examples/Shared"),
        .executableTarget(name: "bambu-monitor", dependencies: ["BambuLAN", "PrintersFile"], path: "Examples/BambuMonitor"),
        .executableTarget(name: "bambu-status", dependencies: ["BambuLAN", "PrintersFile"], path: "Examples/bambu-status"),

        .testTarget(name: "BambuCoreTests", dependencies: ["BambuCore"]),
        .testTarget(name: "BambuLANTests", dependencies: ["BambuLAN"]),
    ]
)
