import Testing
import Foundation
@testable import AskAICore

@Suite("Sprite sets")
struct SpriteSetTests {

    @Test("the built-in set defines every mood")
    func builtInIsComplete() {
        for mood in SpriteMood.allCases {
            #expect(SpriteSet.builtIn.animations[mood.rawValue] != nil,
                    "built-in set is missing \(mood)")
        }
    }

    /// The fallback that keeps a half-built generated set usable.
    @Test("a set missing a mood falls back to the built-in one")
    func missingMoodFallsBack() {
        let partial = SpriteSet(
            id: "partial", name: "Partial",
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["a", "b"], frameDuration: 0.1, loops: true)])

        #expect(partial.animation(for: .thinking).frames == ["a", "b"])
        #expect(partial.animation(for: .confused)
                == SpriteSet.builtIn.animation(for: .confused))
    }

    @Test("allFrames is deduplicated and covers every animation")
    func allFramesDeduplicates() {
        let set = SpriteSet(
            id: "x", name: "X",
            animations: [
                SpriteMood.thinking.rawValue:
                    SpriteAnimation(frames: ["a", "b"], frameDuration: 0.1, loops: true),
                SpriteMood.talking.rawValue:
                    SpriteAnimation(frames: ["b", "c"], frameDuration: 0.1, loops: false),
            ])
        #expect(set.allFrames == ["a", "b", "c"])
    }

    @Test("the built-in set round-trips through JSON")
    func roundTrips() throws {
        let data = try JSONEncoder().encode(SpriteSet.builtIn)
        let decoded = try JSONDecoder().decode(SpriteSet.self, from: data)
        #expect(decoded == SpriteSet.builtIn)
    }

    @Test("resting index defaults to the last frame and survives encoding")
    func restingIndexRoundTrips() throws {
        let animation = SpriteAnimation(
            frames: ["a", "b", "c"], frameDuration: 0.1, loops: false, restingIndex: 1)
        let decoded = try JSONDecoder().decode(
            SpriteAnimation.self, from: try JSONEncoder().encode(animation))
        #expect(decoded.restingFrame == "b")

        let defaulted = SpriteAnimation(frames: ["a", "b"], frameDuration: 0.1, loops: false)
        #expect(defaulted.restingFrame == "b")
    }

    // MARK: - Decoding hostile manifests
    //
    // Manifests are user-supplied once sets can be generated or hand-installed,
    // so these are correctness requirements, not paranoia. An empty `frames`
    // would trap on the next subscript.

    @Test("an empty frame list is rejected")
    func emptyFramesRejected() {
        let json = #"{"frames":[],"frameDuration":0.1,"loops":false}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SpriteAnimation.self, from: Data(json.utf8))
        }
    }

    @Test("a non-positive duration is rejected")
    func zeroDurationRejected() {
        let json = #"{"frames":["a"],"frameDuration":0,"loops":true}"#
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(SpriteAnimation.self, from: Data(json.utf8))
        }
    }

    /// Clamped rather than rejected: a bad resting frame is cosmetic, and
    /// throwing away an otherwise usable character over it would be worse.
    @Test("an out-of-range resting index is clamped, not rejected")
    func restingIndexClamped() throws {
        let high = try JSONDecoder().decode(
            SpriteAnimation.self,
            from: Data(#"{"frames":["a","b"],"frameDuration":0.1,"loops":false,"restingIndex":99}"#.utf8))
        #expect(high.restingFrame == "b")

        let low = try JSONDecoder().decode(
            SpriteAnimation.self,
            from: Data(#"{"frames":["a","b"],"frameDuration":0.1,"loops":false,"restingIndex":-5}"#.utf8))
        #expect(low.restingFrame == "a")
    }
}

@Suite("Sprite set store", .serialized)
struct SpriteSetStoreTests {

    /// A throwaway root per test, so nothing can touch a real installed set.
    private func makeStore() -> SpriteSetStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-sprites-\(UUID().uuidString)")
        return SpriteSetStore(root: root)
    }

    private func png() -> Data { Data([0x89, 0x50, 0x4E, 0x47]) }

    private var sample: SpriteSet {
        SpriteSet(
            id: "robot", name: "Robot",
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["w0", "w1"], frameDuration: 0.1, loops: true)])
    }

    @Test("a saved set can be read back")
    func saveAndLoad() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(sample, frames: ["w0": png(), "w1": png()])
        #expect(store.set(id: "robot") == sample)
        #expect(store.isComplete(sample))
    }

    @Test("the built-in set is always available and never written")
    func builtInIsSpecial() {
        let store = makeStore()
        #expect(store.set(id: SpriteSet.builtInID) == SpriteSet.builtIn)
        #expect(store.isComplete(SpriteSet.builtIn))
        #expect(throws: SpriteSetError.cannotOverwriteBuiltIn) {
            try store.save(SpriteSet.builtIn, frames: [:])
        }
        #expect(throws: SpriteSetError.cannotOverwriteBuiltIn) {
            try store.delete(id: SpriteSet.builtInID)
        }
    }

    @Test("an unknown set is nil, not an error")
    func unknownSet() {
        #expect(makeStore().set(id: "nope") == nil)
    }

    /// The interrupted-generation case: the manifest exists but frames do not.
    @Test("a set whose frames are missing is not complete")
    func missingFramesDetected() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(sample, frames: ["w0": png()])   // w1 never written
        #expect(store.set(id: "robot") != nil)
        #expect(!store.isComplete(sample))
    }

    @Test("a corrupt manifest reads as nil rather than throwing")
    func corruptManifest() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try FileManager.default.createDirectory(
            at: store.directory(for: "bad"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.manifestURL(for: "bad"))
        #expect(store.set(id: "bad") == nil)
    }

    @Test("installed sets list the built-in first and skip unreadable ones")
    func installedSets() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(sample, frames: ["w0": png(), "w1": png()])
        try FileManager.default.createDirectory(
            at: store.directory(for: "bad"), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.manifestURL(for: "bad"))

        let sets = store.installedSets()
        #expect(sets.first == SpriteSet.builtIn)
        #expect(sets.contains(sample))
        #expect(!sets.contains { $0.id == "bad" })
    }

    @Test("deleting removes the set")
    func delete() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }

        try store.save(sample, frames: ["w0": png(), "w1": png()])
        try store.delete(id: "robot")
        #expect(store.set(id: "robot") == nil)
    }
}

