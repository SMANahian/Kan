import AppKit
import SwiftUI
import KanAgent
import KanCore

// MARK: - AI Agents

/// How to reach the library from AI agents: the bundled `kan` CLI, MCP setup snippets (copied,
/// never written into an agent's config) and the "Copy for AI" prompt templates.
struct AgentsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var installResult: CommandLineInstallResult?
    @State private var installing = false
    @State private var selectedTemplate: String?

    var body: some View {
        @Bindable var model = model
        let path = model.commandLineToolURL.path
        Form {
            Section("The kan command") {
                LabeledContent("Path") {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button(installing ? "Installing…" : "Install kan Command") {
                        installing = true
                        Task {
                            installResult = await model.installCommandLineTool()
                            installing = false
                        }
                    }
                    .disabled(installing)
                    CopyButton(text: path, title: "Copy Path")
                }
                if let installResult { installMessage(installResult) }
                SettingsFootnote("Links \(CommandLineInstaller.linkURL.path) to the command inside Kan.app, so “kan search …” works in Terminal.")
            }
            Section("Connect an AI agent (MCP)") {
                // Same snippets as `kan mcp-config`, so the two never disagree.
                ForEach(MCPSetup.snippets(executable: path, libraryPath: nil), id: \.client) { snippet in
                    VStack(alignment: .leading, spacing: 4) {
                        SnippetView(title: snippet.client, text: snippet.text)
                        SettingsFootnote(snippet.instructions)
                    }
                }
                SettingsFootnote("Kan never edits these files itself. The MCP server reads the library on this Mac only.")
            }
            Section("Copy for AI — prompt templates") {
                TemplateEditor(templates: $model.settings.promptTemplates, selection: $selectedTemplate)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func installMessage(_ result: CommandLineInstallResult) -> some View {
        switch result {
        case .installed(let link, let onPath):
            if onPath == false {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Linked \(link.path)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    SettingsFootnote("\(link.deletingLastPathComponent().path) isn't on your PATH yet. Add this line to ~/.zshrc:")
                    SnippetView(title: nil, text: "export PATH=\"$HOME/.local/bin:$PATH\"")
                }
            } else {
                Label("Linked \(link.path) — run “kan --help” in Terminal", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

/// Monospaced, selectable text with a Copy button.
private struct SnippetView: View {
    let title: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                HStack {
                    Text(title).font(.callout)
                    Spacer()
                    CopyButton(text: text, title: "Copy")
                }
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct CopyButton: View {
    @Environment(AppModel.self) private var model
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            model.environment.copyToPasteboard(text)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        }
        .controlSize(.small)
    }
}

/// Edits `settings.promptTemplates` (name + body), with reset to the defaults.
private struct TemplateEditor: View {
    @Binding var templates: [PromptTemplate]
    @Binding var selection: String?
    @State private var confirmingReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                List(selection: $selection) {
                    ForEach(templates) { template in
                        Text(template.name.isEmpty ? "Untitled" : template.name).tag(template.id)
                    }
                }
                .frame(width: 170, height: 190)
                if let index = templates.firstIndex(where: { $0.id == selection }) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Name", text: $templates[index].name)
                            .textFieldStyle(.roundedBorder)
                        TextEditor(text: $templates[index].body)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 158)
                    }
                } else {
                    Text("Select a template to edit it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 190)
                }
            }
            HStack {
                Button {
                    let template = PromptTemplate(id: UUID().uuidString, name: "New template",
                                                  body: "Here is a transcript of my call “{{title}}”.\n\n{{transcript}}")
                    templates.append(template)
                    selection = template.id
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a template")
                Button {
                    templates.removeAll { $0.id == selection }
                    selection = templates.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil || templates.count <= 1)
                .help("Delete the selected template")
                Spacer()
                Button("Reset to Defaults…") { confirmingReset = true }
                    .confirmationDialog("Replace your templates with Kan's defaults?", isPresented: $confirmingReset) {
                        Button("Reset", role: .destructive) {
                            templates = PromptTemplate.defaults
                            selection = templates.first?.id
                        }
                    }
            }
            SettingsFootnote("Placeholders: {{title}} {{date}} {{duration}} {{me}} {{participants}} {{notes}} {{bookmarks}} {{tags}} {{app}} {{transcript}}")
        }
        .onAppear { if selection == nil { selection = templates.first?.id } }
    }
}

// MARK: - Permissions

struct PermissionsSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(PermissionKind.allCases, id: \.self) { kind in
                    PermissionSettingsRow(kind: kind)
                }
            }
            Section("After changing System Audio Recording") {
                HStack {
                    SettingsFootnote("macOS applies a change to System Audio Recording only after Kan restarts.")
                    Spacer()
                    Button("Relaunch Kan") { model.environment.relaunch() }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshPermissions() }
    }
}

