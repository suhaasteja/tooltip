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

    private static var cache: [String: NSImage] = [:]

    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let url = Bundle.main.url(
                forResource: name, withExtension: "png", subdirectory: "Sprites"),
              let image = NSImage(contentsOf: url)
        else {
            Log.panel.error("sprite frame missing: \(name, privacy: .public)")
            return nil
        }
        // The PNGs are 2x. Halving the reported size makes SwiftUI lay them out
        // in points while still drawing every pixel on Retina.
        image.size = NSSize(width: image.size.width / 2, height: image.size.height / 2)
        cache[name] = image
        return image
    }

    /// Warms the cache so the first invocation does not decode PNGs while the
    /// user is waiting on it.
    static func preload() {
        for mood in SpriteMood.allCases {
            for frame in mood.animation.frames { _ = image(named: frame) }
        }
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

    private var mood: SpriteMood = .idle
    private var timer: Timer?
    private var index = 0

    init(mood: SpriteMood = .idle) {
        self.mood = mood
        self.frameName = mood.animation.restingFrame
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

        let animation = newMood.animation
        guard animated, !prefersReducedMotion, newMood.needsAnimation else {
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
        let animation = mood.animation
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
        let frames = mood.animation.frames
        self.index = min(max(index, 0), frames.count - 1)
        frameName = frames[self.index]
    }

    /// Halts playback. Called when the panel hides, so a resident background app
    /// is never animating something nobody can see.
    func stop() {
        stopTimer()
        frameName = mood.animation.restingFrame
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
    var height: CGFloat = 66

    var body: some View {
        Group {
            if let image = SpriteLoader.image(named: animator.frameName) {
                Image(nsImage: image)
                    .interpolation(.none)  // keep pixel art hard-edged
                    .resizable()
                    .scaledToFit()
            } else {
                // Degrade to the old glyph rather than leaving a hole.
                Image(systemName: "sparkle").font(.system(size: height * 0.4))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)  // decorative; the answer text carries meaning
    }
}
