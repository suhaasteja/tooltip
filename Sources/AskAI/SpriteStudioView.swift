import SwiftUI
import AskAICore

/// The Sprites tab: describe a character, generate it, look at it, keep it.
struct SpriteStudioView: View {
    @ObservedObject var model: SpriteStudioModel

    /// Which sheet's prompt the editor is showing.
    enum Sheet: Hashable { case thinking, poses }
    @State private var editedSheet: Sheet = .thinking

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            characterPicker
            Divider()
            switch model.phase {
            case .idle, .failed:
                generator
            case .running(let step):
                running(step)
            case .preview:
                preview
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .alert("Generating costs money", isPresented: $model.showCostWarning) {
            Button("Generate") { model.generate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creating a character sends three image requests to Google and "
                 + "is billed to your own API key. It takes about a minute.")
        }
        .alert("Delete this character?",
               isPresented: $model.showDeleteConfirmation) {
            Button("Delete", role: .destructive) { model.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its frames are removed from disk. Ask AI goes back to the "
                 + "built-in character. This cannot be undone — regenerating "
                 + "costs another paid run.")
        }
    }

    // MARK: Which character is in use

    private var characterPicker: some View {
        HStack(alignment: .top, spacing: 14) {
            // The character itself, animated, so switching between them is a
            // matter of looking rather than remembering what a name refers to.
            VStack(spacing: 4) {
                FramePlayerView(player: model.player, height: 72)
                    .frame(width: 84)
                Text(model.previewMood.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker("Character", selection: $model.activeSetID) {
                    ForEach(model.installedSets) { set in
                        Text(set.name).tag(set.id)
                    }
                }
                Picker("Preview", selection: $model.previewMood) {
                    ForEach(SpriteMood.allCases, id: \.self) { mood in
                        Text(Self.label(for: mood)).tag(mood)
                    }
                }

                if model.selectionIsEditable {
                    // Rename commits on Enter or on losing focus, rather than
                    // behind a modal: it is one string, and a dialog for it
                    // would be more ceremony than the change deserves.
                    TextField("Name", text: $model.editedName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.commitRename() }

                    HStack(spacing: 8) {
                        Button("Regenerate…") { model.regenerateSelected() }
                            .controlSize(.small)
                            .disabled(model.isRunning)
                        Button("Delete…") { model.showDeleteConfirmation = true }
                            .controlSize(.small)
                            .disabled(model.isRunning)
                        Spacer()
                        if let size = model.selectedSizeDescription {
                            Text(size).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("The built-in character can't be renamed or removed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.player.prefersReducedMotion {
                    Text("Holding still because Reduce Motion is on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Moods are named for the panel state they come from; these say what the
    /// user would actually see happen.
    private static func label(for mood: SpriteMood) -> String {
        switch mood {
        case .thinking: return "Thinking about an answer"
        case .talking: return "Explaining the answer"
        case .confused: return "Something went wrong"
        case .searching: return "Nothing was selected"
        case .idle: return "Waiting"
        }
    }

    // MARK: Making a new one

    private var generator: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create a character").font(.headline)

            TextField(
                "Description",
                text: $model.description,
                prompt: Text("a small round owl wearing tiny round spectacles"),
                axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            if !model.reusesLLMKey {
                SecureField("Google API key", text: $model.imageAPIKey)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") { model.saveImageKey() }
                        .disabled(model.imageAPIKey.isEmpty)
                    Text("Image generation needs a Google AI Studio key, separate "
                         + "from the one above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Using the Google key from the General tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Generate…") { model.showCostWarning = true }
                    .disabled(!model.canGenerate)
                    .keyboardShortcut(.defaultAction)
                Spacer()
                Text("~1 minute, 3 paid requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = model.phase {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("Actions and model") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What the character does. \(SpritePrompts.placeholder) is "
                         + "replaced by your description.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $editedSheet) {
                        Text("Thinking loop").tag(Sheet.thinking)
                        Text("Poses").tag(Sheet.poses)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    TextEditor(text: editedSheet == .thinking
                               ? $model.thinkingPrompt : $model.posesPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3)))

                    Text(editedSheet == .thinking
                         ? "Six frames, played as a loop while the answer loads."
                         : "Four frames. The order is load-bearing: idle, "
                           + "explaining, puzzled, searching. Swapping two lines "
                           + "swaps two moods.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Button("Restore defaults") { model.restorePrompts() }
                            .controlSize(.small)
                            .disabled(!model.promptsAreCustomised)
                        Spacer()
                    }

                    Divider()

                    TextField("Image model", text: $model.modelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                    Text("Preview endpoints get renamed and retired. The output "
                         + "format follows the model, so changing it changes what "
                         + "comes back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
    }

    // MARK: In flight

    private func running(_ step: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                // Named steps, not a bare spinner: a minute of silence reads as
                // a hang.
                Text(step).font(.callout)
            }
            Text("Nothing is saved until you keep it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Cancel") { model.cancel() }
        }
    }

    // MARK: Preview before committing

    private var preview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview").font(.headline)
            Text("Generated characters vary. Keep this one only if it looks right.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Animated first, then the frames laid out flat. The animation shows
            // whether it reads as thinking; the strip shows whether any single
            // frame came out mangled.
            HStack(alignment: .center, spacing: 14) {
                FramePlayerView(player: model.player, height: 72)
                    .frame(width: 84)
                Picker("Preview", selection: $model.previewMood) {
                    ForEach(SpriteMood.allCases, id: \.self) { mood in
                        Text(Self.label(for: mood)).tag(mood)
                    }
                }
                .frame(maxWidth: 230)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.previewFrames.keys.sorted(), id: \.self) { name in
                        if let image = model.previewFrames[name] {
                            VStack(spacing: 4) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 64)
                                Text(name)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 96)

            HStack {
                Button("Keep and use") { model.keep() }
                    .keyboardShortcut(.defaultAction)
                Button("Discard") { model.discard() }
                Spacer()
                Text("\(model.previewFrames.count) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
