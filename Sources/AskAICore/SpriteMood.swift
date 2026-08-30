import Foundation

/// What the character is doing, derived from what the panel is showing.
///
/// Pure, and deliberately separate from `PanelState`: the panel's states are
/// about the request, the moods are about presentation, and collapsing them
/// would put animation vocabulary into the state machine that drives the LLM.
/// Keeping the mapping here means it is unit-testable with no AppKit and no
/// running app — the same reason `PanelPlacement` lives in this target.
public enum SpriteMood: String, CaseIterable, Sendable {
    /// Nothing is happening. Not normally seen: the panel hides when idle.
    case idle
    /// A request is in flight.
    case thinking
    /// An answer arrived (or is streaming in).
    case talking
    /// The request failed.
    case confused
    /// The service fired but there was nothing on the pasteboard.
    case searching

    public static func mood(for state: PanelState) -> SpriteMood {
        switch state {
        case .idle: return .idle
        case .loading: return .thinking
        case .success: return .talking
        case .failure: return .confused
        case .emptySelection: return .searching
        }
    }
}

/// The frames a mood plays, and how.
///
/// Frame names are resource basenames, resolved by the app target — this type
/// stays free of any image or bundle type so it can be tested as plain data.
public struct SpriteAnimation: Equatable, Sendable, Codable {

    /// Resource basenames, in playback order. Never empty.
    public let frames: [String]
    /// How long each frame is held.
    public let frameDuration: TimeInterval
    /// When false, the sequence plays once and holds `restingFrame`.
    public let loops: Bool
    /// Index of the frame shown when motion is suppressed.
    ///
    /// Stored rather than derived because generated sets do not follow the
    /// built-in set's convention: the shipped sequences are authored to *settle*
    /// into their resting pose, so the last frame is right for them, but a
    /// generated animation may rest anywhere.
    public let restingIndex: Int

    public init(
        frames: [String],
        frameDuration: TimeInterval,
        loops: Bool,
        restingIndex: Int? = nil
    ) {
        precondition(!frames.isEmpty, "an animation needs at least one frame")
        self.frames = frames
        self.frameDuration = frameDuration
        self.loops = loops
        // Default to the last frame: see the note above.
        self.restingIndex = min(max(restingIndex ?? frames.count - 1, 0), frames.count - 1)
    }

    private enum CodingKeys: String, CodingKey {
        case frames, frameDuration, loops, restingIndex
    }

    /// Validates on decode rather than trusting the file.
    ///
    /// Manifests become user-supplied content once sets can be generated or
    /// hand-installed, and an empty `frames` array would trap on the very next
    /// subscript. Failing the decode lets the caller fall back to the built-in
    /// set, which is the behaviour the panel needs.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let frames = try c.decode([String].self, forKey: .frames)
        guard !frames.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .frames, in: c, debugDescription: "an animation needs at least one frame")
        }
        let duration = try c.decode(TimeInterval.self, forKey: .frameDuration)
        guard duration > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .frameDuration, in: c, debugDescription: "frameDuration must be positive")
        }
        self.frames = frames
        self.frameDuration = duration
        self.loops = try c.decode(Bool.self, forKey: .loops)
        let resting = try c.decodeIfPresent(Int.self, forKey: .restingIndex) ?? frames.count - 1
        // Clamp rather than reject: an out-of-range resting frame is a cosmetic
        // mistake, not a reason to discard an otherwise usable character.
        self.restingIndex = min(max(resting, 0), frames.count - 1)
    }

    /// The frame shown when motion is suppressed — either by the system's
    /// Reduce Motion setting or by the user turning the character's animation
    /// off.
    public var restingFrame: String { frames[restingIndex] }

    /// Total duration of one pass. Infinite-looping animations still report the
    /// length of a single cycle.
    public var cycleDuration: TimeInterval {
        frameDuration * Double(frames.count)
    }

    /// Frame index at `time` seconds into playback.
    ///
    /// Pure so playback can be tested by sampling times rather than by waiting
    /// on a timer. A non-looping animation clamps to its last frame; negative
    /// times clamp to the first.
    public func frameIndex(at time: TimeInterval) -> Int {
        guard time > 0 else { return 0 }
        let step = Int(time / frameDuration)
        if loops {
            return step % frames.count
        }
        return min(step, frames.count - 1)
    }

    public func frame(at time: TimeInterval) -> String {
        frames[frameIndex(at: time)]
    }
}

