import SwiftUI

struct AIView: View {
    @EnvironmentObject private var model: AppModel

    let projectID: String?
    let filePath: String?
    let showSettingsOnly: Bool

    @State private var apiKey = ""
    @State private var providerID = "freepool"
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
                        // A stored NanoGPT key has explicit priority. Reflect the service's
                        // actual effective provider immediately so the UI never says Free AI
                        // while requests are really going to NanoGPT.
                        providerID = model.ai.selectedProviderID
                        selectedModel = model.ai.selectedModel ?? ""
                        apiKey = ""
                        if providerID == "custom" {
                            customName = model.ai.selectedProvider.name
                            customBaseURL = model.ai.baseURL
                        }
                        status = model.ai.nanoGPTConfigured && providerID == "nanogpt"
                            ? "NanoGPT key detected · NanoGPT has priority with Free AI fallback"
                            : "Selected \(model.ai.selectedProvider.name)"
                        Task { await loadModels() }
                    } catch { status = error.localizedDescription }
                }

                if providerID == "freepool" {
                    Text("Free AI Pool works without your own API key and automatically falls back between keyless providers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("If a NanoGPT key is saved, Nexora prefers NanoGPT automatically. You can still select another configured provider manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if providerID == "custom" {
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

            if providerID == "freepool" {
                Section("Free AI") {
                    Button("Refresh Free Models") { Task { await loadModels() } }
                    Button("Test Free Pool") {
                        Task {
                            do {
                                _ = try await model.ai.testConnection()
                                status = "Free AI pool is reachable"
                            } catch {
                                status = error.localizedDescription
                            }
                        }
                    }
                    Text("No personal API key required. Free providers can have rate limits or temporary outages.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
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
                            providerID = model.ai.selectedProviderID
                            status = providerID == "nanogpt" ? "NanoGPT saved and selected" : "Saved securely in Keychain"
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

                Text("Free AI works without your own API key. Adding NanoGPT or another provider key is optional and can give you more models.")
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
            Never request or expose secrets, API keys, tokens, .env files, credentials, or files under .nexora.
            Mode: \(mode.rawValue)
            """

            if let projectID, let project = model.projects.get(projectID) {
                system += "\nProject: \(project.name)\nRuntime: \(project.runtime.rawValue)\nEntry point: \(project.entrypoint)"

                if let paths = try? model.projects.allFilePaths(projectID: projectID, limit: 300), !paths.isEmpty {
                    system += "\nProject files:\n" + paths.joined(separator: "\n")
                }

                let activePath = filePath ?? project.entrypoint
                if !isSecretPath(activePath),
                   let file = try? model.projects.readFile(projectID: projectID, path: activePath),
                   file.encoding == "utf8" {
                    system += """
                    \nActive file: \(activePath)
                    --- FILE START ---
                    \(file.content)
                    --- FILE END ---
                    """
                }

                system += """
                \nWhen the user asks you to edit OR create files, return every changed/new file as a COMPLETE file block:
                <nexora-file path="relative/path.ext">
                complete file content
                </nexora-file>
                You may return multiple nexora-file blocks. Paths must be relative to the project workspace. Do not write secret files.
                """
            }

            switch mode {
            case .ask:
                system += "\nAnswer without modifying files unless the user explicitly asks."
            case .edit:
                system += "\nMake focused project edits. You may create new files when the request needs them."
            case .agent:
                system += "\nAct as a bounded coding agent: inspect the supplied context, propose all necessary file changes, and state what should be run to verify them. Do not claim verification happened until Nexora runs it."
            case .debug:
                system += "\nDiagnose the current code/runtime problem and propose concrete file fixes when possible."
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
            let blocks = extractFileBlocks(content)
            messages.append(.init(role: "assistant", content: stripFileBlocks(content, count: blocks.count)))
            persistMessages()
            status = response.model

            if let projectID, !blocks.isEmpty {
                var changes: [NexoraAIFileChange] = []
                for block in blocks {
                    guard !isSecretPath(block.path) else { continue }
                    let old: String?
                    if let current = try? model.projects.readFile(projectID: projectID, path: block.path), current.encoding == "utf8" {
                        old = current.content
                    } else {
                        old = nil
                    }
                    if old != block.content {
                        changes.append(.init(path: block.path, oldContent: old, newContent: block.content))
                    }
                }
                if !changes.isEmpty {
                    proposal = .init(projectID: projectID, changes: changes)
                    status = "\(changes.count) file change\(changes.count == 1 ? "" : "s") ready to review"
                }
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func loadModels() async {
        do {
            models = try await model.ai.listModels()
            if !models.contains(where: { $0.id == selectedModel }) {
                selectedModel = model.ai.selectedModel.flatMap { saved in
                    models.contains(where: { $0.id == saved }) ? saved : nil
                } ?? models.first?.id ?? ""
            }
            if !selectedModel.isEmpty {
                _ = try? model.ai.update(.init(apiKey: nil, selectedModel: selectedModel, baseURL: nil))
            }
        } catch {
            models = []
            status = error.localizedDescription
        }
    }

    private func apply(_ proposal: NexoraAIProposal) {
        do {
            _ = try model.backups.create(projectID: proposal.projectID, label: "AI checkpoint")
            try model.projects.applyTextFilesAtomically(
                projectID: proposal.projectID,
                changes: proposal.changes.map { .init(path: $0.path, content: $0.newContent) }
            )
            model.history.append(
                projectID: proposal.projectID,
                kind: .aiEdit,
                title: "AI changes applied",
                detail: proposal.changes.map(\.path).joined(separator: ", ")
            )
            model.refreshLocalState()
            if mode == .agent || mode == .debug {
                let result = model.runProject(proposal.projectID)
                status = result.succeeded
                    ? "Applied \(proposal.changes.count) file change(s) and local run started: \(result.output)"
                    : "Applied \(proposal.changes.count) file change(s); local verification failed: \(result.output)"
            } else {
                status = "Applied \(proposal.changes.count) file change(s)"
            }
            self.proposal = nil
        } catch {
            status = "Could not apply change: \(error.localizedDescription)"
        }
    }

    private func extractFileBlocks(_ content: String) -> [(path: String, content: String)] {
        let pattern = "<nexora-file\\s+path=\"([^\"]+)\">(.*?)</nexora-file>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        var output: [(String, String)] = []
        for match in regex.matches(in: content, range: range) {
            guard match.numberOfRanges == 3,
                  let pathRange = Range(match.range(at: 1), in: content),
                  let bodyRange = Range(match.range(at: 2), in: content) else { continue }
            let path = String(content[pathRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            var body = String(content[bodyRange])
            if body.hasPrefix("\n") { body.removeFirst() }
            if body.hasSuffix("\n") { body.removeLast() }
            if !path.isEmpty { output.append((path, body)) }
        }
        return output
    }

    private func stripFileBlocks(_ content: String, count: Int) -> String {
        guard count > 0 else { return content }
        let pattern = "<nexora-file\\s+path=\"([^\"]+)\">(.*?)</nexora-file>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return content }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        return regex.stringByReplacingMatches(
            in: content,
            range: range,
            withTemplate: "[Proposed file change attached]"
        )
    }

    private func isSecretPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return lower.hasPrefix(".nexora/")
            || name == ".env"
            || name.hasPrefix(".env.")
            || lower.contains("secret")
            || lower.contains("credential")
            || lower.contains("token.json")
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

private struct NexoraAIFileChange: Identifiable {
    var id: String { path }
    let path: String
    let oldContent: String?
    let newContent: String
}

private struct NexoraAIProposal: Identifiable {
    let id = UUID()
    let projectID: String
    let changes: [NexoraAIFileChange]
}

private struct NexoraProposalView: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: NexoraAIProposal
    let apply: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(proposal.changes) { change in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(change.path)
                                    .font(.headline.monospaced())
                                Spacer()
                                Text(change.oldContent == nil ? "NEW" : "MODIFIED")
                                    .font(.caption2.bold())
                                    .foregroundStyle(change.oldContent == nil ? .green : .orange)
                            }
                            Text(NexoraSimpleDiff.make(old: change.oldContent ?? "", new: change.newContent))
                                .font(.caption.monospaced())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .navigationTitle("Review \(proposal.changes.count) Change\(proposal.changes.count == 1 ? "" : "s")")
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
