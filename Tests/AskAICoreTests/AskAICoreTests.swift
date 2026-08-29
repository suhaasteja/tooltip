import Testing
@testable import AskAICore

// NOTE: XCTest is not available with Command Line Tools alone (it ships with
// full Xcode). swift-testing IS bundled with the toolchain, so the whole suite
// uses `import Testing`. See NOTES.md.
@Test func coreLinks() {
    #expect(!AskAICore.version.isEmpty)
}
