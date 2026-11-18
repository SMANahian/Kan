import SwiftUI
import KanAI
import KanCore

// MARK: - OpenAI

/// Settings › OpenAI: the API key (kept in the login keychain, shown only as "sk-…" and its last 4
/// characters), the two features, the model and language they write with, and what is sent and
/// billed. Both features are off, and disabled until a key is saved.
struct OpenAISettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var keyDraft = ""
    @State private var keyMessage: String?
    @State private var savingKey = false
    @State private var replacingKey = false
    @State private var confirmingRemove = false
    /// "Other…" is chosen in the model picker (the model id is typed).
    @State private var customModel = false
    /// The Model ID field as typed; it becomes the setting only while it can be a model id.
    @State private var modelIDDraft = ""

    private static let keysPage = URL(string: "https://platform.openai.com/api-keys")
    private static let otherModelTag = "other"

    var body: some View {
        @Bindable var model = model
        let keySaved = model.apiKeyState.isSaved
        Form {
            Section("API key") {
                switch model.apiKeyState {
                case .loading:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading the keychain…").foregroundStyle(.secondary)
                    }
                case .missing:
                    keyEntry
                case .saved(let hint):
                    if replacingKey { keyEntry } else { savedKey(hint) }
                }
                SettingsFootnote("Kan keeps the key in your login keychain (as “Kan — OpenAI API key”), never in its settings file, and sends it only to OpenAI.")
            }
            Section("After each call") {
                Toggle("Suggest titles when a transcript is ready", isOn: Binding(
                    get: { keySaved && model.settings.aiSuggestTitles },
                    set: { model.settings.aiSuggestTitles = $0 }))
                    .disabled(!keySaved)
                SettingsFootnote("Three ideas appear under the title in the label panel and in the library. While the call still has its automatic title (“Zoom call”), Kan uses the first one; a title you typed is never replaced.")
                Toggle("Summarize each call after you label it", isOn: Binding(
                    get: { keySaved && model.settings.aiSummarize },
                    set: { model.settings.aiSummarize = $0 }))
                    .disabled(!keySaved)
                SettingsFootnote("Key points, ideas, decisions, action items and open questions, written once you save or close the label panel so the speaker names you gave are used. It appears above the transcript and in the call's Markdown.")
                if !keySaved {
                    SettingsFootnote("Save an API key to turn these on. With a key, the library can also summarize any call or suggest titles when you ask.")
                }
            }
            Section("Model") {
                Picker("Model", selection: modelSelection) {
                    ForEach(OpenAIModels.known) { option in
                        Text(option.name).tag(option.id)
                    }
                    Divider()
                    Text("Other…").tag(Self.otherModelTag)
                }
                if customModel {
                    HStack {
                        Text("Model ID")
                        TextField("Model ID", text: Binding(get: { modelIDDraft }, set: { text in
                            modelIDDraft = text
                            model.setCustomModelID(text)
                        }), prompt: Text(KanSettings.defaultAIModel))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity)
                        if !testedTextModels.isEmpty {
                            Menu("This Key's Models") {
                                ForEach(testedTextModels, id: \.self) { id in
                                    Button(id) {
                                        modelIDDraft = id
                                        model.setCustomModelID(id)
                                    }
                                }
                            }
                            .fixedSize()
                        }
                    }
                    if let problem = AppModel.modelIDProblem(modelIDDraft) {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    SettingsFootnote("Any OpenAI model that supports the Responses API and structured outputs. Empty uses \(OpenAIModels.option(for: KanSettings.defaultAIModel)?.name ?? KanSettings.defaultAIModel). Test the key to see which models it can use.")
                } else if let option = OpenAIModels.option(for: model.settings.effectiveAIModel) {
                    SettingsFootnote(option.detail + ".")
                }
                Picker("Write titles and summaries in", selection: $model.settings.aiLanguage) {
                    ForEach(AIOutputLanguage.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                SettingsFootnote("“Same as the call” follows the language most of the call was in. Names and technical terms are kept as they were said.")
            }
            Section("What is sent") {
                SettingsFootnote("The transcript — who said what, with times — and the call's title, date, duration, app, participants, tags, your notes and bookmarks. Never the audio. Kan asks OpenAI not to store requests (store: false); OpenAI's API data policies apply.")
                SettingsFootnote("Tell the people on your calls that the transcript goes to OpenAI too, and get their OK.")
                SettingsFootnote("OpenAI bills your API account. With GPT-6.1 Terra, an hour-long call costs a few cents; GPT-6 Luna about a tenth of that.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            customModel = OpenAIModels.option(for: model.settings.effectiveAIModel) == nil
            modelIDDraft = model.settings.aiModel
        }
    }

    // MARK: The key

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("API key", text: $keyDraft, prompt: Text("Paste your key (sk-…)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .onSubmit(saveKey)
                    .disabled(savingKey)
                Button(savingKey ? "Saving…" : "Save", action: saveKey)
                    .disabled(savingKey || keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if replacingKey {
                    Button("Cancel") {
                        replacingKey = false
                        keyDraft = ""
                        keyMessage = nil
                    }
                }
            }
            if let keyMessage {
                Label(keyMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let page = Self.keysPage {
                HStack(spacing: 4) {
                    Text("Create one at").foregroundStyle(.secondary)
                    Link("platform.openai.com/api-keys", destination: page)
                }
                .font(.caption)
            }
        }
    }

    private func savedKey(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Saved key") {
                Text(hint)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(model.apiKeyCheck == .checking ? "Testing…" : "Test") {
                    Task { await model.testAPIKey() }
                }
                .disabled(model.apiKeyCheck == .checking)
                .help("Asks OpenAI which models this key can use (sends only the key)")
                Button("Replace…") {
                    keyDraft = ""
                    keyMessage = nil
                    replacingKey = true
                }
                Spacer()
                Button("Remove…", role: .destructive) { confirmingRemove = true }
                    .confirmationDialog("Remove the OpenAI API key?", isPresented: $confirmingRemove) {
                        Button("Remove Key", role: .destructive, action: removeKey)
                    } message: {
                        Text("Kan deletes it from your keychain, stops any request in progress and turns both features off. Title ideas and summaries already written stay.")
                    }
            }
            checkResult
            if let keyMessage {
                Label(keyMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var checkResult: some View {
        switch model.apiKeyCheck {
        case .checking?:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Asking OpenAI…").foregroundStyle(.secondary)
            }
            .font(.callout)
        case .passed?:
            let chosen = model.settings.effectiveAIModel
            if model.keyCanUseChosenModel == true {
                Label("The key works and can use \(OpenAIModels.option(for: chosen)?.name ?? chosen).",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                Label("The key works, but it can't use “\(chosen)”. Choose another model below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let error)?:
            Label(error.message, systemImage: "xmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            EmptyView()
        }
    }

    /// The models a passed Test found that can write text.
    private var testedTextModels: [String] {
        guard case .passed(let models)? = model.apiKeyCheck else { return [] }
        return models.filter(OpenAIModels.isLikelyTextModel)
    }

    private func saveKey() {
        let key = keyDraft
        guard !savingKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        savingKey = true
        keyMessage = nil
        Task {
            let problem = await model.saveAPIKey(key)
            savingKey = false
            keyMessage = problem
            if problem == nil {
                // Nothing of the key stays in the view.
                keyDraft = ""
                replacingKey = false
            }
        }
    }

    private func removeKey() {
        keyMessage = nil
        Task {
            keyMessage = await model.removeAPIKey()
            replacingKey = false
            keyDraft = ""
        }
    }

    // MARK: The model

    /// A known model by name, or "Other…" with its id typed below.
    private var modelSelection: Binding<String> {
        Binding(
            get: {
                if customModel { return Self.otherModelTag }
                return OpenAIModels.option(for: model.settings.effectiveAIModel)?.id ?? Self.otherModelTag
            },
            set: { tag in
                if tag == Self.otherModelTag {
                    if !customModel { modelIDDraft = model.settings.aiModel }
                    customModel = true
                } else {
                    customModel = false
                    model.settings.aiModel = tag
                }
            })
    }
}
