import SwiftUI
import AskAICore

/// The Sprites tab: describe a character, generate it, look at it, keep it.
struct SpriteStudioView: View {
    @ObservedObject var model: SpriteStudioModel

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
    }

    // MARK: Which character is in use

    private var characterPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Character", selection: $model.activeSetID) {
                ForEach(model.installedSets) { set in
                    Text(set.name).tag(set.id)
                }
            }
            Text("Shown beside the answer when you use Ask AI.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

            DisclosureGroup("Advanced") {
                TextField("Image model", text: $model.modelID)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Preview endpoints get renamed and retired. The output format "
                     + "follows the model, so changing it changes what comes back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
