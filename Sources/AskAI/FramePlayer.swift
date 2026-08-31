import AppKit
import SwiftUI
import AskAICore

/// Animates frames held in memory.
///
/// Separate from `SpriteAnimator`, which resolves frames from disk for the
/// panel. Settings needs to animate two things the panel never does: a character
/// that is only in memory because it has not been kept yet, and an arbitrary
/// mood of an installed character. Both are just "these images, in this order".
///
/// Main-thread only, and no `@MainActor` — the same convention as the rest of
/// the AppKit layer.
final class FramePlayer: ObservableObject {

    @Published private(set) var current: NSImage?
    /// True while a timer is running, so the caller can say why it is still.
    @Published private(set) var isAnimating = false

    private var images: [NSImage] = []
    private var timer: Timer?
    private var index = 0
    private var loops = false

    /// True when the system asks for reduced motion.
    ///
    /// Honoured here as well as in the panel. A preview exists to show motion,
    /// so this is arguably the one place to ignore it — but an app that respects
    /// the setting everywhere except where it matters is just inconsistent, and
    /// the view says why the character is holding still.
    var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Plays an animation whose frames are looked up in `images`.
    ///
    /// Missing frames are skipped rather than treated as an error: a half-loaded
    /// set should show what it has, not nothing.
    func play(_ animation: SpriteAnimation, from images: [String: NSImage]) {
        stop()
        let ordered = animation.frames.compactMap { images[$0] }
        guard !ordered.isEmpty else { current = nil; return }

        self.images = ordered
        self.loops = animation.loops
        index = 0
        current = ordered[0]

        guard ordered.count > 1, !prefersReducedMotion else {
            // Settle on the resting frame, matching what the panel would show.
            current = images[animation.restingFrame] ?? ordered[ordered.count - 1]
            return
        }

        let timer = Timer(timeInterval: animation.frameDuration, repeats: true) {
            [weak self] _ in self?.advance()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        isAnimating = true
    }

    private func advance() {
        index += 1
        if index >= images.count {
            guard loops else {
                index = images.count - 1
                current = images[index]
                stop()
                return
            }
            index = 0
        }
        current = images[index]
    }

    /// Halts playback. Called when the Settings window closes, so a preview
    /// nobody can see is not burning a timer.
    func stop() {
        timer?.invalidate()
        timer = nil
        isAnimating = false
    }

    deinit { timer?.invalidate() }
}

/// Draws whatever the player currently holds.
struct FramePlayerView: View {
    @ObservedObject var player: FramePlayer
    var height: CGFloat = 72

    var body: some View {
        Group {
            if let image = player.current {
                Image(nsImage: image)
                    .interpolation(.none)   // keep pixel art hard-edged
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(
                        Image(systemName: "person.crop.square.badge.questionmark")
                            .foregroundStyle(.tertiary))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
