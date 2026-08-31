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
            editedName = sets.set(id: activeSetID)?.name ?? ""
            refreshPreview()
        }
    }

    /// Which mood the preview plays. Defaults to the loop, since that is the
    /// one the user will actually watch in the panel.
    @Published var previewMood: SpriteMood = .thinking {
        didSet { refreshPreview() }
    }

    /// Animates whichever character is selected, or the one just generated.
    let player = FramePlayer()
    /// Shown once, before the first paid run.
    @Published var showCostWarning = false
    /// Confirmation before a destructive delete.
    @Published var showDeleteConfirmation = false
    /// The editable display name of the selected character.
    @Published var editedName: String = ""

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
        self.editedName = sets.set(id: store.activeSpriteSetID)?.name ?? ""
        refreshPreview()
    }

    // MARK: - Managing characters

    /// The selected character, or the built-in one.
    var selectedSet: SpriteSet? { sets.set(id: activeSetID) }

    /// The built-in character ships inside the app bundle and is the fallback
    /// for everything else, so it cannot be renamed, regenerated or removed.
    var selectionIsEditable: Bool { activeSetID != SpriteSet.builtInID }

    /// Human-readable size of the selected character on disk.
    var selectedSizeDescription: String? {
        guard selectionIsEditable else { return nil }
        let bytes = sets.sizeOnDisk(id: activeSetID)
        guard bytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    func commitRename() {
        guard selectionIsEditable else { return }
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != selectedSet?.name else {
            // Reject silently by restoring: an empty name is a slip, not a
            // decision worth an error banner.
            editedName = selectedSet?.name ?? ""
            return
        }
        do {
            try sets.rename(id: activeSetID, to: trimmed)
            installedSets = sets.installedSets()
        } catch let error as SpriteSetError {
            phase = .failed(error.userMessage)
            editedName = selectedSet?.name ?? ""
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Removes the selected character.
    ///
    /// The delicate part is that the panel may be showing it right now. Order
    /// matters: switch the selection to the built-in *first*, so the panel is
    /// already looking elsewhere, then delete the files and drop the cache.
    func deleteSelected() {
        guard selectionIsEditable else { return }
        let doomed = activeSetID
        activeSetID = SpriteSet.builtInID      // didSet re-points the panel
        do {
            try sets.delete(id: doomed)
            SpriteLoader.forget(doomed)
            installedSets = sets.installedSets()
            editedName = selectedSet?.name ?? ""
            refreshPreview()
        } catch let error as SpriteSetError {
            phase = .failed(error.userMessage)
        } catch {
            phase = .failed("Couldn't remove the character: \(error.localizedDescription)")
        }
    }

    /// Regenerates the selected character's art with the current prompts.
    ///
    /// This is the only way to bring a character made under older prompts up to
    /// date: its frames *are* the old actions, and no manifest edit can turn a
    /// walk cycle into pondering. Reuses the description and the id, so the
    /// result replaces the original rather than accumulating a near-duplicate.
    func regenerateSelected() {
        guard let set = selectedSet, selectionIsEditable else { return }
        description = set.name
        showCostWarning = true
    }

    // MARK: - Preview

    /// Loads the selected character's frames and plays the chosen mood.
    ///
    /// Reads through `SpriteLoader`, the same path the panel uses, so what the
    /// preview shows is what the panel will show — including a set that has lost
    /// its frames, which resolves to the built-in one rather than to nothing.
    func refreshPreview() {
        // A generated character awaiting keep-or-discard takes precedence: it is
        // the thing the user is being asked to judge.
        if !previewFrames.isEmpty {
            playPreviewOfPending()
            return
        }
        let set = store.activeSpriteSet(store: sets)
        var images: [String: NSImage] = [:]
        for name in set.allFrames {
            images[name] = SpriteLoader.image(named: name, in: set)
        }
        player.play(set.animation(for: previewMood), from: images)
    }

    private func playPreviewOfPending() {
        guard let pending else { return }
        player.play(pending.set.animation(for: previewMood), from: previewFrames)
    }

    /// Stops the preview timer. Called when the Settings window closes.
    func stopPreview() {
        player.stop()
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
        refreshPreview()
    }

    private func finish(_ output: SpriteGenerationJob.Output) {
        pending = output
        previewFrames = output.frames.compactMapValues { NSImage(data: $0) }
        phase = .preview
        playPreviewOfPending()
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
            self.pending = nil
            previewFrames = [:]
            phase = .idle
            // Assign last: the didSet refreshes the preview, and it must read
            // the saved frames rather than the ones being cleared above.
            activeSetID = pending.set.id
            refreshPreview()
        } catch {
            phase = .failed("Couldn't save the character: \(error.localizedDescription)")
        }
    }

    func discard() {
        pending = nil
        previewFrames = [:]
        phase = .idle
        refreshPreview()
    }

    func refreshSets() {
        installedSets = sets.installedSets()
        editedName = sets.set(id: activeSetID)?.name ?? ""
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
