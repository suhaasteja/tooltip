import SwiftUI
import AppKit
import AskAICore

/// Loads sprite frames out of `Contents/Resources/Sprites`, once.
///
/// Deliberately `Bundle.main` and not `Bundle.module`: SwiftPM's generated
/// accessor for an *executable* target searches `Bundle.main.bundleURL`, which
/// for a .app is the bundle root rather than `Contents/Resources`, so it can
/// never find its own bundle here -- and it calls `fatalError` rather than
/// returning nil. `scripts/bundle.sh` copies the frames into place instead.
///
/// A missing frame returns nil rather than trapping: a sprite that fails to load
/// should degrade to no character, never take the panel down with it.
enum SpriteLoader {

    /// Keyed by set id *and* frame name: two sets will both have a `walk-0`.
    private static var cache: [String: NSImage] = [:]
    private static let store = SpriteSetStore()

    static func image(named name: String, in set: SpriteSet) -> NSImage? {
        let key = "\(set.id)/\(name)"
        if let hit = cache[key] { return hit }

        let url: URL?
        if set.id == SpriteSet.builtInID {
            url = Bundle.main.url(
                forResource: name, withExtension: "png", subdirectory: "Sprites")
        } else {
            let candidate = store.directory(for: set.id)
                .appendingPathComponent("\(name).png")
            url = FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }

        guard let url, let image = NSImage(contentsOf: url) else {
            Log.panel.error(
                "sprite frame missing: \(set.id, privacy: .public)/\(name, privacy: .public)")
            return nil
        }
        // The PNGs are 2x. Halving the reported size makes SwiftUI lay them out
        // in points while still drawing every pixel on Retina.
        image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        cache[key] = image
        return image
    }

    /// Warms the cache so the first invocation does not decode PNGs while the
    /// user is waiting on it.
    static func preload(_ set: SpriteSet) {
        for frame in set.allFrames { _ = image(named: frame, in: set) }
    }

    /// The point size of this set's frames, or nil if none could be loaded.
    ///
    /// Used to size the character's slot in the panel. Hardcoding the slot means
    /// `scaledToFit` letterboxes the character inside it — dead space that reads
    /// as the panel sitting further from the selected text than it is, and which
    /// changes with every character because generated frames are not all the
    /// same shape.
    static func frameSize(for set: SpriteSet, fallback: CGSize) -> CGSize {
        for name in set.allFrames {
            if let image = image(named: name, in: set), image.size.width > 0 {
                return image.size
            }
        }
        return fallback
    }

    /// Drops cached frames for a set, so a regenerated character is picked up
    /// without relaunching.
    static func forget(_ setID: String) {
        cache = cache.filter { !$0.key.hasPrefix("\(setID)/") }
    }
}

/// Drives frame playback for a mood.
///
/// A timer rather than `TimelineView(.animation)` on purpose: this app is an
/// `LSUIElement` process that stays resident for weeks, and `.animation` redraws
/// at display rate for as long as the view exists. Here nothing runs unless a
/// mood actually needs it, and `stop()` is called when the panel hides.
///
/// Main-thread only, like the rest of the AppKit layer — no `@MainActor`, which
/// would drag in isolation checking this package deliberately opts out of.
final class SpriteAnimator: ObservableObject {

    @Published private(set) var frameName: String

    /// The character being played. Swapping it restarts the current mood, so a
    /// newly generated set is visible without relaunching.
    private(set) var set: SpriteSet

    private var mood: SpriteMood = .idle
    private var timer: Timer?
    private var index = 0

    init(set: SpriteSet = .builtIn, mood: SpriteMood = .idle) {
        self.set = set
        self.mood = mood
        self.frameName = set.animation(for: mood).restingFrame
    }

    func use(_ newSet: SpriteSet) {
        guard newSet != set else { return }
        set = newSet
        SpriteLoader.preload(newSet)
        let current = mood
        // Force a restart: `play` short-circuits when the mood is unchanged.
        mood = .idle
        play(current)
    }

    /// True when the system asks for reduced motion. Read live rather than
    /// cached: the user can change it while the app is resident, and this is
    /// cheap.
    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func play(_ newMood: SpriteMood, animated: Bool = true) {
        // Restarting an already-playing mood would jump the walk cycle back to
        // frame 0 on every streamed delta, which reads as a stutter.
        guard newMood != mood || timer == nil else { return }
        mood = newMood
        stopTimer()

        let animation = set.animation(for: newMood)
        guard animated, !prefersReducedMotion, set.needsAnimation(for: newMood) else {
            frameName = animation.restingFrame
            return
        }

        index = 0
        frameName = animation.frames[0]

        let timer = Timer(timeInterval: animation.frameDuration, repeats: true) {
            [weak self] _ in
            self?.advance()
        }
        // .common so playback does not freeze while a menu is tracking or the
        // panel is being dragged.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func advance() {
        let animation = set.animation(for: mood)
        index += 1
        if index >= animation.frames.count {
            guard animation.loops else {
                // Settle on the resting pose and stop burning a timer on it.
                index = animation.frames.count - 1
                frameName = animation.restingFrame
                stopTimer()
                return
            }
            index = 0
        }
        frameName = animation.frames[index]
    }

    /// Pins playback to one frame of the current mood. Snapshot testing only.
    func showFrame(at index: Int) {
        stopTimer()
        let frames = set.animation(for: mood).frames
        self.index = min(max(index, 0), frames.count - 1)
        frameName = frames[self.index]
    }

    /// Halts playback. Called when the panel hides, so a resident background app
    /// is never animating something nobody can see.
    func stop() {
        stopTimer()
        frameName = set.animation(for: mood).restingFrame
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

/// The character itself.
struct SpriteView: View {
    @ObservedObject var animator: SpriteAnimator
    /// Optional. When nil the character fills whatever rect it is given, which
    /// is what the panel wants: the rect is already the frames' own size, so
    /// there is nothing to letterbox.
    var height: CGFloat?

    var body: some View {
        Group {
            if let image = SpriteLoader.image(named: animator.frameName, in: animator.set) {
                Image(nsImage: image)
                    .interpolation(.none)  // keep pixel art hard-edged
                    .resizable()
                    .scaledToFit()
            } else {
                // Degrade to a glyph rather than leaving a hole.
                Image(systemName: "sparkle").font(.system(size: (height ?? 60) * 0.4))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)  // decorative; the answer text carries meaning
    }
}
