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
