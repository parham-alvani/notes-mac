// swift-tools-version: 6.2

import Foundation
import PackageDescription

// SwiftTerm brings a build-tool plugin, and with one in the graph the command
// line tools' SwiftPM stops passing the swift-testing macro plugin to test
// targets (`plugin for module 'TestingMacros' not found`). Without Xcode the
// plugin is named here; with Xcode, as on CI, SwiftPM finds it and this is empty.
let testingMacros = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
let testSettings: [SwiftSetting] =
    FileManager.default.fileExists(atPath: "/Applications/Xcode.app") || !FileManager.default.fileExists(atPath: testingMacros)
    ? [] : [.unsafeFlags(["-load-plugin-library", testingMacros])]

let package = Package(
    name: "Daftar",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Daftar", targets: ["Daftar"]),
        .executable(name: "DaftarQuickLook", targets: ["DaftarQuickLook"]),
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
        // The app's windows and views: a library, so the tests can drive them.
        .target(
            name: "DaftarUI",
            dependencies: ["DaftarCore", .product(name: "SwiftTerm", package: "SwiftTerm")],
            resources: [.copy("Reader"), .copy("Images")]
        ),
        .executableTarget(
            name: "Daftar",
            dependencies: ["DaftarUI"]
        ),
        // The Quick Look extension: an executable that `just app` puts in
        // `Contents/PlugIns/DaftarQuickLook.appex`, with Support/QuickLook.
        .executableTarget(
            name: "DaftarQuickLook",
            dependencies: ["DaftarCore"]
        ),
        .testTarget(
            name: "DaftarCoreTests",
            dependencies: ["DaftarCore"],
            swiftSettings: testSettings
        ),
        // The app's own views, driven in-process: the editor's keys and saves.
        .testTarget(
            name: "DaftarTests",
            dependencies: ["DaftarUI", "DaftarCore"],
            swiftSettings: testSettings
        ),
    ]
)
