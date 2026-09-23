import SwiftUI

struct AIView: View {
    @EnvironmentObject private var model: AppModel
    var showSettingsOnly = false

    @State private var models: [AIModel] = []
    @State private var selectedModel = ""
    @State private var query = ""
    @State private var status = ""
    @State private var busy = false
    @State private var selectedProjectID = ""
    @State private var favorites: Set<String> = []

    var body: some View {
        NavigationStack {
            Group {
                if showSettingsOnly {
                    modelBrowser
                } else {
                    List {
                        Section("Coding model") {
                            NavigationLink {
                                modelBrowser
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(selectedModel.isEmpty ? "Choose model" : selectedModel)
                                            .lineLimit(2)
                                        Text("NanoGPT · searchable model list")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        Section("Open AI with project") {
                            if model.remoteProjects.isEmpty {
                                Text("No backend projects loaded. Refresh Projects first.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("Project", selection: $selectedProjectID) {
                                    Text("Select project").tag("")
                                    ForEach(model.remoteProjects) { project in
                                        Text(project.name).tag(project.id)
                                    }
                                }

                                if let project = model.remoteProjects.first(where: { $0.id == selectedProjectID }) {
                                    NavigationLink("Open coding assistant") {
                                        RemoteAICodingAssistantView(
                                            project: project,
                                            activeFilePath: nil,
                                            activeFileContent: "",
                                            onApplyFile: { _, _ in }
                                        )
                                    }
                                }
                            }
                        }

                        Section("How Nexora Host AI works") {
                            Label("Project files are the source of truth", systemImage: "doc.text.magnifyingglass")
                            Label("Edits are reviewable before apply", systemImage: "arrow.left.arrow.right")
                            Label("Secrets are excluded by default", systemImage: "lock.shield")
                            Label("Ask, Edit, Debug, Review and Research modes", systemImage: "slider.horizontal.3")
                            Text("Autonomous multi-step Agent Mode, checkpoints and test loops are kept for Phase 2 so Nexora Host does not pretend they are finished before the backend worker exists.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !status.isEmpty {
                            Section("Status") { Text(status).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle(showSettingsOnly ? "Models" : "AI")
            .task {
                selectedModel = model.ai.selectedModel ?? ""
                favorites = Set(UserDefaults.standard.stringArray(forKey: "ai.favoriteModels") ?? [])
                if model.remote.isConfigured && model.remoteProjects.isEmpty {
                    model.remoteProjects = (try? await model.remote.listProjects()) ?? []
                }
                if model.ai.hasAPIKey { await loadModels() }
            }
        }
    }

    private var modelBrowser: some View {
        List {
            Section("NanoGPT") {
                HStack {
                    TextField("Search models", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        Task { await loadModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                if busy { ProgressView() }
            }

            if !favoriteModels.isEmpty {
                Section("Favorites") {
                    ForEach(favoriteModels) { modelRow($0) }
                }
            }

            Section("Models") {
                if filteredModels.isEmpty {
                    Text(models.isEmpty ? "Load models after adding your NanoGPT key in Settings." : "No models match your search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredModels) { modelRow($0) }
            }

            if !status.isEmpty {
                Section("Status") { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .searchable(text: $query, prompt: "Search models")
    }

    private var filteredModels: [AIModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(q) || ($0.ownedBy?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var favoriteModels: [AIModel] {
        models.filter { favorites.contains($0.id) }
    }

    private func modelRow(_ item: AIModel) -> some View {
        HStack(spacing: 10) {
            Button {
                toggleFavorite(item.id)
            } label: {
                Image(systemName: favorites.contains(item.id) ? "star.fill" : "star")
                    .foregroundStyle(favorites.contains(item.id) ? .yellow : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                selectedModel = item.id
                _ = try? model.ai.update(.init(apiKey: nil, selectedModel: item.id, baseURL: nil))
                rememberRecent(item.id)
                status = "Selected \(item.id)"
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.id)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let owner = item.ownedBy, !owner.isEmpty {
                            Text(owner)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if selectedModel == item.id {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func loadModels() async {
        busy = true
        defer { busy = false }
        do {
            models = try await model.ai.listModels()
            if selectedModel.isEmpty, let first = models.first?.id {
                selectedModel = first
                _ = try? model.ai.update(.init(apiKey: nil, selectedModel: first, baseURL: nil))
            }
            status = "Loaded \(models.count) models"
        } catch {
            status = error.localizedDescription
        }
    }

    private func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: "ai.favoriteModels")
    }

    private func rememberRecent(_ id: String) {
        var recent = UserDefaults.standard.stringArray(forKey: "ai.recentModels") ?? []
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 12 { recent = Array(recent.prefix(12)) }
        UserDefaults.standard.set(recent, forKey: "ai.recentModels")
    }
}

enum NexoraAIMode: String, CaseIterable, Identifiable {
    case ask = "Ask"
    case edit = "Edit"
    case debug = "Debug"
    case review = "Review"
    case research = "Research"
    var id: String { rawValue }
}

struct AssistantMessage: Codable, Identifiable, Equatable {
    let id: String
    let role: String
    let content: String

    init(id: String = UUID().uuidString, role: String, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

struct AIPatchProposal: Identifiable, Equatable {
    let id = UUID()
    let path: String
    let oldContent: String
    let newContent: String
}

struct RemoteAICodingAssistantView: View {
    @EnvironmentObject private var model: AppModel

    let project: RemoteProject
    let activeFilePath: String?
    let activeFileContent: String
    let onApplyFile: (String, String) -> Void

    @State private var messages: [AssistantMessage] = []
    @State private var prompt = ""
    @State private var models: [AIModel] = []
    @State private var selectedModel = ""
    @State private var mode: NexoraAIMode = .ask
    @State private var status = ""
    @State private var busy = false
    @State private var showModels = false
    @State private var proposal: AIPatchProposal?
    @State private var includeLogs = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            assistantHeader
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        contextCard

                        if messages.isEmpty {
                            welcomeCard
                        }

                        ForEach(messages) { item in
                            messageBubble(item)
                                .id(item.id)
                        }

                        if let proposal {
                            proposalCard(proposal)
                        }

                        if !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            composer
                .background(.ultraThinMaterial)
        }
        .task {
            restoreMessages()
            selectedModel = model.ai.selectedModel ?? ""
            if model.ai.hasAPIKey { await loadModels() }
        }
        .sheet(isPresented: $showModels) {
            NavigationStack {
                AIModelSearchSheet(models: models, selectedModel: $selectedModel) {
                    Task { await loadModels() }
                }
            }
        }
        .onChange(of: selectedModel) { value in
            guard !value.isEmpty else { return }
            _ = try? model.ai.update(.init(apiKey: nil, selectedModel: value, baseURL: nil))
        }
    }

    private var assistantHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Coding")
                        .font(.headline)
                    Text(project.name + (activeFilePath.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showModels = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu")
                        Text(selectedModel.isEmpty ? "Model" : shortModelName(selectedModel))
                            .lineLimit(1)
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
            }

            Picker("Mode", selection: $mode) {
                ForEach(NexoraAIMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("AI Context", systemImage: "scope")
                    .font(.caption.bold())
                Spacer()
                Toggle("Logs", isOn: $includeLogs)
                    .labelsHidden()
            }
            Text("✓ Project: \(project.name)")
            Text("✓ Runtime: \(project.runtime)")
            if let activeFilePath { Text("✓ File: \(activeFilePath)") }
            Text("\(includeLogs ? "✓" : "✕") Latest logs")
            Text("✕ .env / secrets")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI works on the project, not beside it.")
                .font(.headline)
            Text("Ask questions, edit the active file, debug logs, review code or research an API. File changes are proposed first and require Apply.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private func messageBubble(_ item: AssistantMessage) -> some View {
        VStack(alignment: item.role == "user" ? .trailing : .leading, spacing: 4) {
            Text(item.role == "user" ? "You" : "AI")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(item.content)
                .textSelection(.enabled)
                .padding(10)
                .background(
                    item.role == "user" ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        }
        .frame(maxWidth: .infinity, alignment: item.role == "user" ? .trailing : .leading)
        .padding(.horizontal)
    }

    private func proposalCard(_ proposal: AIPatchProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.badge.gearshape")
                Text("Proposed edit")
                    .font(.headline)
                Spacer()
                Text(proposal.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ScrollView(.horizontal) {
                Text(SimpleDiff.make(old: proposal.oldContent, new: proposal.newContent))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 240)

            HStack {
                Button("Reject", role: .cancel) { self.proposal = nil }
                Spacer()
                Button("Apply") {
                    onApplyFile(proposal.path, proposal.newContent)
                    messages.append(.init(role: "assistant", content: "Applied \(proposal.path)."))
                    persistMessages()
                    self.proposal = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Ask Nexora Host…", text: $prompt, axis: .vertical)
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
                .disabled(busy || selectedModel.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            HStack {
                Text(mode.rawValue)
                    .font(.caption2.bold())
                if let path = activeFilePath {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if busy { ProgressView().scaleEffect(0.8) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 6)
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
            var context = activeFileContent
            var path = activeFilePath
            if context.isEmpty, let entry = project.entrypoint, !entry.isEmpty,
               let file = try? await model.remote.readFile(projectID: project.id, path: entry), file.encoding == "utf8" {
                context = file.content
                path = file.path
            }

            var logsText = ""
            if includeLogs, let logs = try? await model.remote.logs(projectID: project.id, limit: 80) {
                logsText = logs.map { "[\($0.level)] \($0.message)" }.joined(separator: "\n")
            }

            let system = systemPrompt(path: path, fileContent: context, logs: logsText)
            let chatMessages = [AIChatMessage(role: "system", content: system)] + messages.suffix(16).map { AIChatMessage(role: $0.role, content: $0.content) }
            let response = try await model.ai.chat(.init(model: selectedModel, messages: chatMessages, temperature: 0.2))
            let content = response.message.content
            messages.append(.init(role: "assistant", content: stripFileBlock(content)))
            persistMessages()
            status = response.model

            if let path, let edited = extractFileBlock(content: content, path: path), edited != context {
                proposal = .init(path: path, oldContent: context, newContent: edited)
            }
        } catch {
            status = error.localizedDescription
        }
    }

    private func systemPrompt(path: String?, fileContent: String, logs: String) -> String {
        var base = """
        You are Nexora Host's private coding assistant for one owner.
        Files on disk are the source of truth. Do not invent completed commands or tests.
        Project: \(project.name)
        Runtime: \(project.runtime)
        Framework: \(project.framework ?? "unknown")
        Branch: \(project.branch)
        Mode: \(mode.rawValue)
        Never request or reveal secrets such as .env values.
        """

        if let path, !fileContent.isEmpty {
            base += "\nActive file: \(path)\n--- FILE START ---\n\(fileContent)\n--- FILE END ---\n"
        }
        if !logs.isEmpty {
            base += "\nRecent logs:\n\(logs)\n"
        }

        switch mode {
        case .ask:
            base += "\nAnswer the question. Do not edit files unless the user explicitly asks."
        case .edit:
            base += editInstruction(path: path)
        case .debug:
            base += "\nDiagnose the error from the supplied code/logs. If a concrete edit to the active file fixes it, use the file block format below." + editInstruction(path: path)
        case .review:
            base += "\nReview for correctness, bugs, security and maintainability. Prefer precise findings. Do not rewrite unless requested."
        case .research:
            base += "\nResearch conceptually using the context you have. Distinguish known project facts from assumptions."
        }
        return base
    }

    private func editInstruction(path: String?) -> String {
        guard let path else { return "\nNo active file is available. Explain which file should be opened before editing." }
        return """

        If you want to replace the active file, return the COMPLETE new file inside exactly this wrapper:
        <nexora-file path="\(path)">
        ...complete file content...
        </nexora-file>
        Explain the change outside the block. Never include secrets.
        """
    }

    private func extractFileBlock(content: String, path: String) -> String? {
        let marker = "<nexora-file path=\"\(path)\">"
        guard let start = content.range(of: marker), let end = content.range(of: "</nexora-file>", range: start.upperBound..<content.endIndex) else { return nil }
        var result = String(content[start.upperBound..<end.lowerBound])
        if result.hasPrefix("\n") { result.removeFirst() }
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private func stripFileBlock(_ content: String) -> String {
        guard let start = content.range(of: "<nexora-file "), let end = content.range(of: "</nexora-file>", range: start.lowerBound..<content.endIndex) else { return content }
        var copy = content
        copy.replaceSubrange(start.lowerBound..<end.upperBound, with: "[Proposed file edit attached]")
        return copy
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

    private func shortModelName(_ value: String) -> String {
        value.count > 22 ? String(value.prefix(20)) + "…" : value
    }

    private func storageKey() -> String { "ai.project.messages.\(project.id)" }

    private func persistMessages() {
        if let data = try? JSONEncoder().encode(Array(messages.suffix(80))) {
            UserDefaults.standard.set(data, forKey: storageKey())
        }
    }

    private func restoreMessages() {
        guard let data = UserDefaults.standard.data(forKey: storageKey()), let restored = try? JSONDecoder().decode([AssistantMessage].self, from: data) else { return }
        messages = restored
    }
}

private struct AIModelSearchSheet: View {
    @Environment(\.dismiss) private var dismiss
    let models: [AIModel]
    @Binding var selectedModel: String
    let onReload: () -> Void

    @State private var query = ""
    @State private var favorites: Set<String> = []
    @State private var favoritesOnly = false

    var body: some View {
        List {
            if visibleModels.isEmpty {
                Text("No models match your search.")
                    .foregroundStyle(.secondary)
            }
            ForEach(visibleModels) { item in
                HStack(spacing: 10) {
                    Button {
                        toggleFavorite(item.id)
                    } label: {
                        Image(systemName: favorites.contains(item.id) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(item.id) ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        selectedModel = item.id
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.id).foregroundStyle(.primary).lineLimit(2)
                                if let owner = item.ownedBy { Text(owner).font(.caption2).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            if selectedModel == item.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $query, prompt: "Search models")
        .navigationTitle("Models")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(favoritesOnly ? "All" : "Favorites") { favoritesOnly.toggle() }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { onReload() } label: { Image(systemName: "arrow.clockwise") }
                Button("Done") { dismiss() }
            }
        }
        .onAppear { favorites = Set(UserDefaults.standard.stringArray(forKey: "ai.favoriteModels") ?? []) }
    }

    private var visibleModels: [AIModel] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { item in
            (!favoritesOnly || favorites.contains(item.id)) &&
            (q.isEmpty || item.id.localizedCaseInsensitiveContains(q) || (item.ownedBy?.localizedCaseInsensitiveContains(q) ?? false))
        }
    }

    private func toggleFavorite(_ id: String) {
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites).sorted(), forKey: "ai.favoriteModels")
    }
}

enum SimpleDiff {
    static func make(old: String, new: String) -> String {
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        let maxCount = max(oldLines.count, newLines.count)
        var out: [String] = []
        for index in 0..<maxCount {
            let a = index < oldLines.count ? oldLines[index] : nil
            let b = index < newLines.count ? newLines[index] : nil
            if a == b, let a { out.append("  " + a) }
            else {
                if let a { out.append("- " + a) }
                if let b { out.append("+ " + b) }
            }
        }
        return out.joined(separator: "\n")
    }
}
