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
        //
        // `Sprites/` is excluded rather than declared as a SwiftPM resource.
        // `Bundle.module` in an *executable* target resolves against
        // `Bundle.main.bundleURL` -- the .app root -- not `Contents/Resources`,
        // so the generated accessor can never find its bundle inside a
        // hand-assembled app and traps at launch. `scripts/bundle.sh` copies the
        // frames to `Contents/Resources/Sprites` and the app uses `Bundle.main`.
        // See NOTES.md.
        .executableTarget(
            name: "AskAI",
            dependencies: ["AskAICore"],
            exclude: ["Sprites"],
            swiftSettings: swift5),
        .testTarget(name: "AskAICoreTests", dependencies: ["AskAICore"], swiftSettings: swift5),
        // Cuts sprite sheets into frames. A target rather than a loose script so
        // it can import the extraction logic instead of duplicating it.
        .executableTarget(name: "SpriteTool", dependencies: ["AskAICore"], swiftSettings: swift5),
    ]
)
