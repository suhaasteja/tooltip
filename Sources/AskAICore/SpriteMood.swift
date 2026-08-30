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
public struct SpriteAnimation: Equatable, Sendable {

    /// Resource basenames, in playback order. Never empty.
    public let frames: [String]
    /// How long each frame is held.
    public let frameDuration: TimeInterval
    /// When false, the sequence plays once and holds `frames.last`.
    public let loops: Bool

    public init(frames: [String], frameDuration: TimeInterval, loops: Bool) {
        precondition(!frames.isEmpty, "an animation needs at least one frame")
        self.frames = frames
        self.frameDuration = frameDuration
        self.loops = loops
    }

    /// The frame shown when motion is suppressed — either by the system's
    /// Reduce Motion setting or by the user turning the character's animation
    /// off. This is the *last* frame, not the first, because non-looping
    /// sequences are authored to settle into their resting pose: the celebration
    /// is the lead-in, the resting pose is the honest still.
    public var restingFrame: String { frames[frames.count - 1] }

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

public extension SpriteMood {

    /// The animation for this mood.
    ///
    /// Only `.thinking` loops. Everything else plays a short sequence and
    /// settles, because the panel is something the user is *reading* — a
    /// character that keeps moving under a paragraph of text competes with it,
    /// and at ~30 invocations a day that stops being charming quickly.
    var animation: SpriteAnimation {
        switch self {
        case .idle, .searching:
            return SpriteAnimation(frames: ["pose-3"], frameDuration: 1, loops: false)

        case .thinking:
            // The 6-frame walk cycle: reads as pacing while it works.
            return SpriteAnimation(
                frames: (0..<6).map { "walk-\($0)" },
                frameDuration: 0.11,
                loops: true)

        case .talking:
            // Celebrate, then settle. `restingFrame` is the standing pose, so
            // Reduce Motion shows a calm character rather than a frozen leap.
            return SpriteAnimation(
                frames: ["pose-1", "pose-0", "pose-3"],
                frameDuration: 0.16,
                loops: false)

        case .confused:
            return SpriteAnimation(frames: ["pose-2"], frameDuration: 1, loops: false)
        }
    }

    /// Whether this mood needs a running timer at all. A single-frame animation
    /// never does, and in a background app that lives for weeks an unnecessary
    /// display-rate redraw is a real battery cost.
    var needsAnimation: Bool { animation.frames.count > 1 }
}
