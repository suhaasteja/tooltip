import Foundation

/// Finds and reads sprite sets installed on disk.
///
/// Sets live one directory each, holding a `manifest.json` and the PNG frames it
/// names:
///
/// ```
/// <root>/<set-id>/manifest.json
/// <root>/<set-id>/walk-0.png …
/// ```
///
/// The default root is Application Support. The app is sandboxed, so that
/// resolves inside its container — which is both correct and the only place it
/// can write. The bundled character deliberately does *not* live here: it ships
/// read-only inside the app, and `SpriteSet.builtIn` describes it in code so a
/// missing or corrupt user set always has something to fall back to.
public struct SpriteSetStore {

    public let root: URL

    /// - Parameter root: injected so tests use a throwaway directory.
    public init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            // Namespaced by bundle id: inside the sandbox container this is
            // already app-private, but the same code runs unsandboxed in tests
            // and from the CLI script.
            let bundleID = Bundle.main.bundleIdentifier ?? "com.yourname.AskAI"
            self.root = support.appendingPathComponent(bundleID, isDirectory: true)
                .appendingPathComponent("Sprites", isDirectory: true)
        }
    }

    public func directory(for setID: String) -> URL {
        root.appendingPathComponent(setID, isDirectory: true)
    }

    public func manifestURL(for setID: String) -> URL {
        directory(for: setID).appendingPathComponent("manifest.json")
    }

    /// Reads one set, or nil if it is absent or unreadable.
    ///
    /// Returns nil rather than throwing on a bad manifest: every caller's only
    /// sensible response is to fall back to the built-in character, and making
    /// that an error path would just move the `try?` somewhere less obvious.
    public func set(id: String) -> SpriteSet? {
        guard id != SpriteSet.builtInID else { return SpriteSet.builtIn }
        guard let data = try? Data(contentsOf: manifestURL(for: id)) else { return nil }
        return try? JSONDecoder().decode(SpriteSet.self, from: data)
    }

    /// Every readable installed set, built-in first.
    ///
    /// Unreadable directories are skipped silently — a half-written set from an
    /// interrupted generation should not stop the others from appearing.
    public func installedSets() -> [SpriteSet] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let userSets = contents
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { set(id: $0.lastPathComponent) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [SpriteSet.builtIn] + userSets
    }

    /// Writes a set's manifest and frames.
    ///
    /// - Parameter frames: PNG data keyed by the basenames the manifest uses.
    public func save(_ set: SpriteSet, frames: [String: Data]) throws {
        guard set.id != SpriteSet.builtInID else {
            throw SpriteSetError.cannotOverwriteBuiltIn
        }
        let directory = self.directory(for: set.id)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        for (name, data) in frames {
            try data.write(to: directory.appendingPathComponent("\(name).png"))
        }
        // Manifest last: a set is only discoverable once its frames are on disk,
        // so an interrupted write leaves an ignorable directory rather than a
        // set that names frames which are not there.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(set).write(to: manifestURL(for: set.id))
    }

    public func delete(id: String) throws {
        guard id != SpriteSet.builtInID else { throw SpriteSetError.cannotOverwriteBuiltIn }
        try FileManager.default.removeItem(at: directory(for: id))
    }

    /// Whether every frame a set names is actually present.
    ///
    /// Cheap enough to run before switching to a set, and the difference between
    /// a character that is missing an arm and one that never appears.
    public func isComplete(_ set: SpriteSet) -> Bool {
        guard set.id != SpriteSet.builtInID else { return true }
        let directory = self.directory(for: set.id)
        return set.allFrames.allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("\($0).png").path)
        }
    }
}

public enum SpriteSetError: Error, Equatable {
    case cannotOverwriteBuiltIn
}
