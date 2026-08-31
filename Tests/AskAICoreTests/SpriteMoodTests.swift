import Testing
@testable import AskAICore

@Suite("Sprite moods")
struct SpriteMoodTests {

    @Test("every panel state maps to a mood")
    func everyStateMaps() {
        #expect(SpriteMood.mood(for: .idle) == .idle)
        #expect(SpriteMood.mood(for: .loading(selection: "x")) == .thinking)
        #expect(SpriteMood.mood(for: .success(selection: "x", answer: "y")) == .talking)
        #expect(
            SpriteMood.mood(for: .failure(selection: "x", message: "m", retryable: true))
                == .confused)
        #expect(SpriteMood.mood(for: .emptySelection) == .searching)
    }

    @Test("every mood has at least one frame and a positive duration")
    func animationsAreWellFormed() {
        for mood in SpriteMood.allCases {
            let animation = SpriteSet.builtIn.animation(for: mood)
            #expect(!animation.frames.isEmpty, "\(mood) has no frames")
            #expect(animation.frameDuration > 0, "\(mood) has a non-positive duration")
        }
    }

    /// The frame names are resolved against the resource bundle at runtime, so a
    /// typo here is a silent missing sprite rather than a compile error.
    @Test("frame names refer to sheets that exist")
    func frameNamesAreKnown() {
        let known = Set(
            (0..<6).map { "walk-\($0)" } + (0..<4).map { "pose-\($0)" })
        for mood in SpriteMood.allCases {
            for frame in SpriteSet.builtIn.animation(for: mood).frames {
                #expect(known.contains(frame), "\(mood) references unknown frame \(frame)")
            }
        }
    }

    @Test("only thinking loops; everything else settles")
    func onlyThinkingLoops() {
        for mood in SpriteMood.allCases {
            #expect(SpriteSet.builtIn.animation(for: mood).loops == (mood == .thinking),
                    "\(mood) loops incorrectly")
        }
    }

    @Test("single-frame moods need no timer")
    func staticMoodsNeedNoAnimation() {
        let set = SpriteSet.builtIn
        #expect(set.needsAnimation(for: .thinking))
        #expect(set.needsAnimation(for: .talking))
        #expect(!set.needsAnimation(for: .idle))
        #expect(!set.needsAnimation(for: .confused))
        #expect(!set.needsAnimation(for: .searching))
    }
}

@Suite("Sprite animation playback")
struct SpriteAnimationTests {

    private let looping = SpriteAnimation(
        frames: ["a", "b", "c"], frameDuration: 0.1, loops: true)
    private let oneShot = SpriteAnimation(
        frames: ["a", "b", "c"], frameDuration: 0.1, loops: false)

    @Test("a looping animation wraps")
    func loopingWraps() {
        #expect(looping.frame(at: 0) == "a")
        #expect(looping.frame(at: 0.15) == "b")
        #expect(looping.frame(at: 0.25) == "c")
        #expect(looping.frame(at: 0.35) == "a")
        // Still aligned after many cycles: step 30, and 30 % 3 == 0.
        #expect(looping.frame(at: 3.05) == "a")
    }

    @Test("a one-shot animation clamps to its last frame")
    func oneShotClamps() {
        #expect(oneShot.frame(at: 0.05) == "a")
        #expect(oneShot.frame(at: 0.25) == "c")
        #expect(oneShot.frame(at: 100) == "c")
    }

    @Test("time before the start clamps to the first frame")
    func negativeTimeClamps() {
        #expect(looping.frameIndex(at: -5) == 0)
        #expect(oneShot.frameIndex(at: -5) == 0)
    }

    /// Reduce Motion shows this frame, so a non-looping sequence must settle on
    /// its calm pose rather than freezing mid-gesture.
    @Test("the resting frame is the last one, not the first")
    func restingFrameIsLast() {
        #expect(oneShot.restingFrame == "c")
        // The shipped character explains, then settles onto its attentive idle
        // pose — that is what Reduce Motion shows, not the raised wing.
        let talking = SpriteSet.builtIn.animation(for: .talking)
        #expect(talking.restingFrame == "pose-0")
        #expect(talking.restingFrame == talking.frames.last)
    }

    @Test("cycle duration covers every frame once")
    func cycleDuration() {
        #expect(abs(looping.cycleDuration - 0.3) < 0.0001)
    }

    @Test("a single-frame animation is stable at any time")
    func singleFrameIsStable() {
        let still = SpriteAnimation(frames: ["only"], frameDuration: 1, loops: true)
        #expect(still.frame(at: 0) == "only")
        #expect(still.frame(at: 999) == "only")
    }
}