struct PermissionSettingsRow: View {
    @Environment(AppModel.self) private var model
    let kind: PermissionKind
    @State private var requesting = false

    var body: some View {
        let status = model.permissionStatuses[kind] ?? .unknown
        let needsRelaunch = model.needsRelaunch(kind)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: Self.symbol(kind)).frame(width: 20)
                Text(kind.displayName)
                Text(kind.isRequired ? "Required" : "Optional")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                PermissionStatusBadge(status: status, needsRelaunch: needsRelaunch)
            }
            SettingsFootnote(Self.explanation(kind))
            HStack {
                if kind == .calendar {
                    Toggle("Use my calendar for titles and attendees", isOn: Binding(
                        get: { model.settings.useCalendar },
                        set: { enabled in
                            model.settings.useCalendar = enabled
                            if enabled && status == .notDetermined { request() }
                        }))
                        .toggleStyle(.checkbox)
                }
                Spacer()
                if needsRelaunch {
                    Button("Relaunch Kan") { model.perform(.relaunch) }
                        .buttonStyle(.borderedProminent)
                } else if status == .notDetermined || status == .unknown {
                    Button(requesting ? "Asking…" : "Request", action: request)
                        .disabled(requesting)
                }
                Button("Open System Settings") { model.openPermissionSettings(kind) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func request() {
        requesting = true
        Task {
            await model.requestPermission(kind)
            requesting = false
        }
    }

    static func symbol(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: return "mic"
        case .systemAudio: return "speaker.wave.2"
        case .accessibility: return "accessibility"
        case .automation: return "gearshape.2"
        case .calendar: return "calendar"
        }
    }

    static func explanation(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone:
            return "Records your side of the call."
        case .systemAudio:
            return "Records the other side — the call app's sound. macOS shows a purple indicator in the menu bar while Kan records it. After allowing it in System Settings, relaunch Kan."
        case .accessibility:
            return "Reads browser window titles (Zen, Firefox, Chrome, Safari…) to recognize and name Google Meet, Teams and Zoom calls on the web. Not needed for detection."
        case .automation:
            return "Asks Chrome-family browsers and Safari for the meeting tab's address. Not needed for detection."
        case .calendar:
            return "Titles a call after the calendar event you're in and lists its attendees. Read on this Mac only."
        }
    }
}

struct PermissionStatusBadge: View {
    let status: PermissionStatus
    /// Granted, but it reaches Kan only after a relaunch (`AppModel.needsRelaunch`).
    var needsRelaunch = false

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(color)
    }

    private var pendingRelaunch: Bool { needsRelaunch && status == .granted }

    private var text: String {
        if pendingRelaunch { return "Allowed — relaunch Kan to apply" }
        switch status {
        case .granted: return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not asked yet"
        case .unknown: return "Unknown"
        }
    }

    private var symbol: String {
        if pendingRelaunch { return "arrow.clockwise.circle.fill" }
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "xmark.octagon.fill"
        case .notDetermined: return "questionmark.circle"
        case .unknown: return "circle.dashed"
        }
    }

    private var color: Color {
        if pendingRelaunch { return .orange }
        switch status {
        case .granted: return .green
        case .denied: return .red
        case .notDetermined, .unknown: return .secondary
        }
    }
}
