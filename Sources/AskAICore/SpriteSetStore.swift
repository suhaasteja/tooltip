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

    /// Largest a single frame may be, in bytes.
    ///
    /// A 132px-tall PNG is a few tens of kilobytes; a megabyte means something
    /// is wrong, and frames are user-supplied content now — they can be
    /// hand-installed, not only generated.
    public static let maxFrameBytes = 1_000_000

    /// Largest all characters may occupy together, in bytes.
    ///
    /// The app is sandboxed, so this fills the user's container rather than
    /// their disk, but a runaway set count is still their storage.
    public static let maxTotalBytes = 100_000_000

    /// Writes a set's manifest and frames.
    ///
    /// - Parameter frames: PNG data keyed by the basenames the manifest uses.
    public func save(_ set: SpriteSet, frames: [String: Data]) throws {
        guard set.id != SpriteSet.builtInID else {
            throw SpriteSetError.cannotOverwriteBuiltIn
        }
        // Validate before writing anything: a partial write that then fails is
        // worse than a refusal, and the manifest-last ordering below only
        // protects against *interrupted* writes, not invalid ones.
        for (name, data) in frames {
            guard !data.isEmpty else { throw SpriteSetError.emptyFrame(name) }
            guard data.count <= Self.maxFrameBytes else {
                throw SpriteSetError.frameTooLarge(name, data.count)
            }
        }
        // Replacing an existing set does not count against the budget twice.
        let incoming = frames.values.reduce(0) { $0 + $1.count }
        let existing = sizeOnDisk(id: set.id)
        if totalSizeOnDisk() - existing + incoming > Self.maxTotalBytes {
            throw SpriteSetError.outOfSpace
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

    /// Changes a set's display name, leaving its frames and id alone.
    ///
    /// A separate operation from `save` because renaming must not require the
    /// frames to be in memory — they are on disk, and re-reading several
    /// megabytes of PNG to change one string would be absurd. The id does not
    /// change: it is the directory name, and moving it would orphan the
    /// selection stored in settings.
    public func rename(id: String, to name: String) throws {
        guard id != SpriteSet.builtInID else { throw SpriteSetError.cannotOverwriteBuiltIn }
        guard let existing = set(id: id) else { throw SpriteSetError.notFound }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SpriteSetError.emptyName }

        let renamed = SpriteSet(id: existing.id, name: trimmed,
                                animations: existing.animations)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(renamed).write(to: manifestURL(for: id))
    }

    /// Every installed character's bytes together.
    public func totalSizeOnDisk() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        return contents.reduce(0) { $0 + sizeOnDisk(id: $1.lastPathComponent) }
    }

    /// Total bytes on disk for one character, also shown in Settings so the user
    /// can see what their characters cost them.
    public func sizeOnDisk(id: String) -> Int {
        let directory = self.directory(for: id)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
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
    case notFound
    case emptyName
    case emptyFrame(String)
    case frameTooLarge(String, Int)
    case outOfSpace

    public var userMessage: String {
        switch self {
        case .cannotOverwriteBuiltIn:
            return "The built-in character cannot be changed or removed."
        case .notFound:
            return "That character is no longer installed."
        case .emptyName:
            return "A character needs a name."
        case .emptyFrame(let name):
            return "Frame \(name) is empty."
        case .frameTooLarge(let name, let bytes):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(bytes), countStyle: .file)
            return "Frame \(name) is \(size), which is too large for a sprite."
        case .outOfSpace:
            return "There is no room for another character. Delete one first."
        }
    }
}
