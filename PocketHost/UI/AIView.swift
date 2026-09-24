import SwiftUI

struct AIView: View {
    @EnvironmentObject private var model: AppModel

    let projectID: String?
    let filePath: String?
    let showSettingsOnly: Bool

    @State private var apiKey = ""
    @State private var providerID = "nanogpt"
    @State private var customName = "Custom Provider"
    @State private var customBaseURL = ""
    @State private var models: [AIModel] = []
    @State private var selectedModel = ""
    @State private var prompt = ""
    @State private var messages: [NexoraChatMessage] = []
    @State private var status = ""
    @State private var busy = false
    @State private var showModels = false
    @State private var proposal: NexoraAIProposal?
    @State private var mode: NexoraAIMode = .ask
    @FocusState private var composerFocused: Bool

    init(projectID: String? = nil, filePath: String? = nil, showSettingsOnly: Bool = false) {
        self.projectID = projectID
        self.filePath = filePath
        self.showSettingsOnly = showSettingsOnly
    }

    var body: some View {
        NavigationStack {
            Group {
                if showSettingsOnly {
                    settings
                } else if !model.ai.hasAPIKey {
                    noProvider
                } else {
                    chat
                }
            }
            .navigationTitle(showSettingsOnly ? "AI Provider" : "AI")
            .sheet(isPresented: $showModels) {
                NavigationStack {
                    NexoraModelSearchSheet(
                        models: models,
                        selectedModel: $selectedModel,
                        onSelect: { value in
                            _ = try? model.ai.update(.init(apiKey: nil, selectedModel: value, baseURL: nil))
                        }
                    )
                }
            }
            .sheet(item: $proposal) { proposal in
                NexoraProposalView(proposal: proposal) {
                    apply(proposal)
                }
            }
            .task {
                providerID = model.ai.selectedProviderID
                customName = model.ai.selectedProvider.name
                customBaseURL = model.ai.baseURL
                selectedModel = model.ai.selectedModel ?? ""
                restoreMessages()
                if model.ai.hasAPIKey {
                    await loadModels()
                }
            }
        }
    }

