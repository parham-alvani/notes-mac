// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Daftar",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Daftar", targets: ["Daftar"]),
    ],
    dependencies: [
        // The terminal pane. Pinned exactly: a terminal emulator is a parser
        // of untrusted bytes, and an update is something to read first.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.99.1"),
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
            dependencies: ["DaftarCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Reader"), .copy("Images")]
        ),
        .testTarget(
            name: "DaftarCoreTests",
            dependencies: ["DaftarCore"]
        ),
    ]
)
