import Foundation

/// The prompts that turn a one-line character description into sheets.
///
/// The actions are chosen for **what this app does**: someone highlights a word
/// or a passage and asks for it to be explained. So the character ponders and
/// then explains. The first draft inherited walk/jump/attack from
/// `~/Desktop/sprite-sheet-creator`, which is a platformer's vocabulary — a
/// character walking on the spot while an explanation loads reads as filler,
/// not as thought.
///
/// The two sheet templates are user-editable; `SettingsStore` holds any
/// override and these are the defaults.
public enum SpritePrompts {

    /// Substituted with the character description.
    public static let placeholder = "{{character}}"

    /// Appended to every prompt. Kept out of the user's field so a description
    /// stays a description.
    ///
    /// It asks for white and for margins. It does **not** ask for "no borders":
    /// both models draw them regardless, so the extractor removes them instead
    /// of the prompt pretending to prevent them.
    public static let style = """
        Classic 16-bit video game sprite art, clean crisp pixels. Identical \
        character design in every frame. Pure white background. Leave generous \
        white margins so no frame's character touches a cell edge.
        """

    /// The looping animation shown while an answer is being fetched.
    ///
    /// A *thinking* cycle rather than a walk cycle. It is the only looping
    /// animation, so it is the one the user actually watches for several
    /// seconds — it has to read as considering the question.
    public static let defaultThinkingTemplate = """
        Create a 6-frame pixel art animation of \(placeholder) thinking hard \
        about a difficult question.

        Arrange the 6 frames in a 2x3 grid (2 rows, 3 columns). The six frames \
        form one smooth repeating loop of pondering, seen from the front.
        Top row: hand beginning to rise toward the chin; hand resting on the \
        chin, eyes glancing upward; head tilted, brow furrowed in concentration.
        Bottom row: head tilted the other way, still pondering; one finger \
        tapping the chin, eyes narrowed; hand lowering slightly, ready to begin \
        the loop again.

        The character stays in the same spot in every frame. Do not show walking.
        """

    /// The four non-looping moods, in the order `SpriteSet` expects them.
    ///
    /// **The order is load-bearing.** Frames are mapped to moods by position,
    /// so swapping two lines swaps two moods.
    public static let defaultPosesTemplate = """
        Create a 4-frame pixel art sprite sheet of \(placeholder), showing four \
        different poses, seen from the front.

        Arrange the 4 frames in a 2x2 grid.
        Top-left: standing attentively, relaxed, waiting to be asked something.
        Top-right: explaining, one hand raised palm-up in a teaching gesture, \
        mouth open mid-sentence.
        Bottom-left: puzzled, shrugging with both palms up and eyebrows raised.
        Bottom-right: searching, peering around with one hand shading the eyes.

        The character stays in the same spot in every frame.
        """

    /// Fills in the character description and appends the style rules.
    public static func render(template: String, character: String) -> String {
        let filled = template.contains(placeholder)
            ? template.replacingOccurrences(of: placeholder, with: character)
            // A template that dropped the placeholder would otherwise generate a
            // character nobody asked for; append rather than silently ignore.
            : template + "\n\nThe character is \(character)."
        return filled + "\n\n" + style
    }

public static func character(_ description: String) -> String {
        """
        A single full-body pixel-art sprite of \(description), front-facing idle \
        pose, centred on a plain white background.

        \(style)
        """
    }
}

/// One sheet to generate, and how to cut it up.
public struct SpriteSheetSpec: Equatable, Sendable {
    public let id: String
    public let prompt: String
    public let columns: Int
    public let rows: Int
    public let aspectRatio: String
    /// Frame basenames, in row-major order.
    public let frameNames: [String]

    public init(id: String, prompt: String, columns: Int, rows: Int,
                aspectRatio: String, frameNames: [String]) {
        self.id = id
        self.prompt = prompt
        self.columns = columns
        self.rows = rows
        self.aspectRatio = aspectRatio
        self.frameNames = frameNames
    }

    /// The looping "considering the question" animation.
    ///
    /// Frame basenames stay `walk-N` even though the action is no longer a walk:
    /// they are only filenames, and renaming them would orphan every character
    /// already generated. The id the user sees comes from the step label.
    public static func thinking(character: String, template: String) -> SpriteSheetSpec {
        SpriteSheetSpec(
            id: "thinking", prompt: SpritePrompts.render(template: template, character: character),
            columns: 3, rows: 2, aspectRatio: "4:3",
            frameNames: (0..<6).map { "walk-\($0)" })
    }

    public static func poses(character: String, template: String) -> SpriteSheetSpec {
        SpriteSheetSpec(
            id: "poses", prompt: SpritePrompts.render(template: template, character: character),
            columns: 2, rows: 2, aspectRatio: "1:1",
            frameNames: (0..<4).map { "pose-\($0)" })
    }
}

/// What the UI shows while a character is being generated.
public enum SpriteGenerationStep: Equatable, Sendable {
    case character
    case sheet(id: String, index: Int, of: Int)
    case extracting
    case done

    public var label: String {
        switch self {
        case .character: return "Designing the character…"
        case .sheet(let id, let index, let total):
            return "Generating \(id) (\(index) of \(total))…"
        case .extracting: return "Cutting out frames…"
        case .done: return "Done"
        }
    }
}