/// A complete character: one animation per mood, plus the frames on disk.
///
/// Frames are referenced by basename and resolved by the app target, so this
/// type stays free of any image or bundle type and can be tested as plain data.
///
/// Codable because a set is stored as a `manifest.json` beside its PNGs, which
/// is what lets a character be generated, hand-installed, or shipped in the app
/// bundle without any of them being a special case.
public struct SpriteSet: Codable, Equatable, Sendable, Identifiable {

    public let id: String
    /// Shown in Settings.
    public let name: String
    /// Keyed by `SpriteMood.rawValue`. A set need not define every mood.
    public let animations: [String: SpriteAnimation]

    public init(id: String, name: String, animations: [String: SpriteAnimation]) {
        self.id = id
        self.name = name
        self.animations = animations
    }

    /// The animation for a mood, falling back to the built-in set.
    ///
    /// Never optional and never traps: a generated set that is missing a mood, or
    /// whose manifest was hand-edited badly, degrades to the shipped character
    /// for that one mood rather than leaving the panel with nothing to draw.
    public func animation(for mood: SpriteMood) -> SpriteAnimation {
        if let mine = animations[mood.rawValue] { return mine }
        if let builtIn = SpriteSet.builtIn.animations[mood.rawValue] { return builtIn }
        // Unreachable unless the built-in set itself is incomplete, which a test
        // asserts against. Still not a trap.
        return SpriteAnimation(frames: ["pose-3"], frameDuration: 1, loops: false)
    }

    /// Every frame this set can ask for, deduplicated. Used to warm the cache.
    public var allFrames: [String] {
        Array(Set(animations.values.flatMap(\.frames))).sorted()
    }

    /// Whether a mood needs a running timer at all. A single-frame animation
    /// never does, and in a background app that lives for weeks an unnecessary
    /// display-rate redraw is a real battery cost.
    public func needsAnimation(for mood: SpriteMood) -> Bool {
        animation(for: mood).frames.count > 1
    }

    /// A filesystem-safe id derived from a description.
    ///
    /// The id becomes a directory name, and the description is whatever the user
    /// typed — including, potentially, path separators. Everything that is not a
    /// letter or digit collapses to a single dash, which makes traversal
    /// impossible rather than merely unlikely.
    ///
    /// Stable by design: regenerating the same description reuses the id and
    /// replaces the character, instead of accumulating near-duplicates.
    public static func makeID(from description: String) -> String {
        let slug = description.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-", result.last == "-" { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let trimmed = String(slug.prefix(40))
        return trimmed.isEmpty ? "character" : trimmed
    }

    // MARK: - The shipped character

    public static let builtInID = "builtin"

    /// The character vendored into the app bundle.
    ///
    /// Only `.thinking` loops. Everything else plays a short sequence and
    /// settles, because the panel is something the user is *reading* — a
    /// character that keeps moving under a paragraph of text competes with it,
    /// and at ~30 invocations a day that stops being charming quickly.
    public static let builtIn = SpriteSet(
        id: builtInID,
        name: "Guitarist",
        animations: [
            SpriteMood.idle.rawValue:
                SpriteAnimation(frames: ["pose-3"], frameDuration: 1, loops: false),
            SpriteMood.searching.rawValue:
                SpriteAnimation(frames: ["pose-3"], frameDuration: 1, loops: false),
            // The 6-frame walk cycle: reads as pacing while it works.
            SpriteMood.thinking.rawValue:
                SpriteAnimation(
                    frames: (0..<6).map { "walk-\($0)" },
                    frameDuration: 0.11,
                    loops: true),
            // Celebrate, then settle. The resting frame is the standing pose, so
            // Reduce Motion shows a calm character rather than a frozen leap.
            SpriteMood.talking.rawValue:
                SpriteAnimation(
                    frames: ["pose-1", "pose-0", "pose-3"],
                    frameDuration: 0.16,
                    loops: false),
            SpriteMood.confused.rawValue:
                SpriteAnimation(frames: ["pose-2"], frameDuration: 1, loops: false),
        ])
}
