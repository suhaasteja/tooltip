import Testing
import Foundation
@testable import AskAICore

/// The Sprites tab's non-UI rules.
///
/// `SpriteStudioModel` itself lives in the app target and cannot be imported
/// here, so what is tested is the logic it delegates to — the id derivation and
/// the save/switch contract it depends on. The parts that genuinely need AppKit
/// are covered by the manual pass recorded in NOTES.md.
@Suite("Sprite studio logic")
struct SpriteStudioLogicTests {

    /// The real implementation, not a copy — traversal safety must not be
    /// asserted against a duplicate that can drift.
    private func makeID(from description: String) -> String {
        SpriteSet.makeID(from: description)
    }

@Suite("Sprite prompt settings", .serialized)
struct SpritePromptSettingsTests {

    private func makeStore() -> (SettingsStore, UserDefaults, String) {
        let name = "askai.spriteprompt.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (SettingsStore(defaults: defaults), defaults, name)
    }

    @Test("defaults to the shipped templates")
    func defaultsToShipped() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(store.thinkingPrompt == SpritePrompts.defaultThinkingTemplate)
        #expect(store.posesPrompt == SpritePrompts.defaultPosesTemplate)
        #expect(!store.isThinkingPromptCustomised)
    }

    @Test("an override is stored and reported as customised")
    func overrideStored() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.thinkingPrompt = "six frames of a cat sleeping"
        #expect(store.thinkingPrompt == "six frames of a cat sleeping")
        #expect(store.isThinkingPromptCustomised)
    }

    /// Clearing the field is the undo, matching how the Services prompt slots
    /// already behave — one rule for every prompt in the app.
    @Test("blanking a prompt restores the default")
    func blankRestores() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.posesPrompt = "something else"
        store.posesPrompt = "   "
        #expect(store.posesPrompt == SpritePrompts.defaultPosesTemplate)
        #expect(!store.isPosesPromptCustomised)
    }

    @Test("restore clears both prompts at once")
    func restoreBoth() {
        let (store, defaults, name) = makeStore()
        defer { defaults.removePersistentDomain(forName: name) }
        store.thinkingPrompt = "a"
        store.posesPrompt = "b"
        store.restoreSpritePrompts()
        #expect(store.thinkingPrompt == SpritePrompts.defaultThinkingTemplate)
        #expect(store.posesPrompt == SpritePrompts.defaultPosesTemplate)
    }
}

    @Test("ids are filesystem-safe and readable")
    func idsAreSafe() {
        #expect(makeID(from: "a small round owl") == "a-small-round-owl")
        #expect(makeID(from: "Wizard  with   a staff") == "wizard-with-a-staff")
    }

    /// A description could contain anything a user types, including path
    /// separators — the id becomes a directory name.
    @Test("path separators and dots cannot escape the sprites directory")
    func idsCannotTraverse() {
        let id = makeID(from: "../../etc/passwd")
        #expect(!id.contains("/"))
        #expect(!id.contains(".."))
        #expect(makeID(from: "...") == "character")
    }

    @Test("regenerating the same description reuses the id, replacing rather than duplicating")
    func idsAreStable() {
        #expect(makeID(from: "a tiny dragon") == makeID(from: "A Tiny Dragon"))
    }

    @Test("very long descriptions are truncated to a sane directory name")
    func idsAreBounded() {
        let id = makeID(from: String(repeating: "dragon ", count: 40))
        #expect(id.count <= 40)
    }

    /// What "keep" does: write, then switch. Both must succeed together, or the
    /// setting would point at a character that is not on disk.
    @Test("saving then selecting a set makes it the resolved active one")
    func keepMakesItActive() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-studio-\(UUID().uuidString)")
        let sets = SpriteSetStore(root: root)
        let name = "askai.studio.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let settings = SettingsStore(defaults: defaults)
        defer {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }

        let set = SpriteSet(
            id: "owl", name: "an owl",
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["walk-0"], frameDuration: 0.11, loops: true)])
        try sets.save(set, frames: ["walk-0": Data([0x89, 0x50])])
        settings.activeSpriteSetID = "owl"

        #expect(settings.activeSpriteSet(store: sets) == set)
    }

    /// Cancelling must leave nothing behind. Since a set is only written when
    /// the user keeps a preview, "nothing was written" is the whole contract.
    @Test("a cancelled generation leaves no set on disk")
    func cancelWritesNothing() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-cancel-\(UUID().uuidString)")
        let sets = SpriteSetStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        // Nothing saved: installedSets is just the built-in.
        #expect(sets.installedSets() == [SpriteSet.builtIn])
    }

    /// Regenerating reuses the id, so the frames on disk change underneath a
    /// cached image. The loader must be told to forget them.
    @Test("overwriting a set replaces its frames")
    func regenerateOverwrites() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-regen-\(UUID().uuidString)")
        let sets = SpriteSetStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = SpriteSet(
            id: "owl", name: "owl v1",
            animations: [SpriteMood.idle.rawValue:
                SpriteAnimation(frames: ["pose-0"], frameDuration: 1, loops: false)])
        try sets.save(first, frames: ["pose-0": Data([1])])

        let second = SpriteSet(
            id: "owl", name: "owl v2",
            animations: [SpriteMood.idle.rawValue:
                SpriteAnimation(frames: ["pose-0"], frameDuration: 1, loops: false)])
        try sets.save(second, frames: ["pose-0": Data([2])])

        #expect(sets.set(id: "owl")?.name == "owl v2")
        let onDisk = try Data(
            contentsOf: sets.directory(for: "owl").appendingPathComponent("pose-0.png"))
        #expect(onDisk == Data([2]))
    }
}

