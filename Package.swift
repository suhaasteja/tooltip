// swift-tools-version:6.0
import PackageDescription

// Tools-version 6.0 is required for SwiftPM to wire up swift-testing, which is
// the only test framework available without full Xcode (XCTest ships with Xcode
// only). Language mode is pinned to v5 throughout: Swift 6 strict concurrency
// buys nothing here and fights AppKit's main-thread-implicit API surface.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "AskAI",
    platforms: [.macOS(.v13)],
    targets: [
        // All pure logic lives here so `swift test` can exercise it.
        .target(name: "AskAICore", swiftSettings: swift5),
        // Thin AppKit shell.
        .executableTarget(name: "AskAI", dependencies: ["AskAICore"], swiftSettings: swift5),
        .testTarget(name: "AskAICoreTests", dependencies: ["AskAICore"], swiftSettings: swift5),
    ]
)