/// Drives a description through the model and out the other side as a
/// ready-to-install `SpriteSet` plus its frames.
///
/// Lives in the core library so the whole flow is testable against a fake
/// client, with no AppKit and no network — the same reason `AskOrchestrator`
/// does.
public struct SpriteGenerationJob {

    public struct Output: Equatable {
        public let set: SpriteSet
        /// PNG data keyed by frame basename, ready for `SpriteSetStore.save`.
        public let frames: [String: Data]
        /// The sheets as the model returned them, for a "show me the source" view.
        public let sheets: [String: GeneratedImage]
    }

    private let client: SpriteGeneratorClient
    private let encoder: (PixelBitmap) -> Data?

    /// - Parameter encoder: injected so the core stays free of ImageIO. The app
    ///   supplies a real PNG encoder; tests supply a stub.
    public init(client: SpriteGeneratorClient, encoder: @escaping (PixelBitmap) -> Data?) {
        self.client = client
        self.encoder = encoder
    }

    /// Generates a complete character.
    ///
    /// - Parameter progress: called on each step, so a caller can show which of
    ///   the several paid requests is in flight. The whole run takes tens of
    ///   seconds.
    public func run(
        id: String,
        name: String,
        description: String,
        thinkingTemplate: String = SpritePrompts.defaultThinkingTemplate,
        posesTemplate: String = SpritePrompts.defaultPosesTemplate,
        decode: (Data) -> PixelBitmap?,
        options: SpriteExtractor.Options = .init(snapToPixelGrid: true),
        progress: @Sendable (SpriteGenerationStep) -> Void = { _ in }
    ) async throws -> Output {

        // 1. The character itself. Every sheet is generated *from this image*,
        //    which is what holds identity: generating each sheet from the text
        //    alone yields a visibly different character each time.
        progress(.character)
        let reference = try await client.generate(
            prompt: SpritePrompts.character(description))

        let specs = [
            SpriteSheetSpec.thinking(character: description, template: thinkingTemplate),
            SpriteSheetSpec.poses(character: description, template: posesTemplate),
        ]

        var sheets: [String: GeneratedImage] = [:]
        var bitmaps: [(bitmap: PixelBitmap, columns: Int, rows: Int, keep: [Int])] = []

        // Generate every sheet first, then cut them together. Cutting each as it
        // arrives would scale each one to its own crop, and the same character
        // would come out at two different sizes -- visible the moment two moods
        // are seen side by side. See NOTES.md.
        for (index, spec) in specs.enumerated() {
            progress(.sheet(id: spec.id, index: index + 1, of: specs.count))
            try Task.checkCancellation()

            // The spec's aspect ratio must reach the request: a 2x2 grid asked
            // for at 4:3 comes back as 3x2 and then slices wrong.
            let sheet = try await client.generate(
                prompt: spec.prompt, reference: reference, aspectRatio: spec.aspectRatio)
            sheets[spec.id] = sheet

            guard let bitmap = decode(sheet.data) else {
                throw SpriteGeneratorError.decoding
            }
            bitmaps.append((bitmap, spec.columns, spec.rows, []))
        }

        progress(.extracting)
        try Task.checkCancellation()
        let cutSheets = try SpriteExtractor.frames(fromSheets: bitmaps, options: options)

        var frames: [String: Data] = [:]
        var animations: [String: SpriteAnimation] = [:]
        for (specIndex, spec) in specs.enumerated() where specIndex < cutSheets.count {
            for (frameIndex, frame) in cutSheets[specIndex].enumerated()
            where frameIndex < spec.frameNames.count {
                guard let png = encoder(frame) else { throw SpriteGeneratorError.decoding }
                frames[spec.frameNames[frameIndex]] = png
            }
        }

        // 2. Wire the frames to moods, matching the built-in set's timings so a
        //    generated character animates the way the shipped one does.
        let thinkingNames = SpriteSheetSpec.thinking(character: "", template: "").frameNames
            .filter { frames[$0] != nil }
        if !thinkingNames.isEmpty {
            // Slower than the old walk cycle's 0.11s. Pondering at walking speed
            // reads as agitation; this is the one loop the user watches for
            // several seconds while an answer loads.
            animations[SpriteMood.thinking.rawValue] = SpriteAnimation(
                frames: thinkingNames, frameDuration: 0.18, loops: true)
        }
        // Pose order is authored in the prompt and is load-bearing:
        // idle, explaining, puzzled, searching.
        if frames["pose-0"] != nil {
            animations[SpriteMood.idle.rawValue] = SpriteAnimation(
                frames: ["pose-0"], frameDuration: 1, loops: false)
        }
        if frames["pose-1"] != nil, frames["pose-0"] != nil {
            // Gesture, then settle to attentive. Deliberately does not loop: the
            // panel is showing an answer the user is reading, and a character
            // still moving underneath competes with the text.
            animations[SpriteMood.talking.rawValue] = SpriteAnimation(
                frames: ["pose-1", "pose-0"], frameDuration: 0.22, loops: false)
        }
        if frames["pose-2"] != nil {
            animations[SpriteMood.confused.rawValue] = SpriteAnimation(
                frames: ["pose-2"], frameDuration: 1, loops: false)
        }
        if frames["pose-3"] != nil {
            animations[SpriteMood.searching.rawValue] = SpriteAnimation(
                frames: ["pose-3"], frameDuration: 1, loops: false)
        }

        progress(.done)
        return Output(
            set: SpriteSet(id: id, name: name, animations: animations),
            frames: frames,
            sheets: sheets)
    }
}
