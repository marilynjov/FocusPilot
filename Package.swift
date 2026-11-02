// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FocusPilot",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FocusPilot", targets: ["FocusPilot"]),
        // Installed as Contents/Helpers/focuspilot; the product name differs
        // from the app's only by case, which collides on macOS file systems.
        .executable(name: "focuspilot-cli", targets: ["FocusPilotCLI"]),
        // Chrome's native messaging host, Contents/Helpers/focuspilot-chrome-host.
        .executable(name: "focuspilot-chrome-host", targets: ["FocusPilotChromeHost"]),
    ],
    dependencies: [
        // Pinned exactly: storage format and migrations depend on it.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        // Everything testable lives here; the app target stays a thin SwiftUI shell.
        .target(
            name: "FocusPilotCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "FocusPilot",
            dependencies: ["FocusPilotCore"]
        ),
        // Developer tool code: cuts the raccoon pose sheet into layer strips
        // (scripts/build-raccoon-art.sh). The app bundles the committed
        // output and does not link this.
        .target(
            name: "RaccoonRig",
            dependencies: ["FocusPilotCore"],
            // Pixel loops are about 50 times slower unoptimized; this keeps
            // RaccoonArtTests from slowing the timing-sensitive suites.
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        // Build-time tool: writes AppIcon.icon for scripts/build-app.sh and
        // renders review images. Not part of the app.
        .executableTarget(
            name: "RenderArtwork",
            dependencies: ["FocusPilotCore", "RaccoonRig"]
        ),
        // The focuspilot command for Herdr panes. It talks to the running
        // app over a socket and never opens the databases itself.
        .executableTarget(
            name: "FocusPilotCLI",
            dependencies: ["FocusPilotCore"]
        ),
        // Chrome starts it for the FocusPilot extension; it reads the
        // published policy and records observations, never the databases.
        .executableTarget(
            name: "FocusPilotChromeHost",
            dependencies: ["FocusPilotCore"]
        ),
        .testTarget(
            name: "FocusPilotCoreTests",
            // The Chrome host is built so a test can run it as Chrome does.
            dependencies: ["FocusPilotCore", "FocusPilotChromeHost", "RaccoonRig", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