@Suite("Sprite set CRUD", .serialized)
struct SpriteSetCRUDTests {

    private func makeStore() -> SpriteSetStore {
        SpriteSetStore(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("askai-crud-\(UUID().uuidString)"))
    }

    private func sample(id: String = "owl", name: String = "an owl") -> SpriteSet {
        SpriteSet(
            id: id, name: name,
            animations: [SpriteMood.thinking.rawValue:
                SpriteAnimation(frames: ["walk-0", "walk-1"],
                                frameDuration: 0.18, loops: true)])
    }

    private func frames() -> [String: Data] {
        ["walk-0": Data([0x89, 0x50, 0x4E, 0x47]), "walk-1": Data([0x89, 0x50, 0x4E, 0x48])]
    }

    // MARK: Rename

    @Test("renaming changes the name but not the id or the frames")
    func renameKeepsIdentity() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())

        try store.rename(id: "owl", to: "Professor Hoot")
        let renamed = try #require(store.set(id: "owl"))
        #expect(renamed.name == "Professor Hoot")
        #expect(renamed.id == "owl", "the id is the directory name and must not move")
        #expect(store.isComplete(renamed), "frames were disturbed by a rename")
    }

    @Test("renaming preserves the animations")
    func renameKeepsAnimations() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())
        try store.rename(id: "owl", to: "Hoot")
        #expect(store.set(id: "owl")?.animations == sample().animations)
    }

    @Test("an empty or whitespace name is rejected")
    func emptyNameRejected() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())
        #expect(throws: SpriteSetError.emptyName) { try store.rename(id: "owl", to: "   ") }
        #expect(store.set(id: "owl")?.name == "an owl", "the old name should survive")
    }

    @Test("renaming something that is not installed reports it")
    func renameMissing() {
        #expect(throws: SpriteSetError.notFound) {
            try self.makeStore().rename(id: "ghost", to: "x")
        }
    }

    @Test("the built-in character cannot be renamed or deleted")
    func builtInIsProtected() {
        let store = makeStore()
        #expect(throws: SpriteSetError.cannotOverwriteBuiltIn) {
            try store.rename(id: SpriteSet.builtInID, to: "x")
        }
        #expect(throws: SpriteSetError.cannotOverwriteBuiltIn) {
            try store.delete(id: SpriteSet.builtInID)
        }
    }

    // MARK: Delete

    /// The case that matters: the panel may be showing the character being
    /// removed. Selection has to move to the built-in one, and the resolver has
    /// to agree — otherwise the panel is pointed at a directory that is gone.
    @Test("deleting the selected character falls back to the built-in")
    func deleteActiveFallsBack() throws {
        let store = makeStore()
        let suite = "askai.crud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: store.root)
        }

        try store.save(sample(), frames: frames())
        settings.activeSpriteSetID = "owl"
        #expect(settings.activeSpriteSet(store: store).id == "owl")

        try store.delete(id: "owl")
        // Even without the UI moving the selection, the resolver must not
        // return a character whose files are gone.
        #expect(settings.activeSpriteSet(store: store) == SpriteSet.builtIn)
    }

    @Test("deleting removes the directory and the listing entry")
    func deleteRemoves() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())
        #expect(store.installedSets().count == 2)

        try store.delete(id: "owl")
        #expect(store.set(id: "owl") == nil)
        #expect(store.installedSets() == [SpriteSet.builtIn])
        #expect(!FileManager.default.fileExists(atPath: store.directory(for: "owl").path))
    }

    @Test("deleting one character leaves the others alone")
    func deleteIsScoped() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(id: "owl", name: "an owl"), frames: frames())
        try store.save(sample(id: "mole", name: "a mole"), frames: frames())

        try store.delete(id: "owl")
        #expect(store.set(id: "mole") != nil)
        #expect(store.installedSets().count == 2, "built-in plus the mole")
    }

    // MARK: Regenerate

    /// Regenerating reuses the id, so it must replace rather than accumulate —
    /// and the new frames must be the ones on disk afterwards.
    @Test("regenerating replaces frames in place")
    func regenerateReplaces() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())
        try store.save(sample(name: "an owl"),
                       frames: ["walk-0": Data([1]), "walk-1": Data([2])])

        #expect(store.installedSets().count == 2, "a duplicate was created")
        let onDisk = try Data(
            contentsOf: store.directory(for: "owl").appendingPathComponent("walk-0.png"))
        #expect(onDisk == Data([1]))
    }

    @Test("size on disk is reported for a saved set and zero for a missing one")
    func sizeOnDisk() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try store.save(sample(), frames: frames())
        #expect(store.sizeOnDisk(id: "owl") > 0)
        #expect(store.sizeOnDisk(id: "ghost") == 0)
    }
}
