import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AskAICore

/// Backing store for the Sprites tab: generate a character, preview it, keep or
/// discard it.
///
/// Nothing here blocks the main thread. The generation is several paid requests
/// taking ~53 seconds end to end, and the Keychain incident in NOTES.md is the
/// reminder of what blocking the main thread costs.
///
/// Main-thread only for state, with explicit hops rather than `@MainActor` —
/// the same convention as the rest of the AppKit layer, which this package
/// deliberately keeps free of actor isolation. See Package.swift.
final class SpriteStudioModel: ObservableObject {

    // MARK: Inputs

    @Published var description: String = ""
    @Published var imageAPIKey: String = ""
    @Published var modelID: String = SpriteGeneratorConfiguration.defaultModel

    /// The two sheet prompts. Editable, because what the character *does* is a
    /// taste call — and because the shipped defaults are aimed at explaining
    /// words, which is not the only thing someone might want.
    @Published var thinkingPrompt: String = "" {
        didSet { store.thinkingPrompt = thinkingPrompt }
    }
    @Published var posesPrompt: String = "" {
        didSet { store.posesPrompt = posesPrompt }
    }

    // MARK: State

    enum Phase: Equatable {
        case idle
        case running(step: String)
        case preview
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// Frames of the character just generated, awaiting keep-or-discard.
    @Published private(set) var previewFrames: [String: NSImage] = [:]
    @Published private(set) var installedSets: [SpriteSet] = []
    @Published var activeSetID: String {
        didSet {
            guard activeSetID != oldValue else { return }
            store.activeSpriteSetID = activeSetID
            onChange()
        }
    }
    /// Shown once, before the first paid run.
    @Published var showCostWarning = false

    private var pending: SpriteGenerationJob.Output?
    private var task: Task<Void, Never>?

    private let store: SettingsStore
    private let keychain: KeychainStore
    private let imageKeychain: KeychainStore
    private let sets: SpriteSetStore
    private let onChange: () -> Void

    init(
        store: SettingsStore,
        keychain: KeychainStore,
        sets: SpriteSetStore = SpriteSetStore(),
        onChange: @escaping () -> Void
    ) {
        self.store = store
        self.keychain = keychain
        // A separate account on the same service, so an image key cannot
        // clobber the chat key. `KeychainStore` is already parameterised for it.
        self.imageKeychain = KeychainStore(
            service: keychain.service, account: "image-api-key")
        self.sets = sets
        self.onChange = onChange
        self.activeSetID = store.activeSpriteSetID
        self.installedSets = sets.installedSets()
        self.imageAPIKey = ""
        self.thinkingPrompt = store.thinkingPrompt
        self.posesPrompt = store.posesPrompt
    }

    /// True when the configured LLM key already works for images, so the user
    /// need not paste a second credential.
    var reusesLLMKey: Bool { store.llmKeyWorksForImages }

    var isRunning: Bool { if case .running = phase { return true }; return false }

    var canGenerate: Bool {
        !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isRunning
    }

    // MARK: - Keys

    func saveImageKey() {
        try? imageKeychain.save(imageAPIKey)
        imageAPIKey = ""
    }

    /// Reads whichever key applies. **Blocks** — callers must be off the main
    /// thread. See NOTES.md.
    private static func resolveKey(reuse: Bool, chat: KeychainStore,
                                   image: KeychainStore) -> String? {
        if reuse, let key = try? chat.read(), !key.isEmpty { return key }
        return try? image.read()
    }

    // MARK: - Generating

