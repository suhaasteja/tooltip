import Foundation

/// The prompts that turn a one-line character description into sheets.
///
/// Adapted from `~/Desktop/sprite-sheet-creator`, with the animations changed:
/// its walk/jump/attack is a platformer's vocabulary, and this app needs the
/// five `SpriteMood` cases instead.
public enum SpritePrompts {

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

    public static func walk(character: String) -> String {
        """
        Create a 6-frame pixel art walk cycle sprite sheet of \(character).

        Arrange the 6 frames in a 2x3 grid (2 rows, 3 columns). The character \
        walks to the right.
        Top row: stride right, legs passing, stride left.
        Bottom row: legs passing, stride right, legs passing.

        \(style)
        """
    }

    /// The four non-walking moods, in the order `SpriteSet` expects them.
    public static func poses(character: String) -> String {
        """
        Create a 4-frame pixel art sprite sheet of \(character), showing four \
        different poses.

        Arrange the 4 frames in a 2x2 grid.
        Top-left: standing idle, facing forward, relaxed.
        Top-right: celebrating, one arm raised high in triumph.
        Bottom-left: confused, shrugging with both palms up.
        Bottom-right: looking around searchingly, one hand shading the eyes.

        \(style)
        """
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

    public static func walk(character: String) -> SpriteSheetSpec {
        SpriteSheetSpec(
            id: "walk", prompt: SpritePrompts.walk(character: character),
            columns: 3, rows: 2, aspectRatio: "4:3",
            frameNames: (0..<6).map { "walk-\($0)" })
    }

    public static func poses(character: String) -> SpriteSheetSpec {
        SpriteSheetSpec(
            id: "pose", prompt: SpritePrompts.poses(character: character),
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

        let specs = [SpriteSheetSpec.walk(character: description),
                     SpriteSheetSpec.poses(character: description)]

        var frames: [String: Data] = [:]
        var sheets: [String: GeneratedImage] = [:]
        var animations: [String: SpriteAnimation] = [:]

        for (index, spec) in specs.enumerated() {
            progress(.sheet(id: spec.id, index: index + 1, of: specs.count))
            try Task.checkCancellation()

            let sheet = try await client.generate(prompt: spec.prompt, reference: reference)
            sheets[spec.id] = sheet

            progress(.extracting)
            guard let bitmap = decode(sheet.data) else {
                throw SpriteGeneratorError.decoding
            }
            let cut = try SpriteExtractor.frames(
                from: bitmap, columns: spec.columns, rows: spec.rows, options: options)

            for (frameIndex, frame) in cut.enumerated() where frameIndex < spec.frameNames.count {
                guard let png = encoder(frame) else { throw SpriteGeneratorError.decoding }
                frames[spec.frameNames[frameIndex]] = png
            }
        }

        // 2. Wire the frames to moods, matching the built-in set's timings so a
        //    generated character animates the way the shipped one does.
        let walkNames = SpriteSheetSpec.walk(character: "").frameNames
            .filter { frames[$0] != nil }
        if !walkNames.isEmpty {
            animations[SpriteMood.thinking.rawValue] = SpriteAnimation(
                frames: walkNames, frameDuration: 0.11, loops: true)
        }
        // Pose order is authored in the prompt: idle, celebrate, confused, searching.
        if frames["pose-0"] != nil {
            animations[SpriteMood.idle.rawValue] = SpriteAnimation(
                frames: ["pose-0"], frameDuration: 1, loops: false)
        }
        if frames["pose-1"] != nil, frames["pose-0"] != nil {
            // Celebrate, then settle on idle — the resting frame must be calm,
            // because that is what Reduce Motion shows.
            animations[SpriteMood.talking.rawValue] = SpriteAnimation(
                frames: ["pose-1", "pose-0"], frameDuration: 0.16, loops: false)
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
