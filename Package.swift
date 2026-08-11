// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LedgerBar",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "LedgerCore", targets: ["LedgerCore"]),
        // SwiftPM build of the native SwiftUI app so the app compiles and runs
        // with Command Line Tools only. The XcodeGen project (project.yml)
        // consumes the same LedgerBar/ sources for the bundled .app build.
        .executable(name: "LedgerBar", targets: ["LedgerBarApp"]),
        // §4.2 capture gate: user-run shape capture, credential from Keychain only.
        .executable(name: "ledgerbar-capture", targets: ["LedgerBarCapture"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        // Swift Testing is test-only; this package keeps CLT-only builds usable.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "LedgerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/LedgerCore"
        ),
        .executableTarget(
            name: "LedgerBarApp",
            dependencies: ["LedgerCore"],
            path: "LedgerBar",
            exclude: ["App/Info.plist", "App/LedgerBar.entitlements"],
            linkerSettings: [
                // Embed Info.plist (LSUIElement etc.) into the bare SwiftPM
                // binary; the XcodeGen app bundle uses the plist file itself.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "LedgerBar/App/Info.plist"
                ])
            ]
        ),
        .executableTarget(
            name: "LedgerBarCapture",
            dependencies: ["LedgerCore"],
            path: "Tools/Capture"
        ),
        .testTarget(
            name: "LedgerCoreTests",
            dependencies: [
                "LedgerCore",
                // Direct GRDB access so persistence tests can assert the
                // normalized mirror tables (schema shape, row counts) with
                // plain SQL against the same database file.
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/LedgerCoreTests"
        )
    ]
)
