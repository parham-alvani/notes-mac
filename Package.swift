// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Daftar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Daftar", targets: ["Daftar"]),
    ],
    targets: [
        // Everything that can be tested without a window: the vault, its
        // index, the task rules, the calendar notes, git. No AppKit here.
        .target(
            name: "DaftarCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "Daftar",
            dependencies: ["DaftarCore"],
            resources: [.copy("Reader"), .copy("Images")]
        ),
        .testTarget(
            name: "DaftarCoreTests",
            dependencies: ["DaftarCore"]
        ),
    ]
)
