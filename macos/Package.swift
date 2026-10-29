// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v13)],
    targets: [
        // Foundation-only: config, Claude Code logins, usage API and probe. No UI.
        .target(name: "UsageCore", path: "Sources/UsageCore"),
        // The menu bar app (AppKit + SwiftUI).
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["UsageCore"],
            path: "Sources/ClaudeUsageBar"
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            path: "Tests/UsageCoreTests"
        ),
    ]
)
