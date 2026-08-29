import Testing
import Foundation
@testable import AskAICore

/// Uses a per-run service name so a test can never touch the real stored key.
private func makeStore() -> KeychainStore {
    KeychainStore(service: "com.yourname.AskAI.tests.\(UUID().uuidString)",
                  account: "anthropic-api-key")
}

@Suite("Keychain store")
struct KeychainStoreTests {

    @Test("save -> read -> delete -> nil round trip")
    func roundTrip() throws {
        let store = makeStore()
        defer { try? store.delete() }

        #expect(try store.read() == nil)

        try store.save("sk-ant-secret-value")
        #expect(try store.read() == "sk-ant-secret-value")

        try store.delete()
        #expect(try store.read() == nil)
    }

    @Test("saving twice updates rather than duplicating")
    func overwrite() throws {
        let store = makeStore()
        defer { try? store.delete() }

        try store.save("first")
        try store.save("second")
        #expect(try store.read() == "second")
    }

    @Test("deleting a nonexistent item is not an error")
    func deleteMissingIsFine() throws {
        let store = makeStore()
        try store.delete()
    }

    @Test("unicode secrets survive the round trip")
    func unicodeSecret() throws {
        let store = makeStore()
        defer { try? store.delete() }
        try store.save("clé-🔑-秘密")
        #expect(try store.read() == "clé-🔑-秘密")
    }
}