    func generate() {
        guard canGenerate else { return }
        let description = self.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let reuse = reusesLLMKey
        let chat = keychain
        let image = imageKeychain
        let thinking = thinkingPrompt
        let poses = posesPrompt

        phase = .running(step: SpriteGenerationStep.character.label)
        previewFrames = [:]
        pending = nil

        task = Task { [weak self] in
            guard let self else { return }
            // The Keychain read can sit behind an authorization dialog for
            // seconds, so it happens off the main thread like every other read
            // in this app.
            let key = await Task.detached(priority: .userInitiated) {
                Self.resolveKey(reuse: reuse, chat: chat, image: image)
            }.value

            guard let key, !key.isEmpty else {
                self.onMain { $0.phase = .failed(SpriteGeneratorError.missingAPIKey.userMessage) }
                return
            }

            let client = GeminiImageClient(
                apiKey: key,
                configuration: SpriteGeneratorConfiguration(
                    model: model.isEmpty ? SpriteGeneratorConfiguration.defaultModel : model))
            let job = SpriteGenerationJob(client: client, encoder: Self.encodePNG)

            do {
                let output = try await job.run(
                    id: SpriteSet.makeID(from: description),
                    name: description,
                    description: description,
                    thinkingTemplate: thinking,
                    posesTemplate: poses,
                    decode: Self.decode,
                    progress: { step in
                        self.onMain { model in
                            guard model.isRunning else { return }
                            model.phase = .running(step: step.label)
                        }
                    })
                try Task.checkCancellation()
                self.onMain { $0.finish(output) }
            } catch is CancellationError {
                self.onMain { $0.phase = .idle }
            } catch let error as SpriteGeneratorError {
                self.onMain { $0.phase = .failed(error.userMessage) }
            } catch let error as SpriteExtractor.ExtractionError {
                self.onMain { $0.phase = .failed(Self.message(for: error)) }
            } catch {
                self.onMain { $0.phase = .failed(error.localizedDescription) }
            }
        }
    }

    /// Cancels in flight. Nothing is written until the user keeps a preview, so
    /// there is no partial set to clean up.
    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        previewFrames = [:]
        pending = nil
    }

    private func finish(_ output: SpriteGenerationJob.Output) {
        pending = output
        previewFrames = output.frames.compactMapValues { NSImage(data: $0) }
        phase = .preview
    }

    // MARK: - Keeping or discarding

    /// Writes the previewed character and switches to it.
    func keep() {
        guard let pending else { return }
        do {
            try sets.save(pending.set, frames: pending.frames)
            installedSets = sets.installedSets()
            // Drop any cached frames under this id first: regenerating a
            // character reuses its id, and stale images would win.
            SpriteLoader.forget(pending.set.id)
            activeSetID = pending.set.id
            self.pending = nil
            previewFrames = [:]
            phase = .idle
        } catch {
            phase = .failed("Couldn't save the character: \(error.localizedDescription)")
        }
    }

    func discard() {
        pending = nil
        previewFrames = [:]
        phase = .idle
    }

    func refreshSets() {
        installedSets = sets.installedSets()
    }

    func restorePrompts() {
        store.restoreSpritePrompts()
        thinkingPrompt = store.thinkingPrompt
        posesPrompt = store.posesPrompt
    }

    var promptsAreCustomised: Bool {
        store.isThinkingPromptCustomised || store.isPosesPromptCustomised
    }

    /// Publishes a change on the main thread. `@Published` from a background
    /// thread is a SwiftUI data race; every state write in the job goes through
    /// here.
    private func onMain(_ body: @escaping (SpriteStudioModel) -> Void) {
        if Thread.isMainThread {
            body(self)
        } else {
            DispatchQueue.main.async { body(self) }
        }
    }

    // MARK: - Helpers

    static func message(for error: SpriteExtractor.ExtractionError) -> String {
        switch error {
        case .gridTooFine:
            return "The generated sheet was too small to cut up. Try again."
        case .noCharacters:
            return "No character could be found in the generated sheet. "
                + "Try rewording the description."
        }
    }

    static func encodePNG(_ bitmap: PixelBitmap) -> Data? {
        var bitmap = bitmap
        let image: CGImage? = bitmap.pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: bitmap.width, height: bitmap.height,
                bitsPerComponent: 8, bytesPerRow: bitmap.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// Decodes whatever the model returned — JPEG from the pro model, PNG from
    /// flash — so the extractor never has to care which.
    static func decode(_ data: Data) -> PixelBitmap? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var bitmap = PixelBitmap(width: image.width, height: image.height)
        let ok: Bool = bitmap.pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return ok ? bitmap : nil
    }
}