@Suite("Active sprite set selection", .serialized)
struct ActiveSpriteSetTests {

    private func makeSettings() -> (SettingsStore, UserDefaults, String) {
        let name = "askai.sprites.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: defaults), defaults, name)
    }

    private func makeStore() -> SpriteSetStore {
        SpriteSetStore(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-active-\(UUID().uuidString)"))
    }

    @Test("defaults to the built-in set")
    func defaultsToBuiltIn() {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(settings.activeSpriteSetID == SpriteSet.builtInID)
        #expect(settings.activeSpriteSet(store: makeStore()) == SpriteSet.builtIn)
    }

    /// The Stage 6 requirement, asserted early: a set the user selected but that
    /// is no longer installed must not leave the panel with no character.
    @Test("a selected but missing set falls back to the built-in")
    func missingSetFallsBack() {
        let (settings, defaults, name) = makeSettings()
        defer { defaults.removePersistentDomain(forName: name) }
        settings.activeSpriteSetID = "deleted-yesterday"
        #expect(settings.activeSpriteSet(store: makeStore()) == SpriteSet.builtIn)
    }

    @Test("a set with missing frames falls back to the built-in")
    func incompleteSetFallsBack() throws {
        let (settings, defaults, name) = makeSettings()
        let store = makeStore()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: store.root)
        }
        let set = SpriteSet(
            id: "half", name: "Half",
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["a", "b"], frameDuration: 0.1, loops: true)])
        try store.save(set, frames: ["a": Data([0x89])])   // "b" missing

        settings.activeSpriteSetID = "half"
        #expect(settings.activeSpriteSet(store: store) == SpriteSet.builtIn)
    }

    @Test("a complete installed set is used")
    func completeSetIsUsed() throws {
        let (settings, defaults, name) = makeSettings()
        let store = makeStore()
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: store.root)
        }
        let set = SpriteSet(
            id: "robot", name: "Robot",
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["a"], frameDuration: 0.1, loops: true)])
        try store.save(set, frames: ["a": Data([0x89])])

        settings.activeSpriteSetID = "robot"
        #expect(settings.activeSpriteSet(store: store) == set)
    }
}
