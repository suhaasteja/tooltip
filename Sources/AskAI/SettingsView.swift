import SwiftUI
import AskAICore

/// Settings UI: API key, model, and the four editable prompt bodies.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var sprites: SpriteStudioModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            prompts.tabItem { Label("Prompts", systemImage: "text.bubble") }
            SpriteStudioView(model: sprites)
                .tabItem { Label("Sprites", systemImage: "person.crop.square") }
        }
        .frame(width: 520, height: 430)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                SecureField("API key", text: $model.apiKey, prompt: Text("sk-ant-…"))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save key") { model.saveAPIKey() }
                        .disabled(model.apiKey.isEmpty)
                    Button("Remove") { model.deleteAPIKey() }
                        .disabled(!model.hasStoredKey)
                    Spacer()
                    Text(model.keyStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.keyIsOptional
                     ? "Stored in the login Keychain. Local servers usually need no key — "
                       + "leave this empty."
                     : "Stored in the login Keychain, never in preferences.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Credentials").font(.headline)
            }

            Divider().padding(.vertical, 6)

            Section {
                Picker("Provider", selection: $model.presetID) {
                    ForEach(ProviderPreset.all) { Text($0.name).tag($0.id) }
                }
                TextField("Base URL", text: $model.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                TextField("Model", text: $model.modelID)
                    .textFieldStyle(.roundedBorder)
                if model.showsEffort {
                    Picker("Effort", selection: $model.effort) {
                        ForEach(SettingsStore.effortLevels, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                HStack {
                    Text("Max tokens")
                    Spacer()
                    TextField("", value: $model.maxTokens, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Toggle("Stream responses", isOn: $model.streaming)
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                if let warning = model.launchAtLoginWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("Model").font(.headline)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Prompts

    private var prompts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Slot", selection: $model.selectedSlot) {
                ForEach(PromptSlot.all) { slot in
                    Text(slot.title.replacingOccurrences(of: "Ask AI: ", with: ""))
                        .tag(slot.id)
                }
            }
            .pickerStyle(.segmented)

            Text("Menu title “\(model.selectedSlotTitle)” is fixed in the app bundle. "
                 + "Only the prompt below is editable.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $model.currentTemplate)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3))
                )

            HStack {
                Text("Use \(PromptTemplate.placeholder) where the selected text should go. "
                     + "If it is missing, the selection is appended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore default") { model.restoreCurrentTemplate() }
                    .controlSize(.small)
            }
        }
        .padding(16)
    }
}