    private var settings: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerID) {
                    ForEach(model.ai.providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
                .onChange(of: providerID) { value in
                    do {
                        try model.ai.selectProvider(value)
                        selectedModel = model.ai.selectedModel ?? ""
                        apiKey = ""
                        if value == "custom" {
                            customName = model.ai.selectedProvider.name
                            customBaseURL = model.ai.baseURL
                        }
                        status = "Selected \(model.ai.selectedProvider.name)"
                    } catch { status = error.localizedDescription }
                }

                if providerID == "custom" {
                    TextField("Provider Name", text: $customName)
                    TextField("https://api.example.com/v1", text: $customBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } else {
                    Text(model.ai.baseURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Section("API Key") {
                SecureField(model.ai.maskedAPIKey ?? "API key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Button("Save Provider") {
                    do {
                        _ = try model.ai.update(.init(
                            apiKey: apiKey.isEmpty ? nil : apiKey,
                            selectedModel: nil,
                            baseURL: providerID == "custom" ? customBaseURL : nil,
                            providerID: providerID,
                            providerName: providerID == "custom" ? customName : nil
                        ))
                        apiKey = ""
                        status = "Saved securely in Keychain"
                        Task { await loadModels() }
                    } catch { status = error.localizedDescription }
                }

                Button("Test Connection") {
                    Task {
                        do { _ = try await model.ai.testConnection(); status = "Connection successful" }
                        catch { status = error.localizedDescription }
                    }
                }
                .disabled(!model.ai.hasAPIKey)
            }

            if model.ai.hasAPIKey {
                Section("Model") {
                    Button("Choose Model") { showModels = true }
                    if !selectedModel.isEmpty {
                        Text(selectedModel)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !status.isEmpty {
                Section("Status") {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            providerID = model.ai.selectedProviderID
            customName = model.ai.selectedProvider.name
            customBaseURL = model.ai.baseURL
        }
    }

    private var noProvider: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "sparkles")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)

                Text("AI is optional")
                    .font(.title2.bold())

                Text("Connect a provider only if you want AI coding features. Projects, files, runtimes, console and SQLite do not require AI.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                NavigationLink {
                    AIView(showSettingsOnly: true)
                } label: {
                    Text("Connect AI Provider")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private var chat: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty {
                    quickActions
                }

                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.role == "user" ? "You" : "Nexora")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        Text(message.content)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }

                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onTapGesture { composerFocused = false }
        .safeAreaInset(edge: .bottom) {
            composer
                .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showModels = true
                } label: {
                    Label(selectedModel.isEmpty ? "Model" : shortModel(selectedModel), systemImage: "cpu")
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(projectID == nil ? "Choose a project-aware action" : "Quick Actions")
                .font(.headline)

            if let projectID, let project = model.projects.get(projectID) {
                Button {
                    mode = .ask
                    prompt = "Explain how this project works and point out the important files."
                    Task { await send() }
                } label: {
                    quickCard("Explain Project", "Explain \(project.name)", "doc.text.magnifyingglass")
                }
                .buttonStyle(.plain)

                Button {
                    mode = .review
                    prompt = "Review the current project entry point for bugs and maintainability issues."
                    Task { await send() }
                } label: {
                    quickCard("Review Code", "Review the active project file.", "checkmark.seal")
                }
                .buttonStyle(.plain)

                Button {
                    mode = .edit
                    prompt = ""
                    composerFocused = true
                } label: {
                    quickCard("Build Feature", "Describe what you want to add.", "hammer")
                }
                .buttonStyle(.plain)
            } else {
                Text("Open AI from inside a project for project-aware coding, file context and reviewable edits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(model.projects.list().prefix(5)) { project in
                    NavigationLink {
                        AIView(projectID: project.id, filePath: project.entrypoint)
                    } label: {
                        quickCard(project.name, project.runtime.rawValue, "folder")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func quickCard(_ title: String, _ subtitle: String, _ symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(NexoraAIMode.allCases) { item in
                        Button(item.rawValue) { mode = item }
                    }
                } label: {
                    Label(mode.rawValue, systemImage: mode.symbol)
                        .font(.caption.bold())
                }
                Spacer()
                if let projectID, let project = model.projects.get(projectID) {
                    Text(filePath ?? project.entrypoint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask Nexora anything…", text: $prompt, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .submitLabel(.send)
                .onSubmit {
                    if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Task { await send() }
                    }
                }

            Button {
                Task { await send() }
            } label: {
                Image(systemName: busy ? "hourglass" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(
                busy
                || selectedModel.isEmpty
                || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            }
        }
        .padding()
    }

    private func send() async {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !selectedModel.isEmpty else { return }

        prompt = ""
        composerFocused = false
        messages.append(.init(role: "user", content: text))
        persistMessages()

        busy = true
        defer { busy = false }

        do {
            var system = """
            You are Nexora Host's coding assistant.
            Files on disk are the source of truth.
            Never claim a command or test ran unless the app actually ran it.
            Never request or expose secrets, API keys or .env values.
            Mode: \(mode.rawValue)
            """

            var activePath = filePath
            var oldContent = ""

            if let projectID, let project = model.projects.get(projectID) {
                system += "\nProject: \(project.name)\nRuntime: \(project.runtime.rawValue)\nEntry point: \(project.entrypoint)"
                activePath = activePath ?? project.entrypoint

                if let activePath,
                   !activePath.lowercased().hasSuffix(".env"),
                   let file = try? model.projects.readFile(projectID: projectID, path: activePath),
                   file.encoding == "utf8" {
                    oldContent = file.content
                    system += """
                    \nActive file: \(activePath)
                    --- FILE START ---
                    \(oldContent)
                    --- FILE END ---
                    If you propose replacing this file, return the COMPLETE replacement inside:
                    <nexora-file path="\(activePath)">
                    ...complete content...
                    </nexora-file>
                    """
                }
            }

            switch mode {
            case .ask:
                system += "\nAnswer without modifying files unless the user explicitly asks."
            case .edit:
                system += "\nPropose a focused edit to the active file when appropriate."
            case .agent:
                system += "\nAct as a bounded coding agent: inspect the supplied context, propose the smallest useful file change, and state what should be run to verify it. Do not claim verification happened until Nexora runs it."
            case .debug:
                system += "\nDiagnose the current code/runtime problem and propose a concrete fix to the active file when possible."
            case .review:
                system += "\nReview for correctness, security and maintainability. Do not rewrite unless needed for a concrete fix."
            }

            let history = messages.suffix(14).map {
                AIChatMessage(role: $0.role, content: $0.content)
            }
            let response = try await model.ai.chat(
                .init(
                    model: selectedModel,
                    messages: [AIChatMessage(role: "system", content: system)] + history,
                    temperature: 0.2
                )
            )

            let content = response.message.content
            messages.append(.init(role: "assistant", content: stripFileBlock(content)))
            persistMessages()
            status = response.model

            if let projectID,
               let activePath,
               let newContent = extractFileBlock(content, path: activePath),
               newContent != oldContent {
                proposal = .init(
                    projectID: projectID,
                    path: activePath,
                    oldContent: oldContent,
                    newContent: newContent
                )
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func loadModels() async {
        do {
            models = try await model.ai.listModels()
            if selectedModel.isEmpty, let first = models.first?.id {
                selectedModel = first
                _ = try? model.ai.update(.init(apiKey: nil, selectedModel: first, baseURL: nil))
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func apply(_ proposal: NexoraAIProposal) {
        do {
            _ = try model.backups.create(projectID: proposal.projectID, label: "AI checkpoint")
            _ = try model.projects.writeFile(
                projectID: proposal.projectID,
                path: proposal.path,
                request: .init(content: proposal.newContent, encoding: "utf8")
            )
            model.history.append(projectID: proposal.projectID, kind: .aiEdit, title: "AI edit applied", detail: proposal.path)
            if mode == .agent || mode == .debug {
                let result = model.runProject(proposal.projectID)
                status = result.succeeded ? "Applied and verified by local run: \(result.output)" : "Applied; local verification failed: \(result.output)"
            } else {
                status = "Applied change to \(proposal.path)"
            }
            self.proposal = nil
        } catch {
            status = "Could not apply change: \(error)"
        }
    }

    private func extractFileBlock(_ content: String, path: String) -> String? {
        let startMarker = "<nexora-file path=\"\(path)\">"
        guard
            let start = content.range(of: startMarker),
            let end = content.range(of: "</nexora-file>", range: start.upperBound..<content.endIndex)
        else { return nil }

        var value = String(content[start.upperBound..<end.lowerBound])
        if value.hasPrefix("\n") { value.removeFirst() }
        if value.hasSuffix("\n") { value.removeLast() }
        return value
    }

    private func stripFileBlock(_ content: String) -> String {
        guard
            let start = content.range(of: "<nexora-file "),
            let end = content.range(of: "</nexora-file>", range: start.lowerBound..<content.endIndex)
        else { return content }

        var copy = content
        copy.replaceSubrange(start.lowerBound..<end.upperBound, with: "[Proposed file edit attached]")
        return copy
    }

    private func shortModel(_ value: String) -> String {
        value.count > 18 ? String(value.prefix(16)) + "…" : value
    }

    private func storageKey() -> String {
        "nexora.ai.messages." + (projectID ?? "global")
    }

    private func persistMessages() {
        if let data = try? JSONEncoder().encode(Array(messages.suffix(80))) {
            UserDefaults.standard.set(data, forKey: storageKey())
        }
    }

    private func restoreMessages() {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey()),
            let restored = try? JSONDecoder().decode([NexoraChatMessage].self, from: data)
        else { return }
        messages = restored
    }
}

private enum NexoraAIMode: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case edit = "Edit"
    case agent = "Agent"
    case debug = "Debug"
    case review = "Review"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .ask: return "questionmark.bubble"
        case .edit: return "pencil"
        case .agent: return "wand.and.stars"
        case .debug: return "ladybug"
        case .review: return "checkmark.seal"
        }
    }
}

private struct NexoraChatMessage: Identifiable, Codable {
    let id: UUID
    let role: String
    let content: String

    init(id: UUID = UUID(), role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

private struct NexoraAIProposal: Identifiable {
    let id = UUID()
    let projectID: String
    let path: String
    let oldContent: String
    let newContent: String
}

private struct NexoraProposalView: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: NexoraAIProposal
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(NexoraSimpleDiff.make(old: proposal.oldContent, new: proposal.newContent))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .navigationTitle("Review Change")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        apply()
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct NexoraModelSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [AIModel]
    @Binding var selectedModel: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var favorites: Set<String> = []

    var body: some View {
        List(filtered) { model in
            HStack {
                Button {
                    toggle(model.id)
                } label: {
                    Image(systemName: favorites.contains(model.id) ? "star.fill" : "star")
                }
                .buttonStyle(.plain)

                Button {
                    selectedModel = model.id
                    onSelect(model.id)
                    dismiss()
                } label: {
                    HStack {
                        Text(model.id)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selectedModel == model.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .onAppear {
            favorites = Set(UserDefaults.standard.stringArray(forKey: "ai.favoriteModels") ?? [])
        }
    }

    private var filtered: [AIModel] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(clean)
            || ($0.ownedBy?.localizedCaseInsensitiveContains(clean) ?? false)
        }
    }

    private func toggle(_ id: String) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: "ai.favoriteModels")
    }
}

private enum NexoraSimpleDiff {
    static func make(old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        let count = max(oldLines.count, newLines.count)
        var output: [String] = []

        for index in 0..<count {
            let before = index < oldLines.count ? oldLines[index] : nil
            let after = index < newLines.count ? newLines[index] : nil

            if before == after, let before {
                output.append("  " + before)
            } else {
                if let before { output.append("- " + before) }
                if let after { output.append("+ " + after) }
            }
        }

        return output.joined(separator: "\n")
    }
}
