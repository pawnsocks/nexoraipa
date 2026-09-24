import SwiftUI
import WebKit
import UniformTypeIdentifiers

struct NexoraGitHubImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onImported: ((ProjectRecord) -> Void)?

    @State private var repositoryURL = ""
    @State private var branch = ""
    @State private var projectName = ""
    @State private var busy = false
    @State private var status = ""

    init(onImported: ((ProjectRecord) -> Void)? = nil) {
        self.onImported = onImported
    }

    var body: some View {
        Form {
            Section("GitHub Repository") {
                TextField("https://github.com/owner/repo", text: $repositoryURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Branch (optional)", text: $branch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Project name (optional)", text: $projectName)
            }

            Section {
                Text("Nexora imports the repository directly from the GitHub API to local project storage. This does not fake a desktop Git executable; GitHub sync metadata is stored locally for diff and push.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(busy ? "Importing…" : "Import Repository") {
                    Task { await runImport() }
                }
                .disabled(busy || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !status.isEmpty {
                Section("Status") {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.hasPrefix("Imported") ? .green : .secondary)
                }
            }
        }
        .navigationTitle("Clone / Import")
    }

    private func runImport() async {
        busy = true
        defer { busy = false }
        do {
            let project = try await model.github.importRepository(
                repositoryURL: repositoryURL,
                branch: branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : branch,
                projectName: projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : projectName,
                projects: model.projects,
                history: model.history
            )
            model.refreshLocalState()
            status = "Imported \(project.name)"
            onImported?(project)
        } catch {
            status = error.localizedDescription
        }
    }
}

struct NexoraGitHubProjectView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String

    @State private var link: GitHubProjectLink?
    @State private var changes: [GitHubFileChange] = []
    @State private var message = "Update from Nexora Host"
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        List {
            if let link {
                Section("Repository") {
                    LabeledContent("Repository", value: "\(link.owner)/\(link.repo)")
                    LabeledContent("Branch", value: link.branch)
                    LabeledContent("Head", value: String(link.headSHA.prefix(10)))
                }

                Section("Changes") {
                    if changes.isEmpty {
                        Text("No local changes detected.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(changes) { change in
                        HStack {
                            Image(systemName: icon(change.status))
                            Text(change.path)
                                .font(.caption.monospaced())
                            Spacer()
                            Text(change.status.rawValue.capitalized)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Commit & Push") {
                    TextField("Commit message", text: $message)
                    Button(busy ? "Pushing…" : "Commit & Push") {
                        Task { await push() }
                    }
                    .disabled(busy || changes.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                Section {
                    Text("This project was not imported through Nexora's GitHub integration yet.")
                        .foregroundStyle(.secondary)
                }
            }

            if !status.isEmpty {
                Section("Status") { Text(status).font(.caption) }
            }
        }
        .navigationTitle("GitHub")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { refresh() }
    }

    private func refresh() {
        link = model.github.link(projectID: projectID, projects: model.projects)
        do { changes = try model.github.changes(projectID: projectID, projects: model.projects); status = "" }
        catch { changes = []; if link != nil { status = error.localizedDescription } }
    }

    private func push() async {
        busy = true
        defer { busy = false }
        do {
            link = try await model.github.push(projectID: projectID, message: message, projects: model.projects, history: model.history)
            status = "Pushed successfully"
            refresh()
        } catch { status = error.localizedDescription }
    }

    private func icon(_ status: GitHubFileChange.Status) -> String {
        switch status {
        case .added: return "plus.circle"
        case .modified: return "pencil.circle"
        case .deleted: return "minus.circle"
        }
    }
}

struct NexoraStaticPreviewView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    @State private var fileURL: URL?
    @State private var status = ""

    var body: some View {
        Group {
            if let fileURL {
                NexoraWebView(fileURL: fileURL, rootURL: model.projects.workspaceURL(projectID))
                    .ignoresSafeArea(edges: .bottom)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "safari")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No static web preview found")
                        .font(.headline)
                    Text(status.isEmpty ? "Add index.html to this project to preview it locally." : status)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .navigationTitle("Preview")
        .toolbar {
            if let fileURL {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") }
                }
            }
        }
        .task { detect() }
    }

    private func detect() {
        let root = model.projects.workspaceURL(projectID)
        let candidates = ["index.html", "public/index.html", "www/index.html"]
        fileURL = candidates.map { root.appendingPathComponent($0) }.first { FileManager.default.fileExists(atPath: $0.path) }
        if fileURL == nil { status = "Dynamic Node/Bun development servers are not available on normal iOS. Static HTML preview is implemented." }
    }
}

private struct NexoraWebView: UIViewRepresentable {
    let fileURL: URL
    let rootURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        return WKWebView(frame: .zero, configuration: config)
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != fileURL { webView.loadFileURL(fileURL, allowingReadAccessTo: rootURL) }
    }
}

struct NexoraBackupView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    @State private var backups: [ProjectBackup] = []
    @State private var status = ""
    @State private var restoreTarget: ProjectBackup?

    var body: some View {
        List {
            Section {
                Button("Create Backup") {
                    do {
                        _ = try model.backups.create(projectID: projectID)
                        reload()
                    } catch { status = error.localizedDescription }
                }
            }

            Section("Backups") {
                if backups.isEmpty { Text("No backups yet.").foregroundStyle(.secondary) }
                ForEach(backups) { backup in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(backup.label).font(.headline)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: backup.sizeBytes, countStyle: .file)).font(.caption)
                        }
                        Text(backup.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Restore") { restoreTarget = backup }
                            Button("Delete", role: .destructive) {
                                try? model.backups.delete(projectID: projectID, backupID: backup.id)
                                reload()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
            }

            if !status.isEmpty { Section("Status") { Text(status).font(.caption) } }
        }
        .navigationTitle("Backups")
        .confirmationDialog("Restore this backup? Current project files will be replaced.", isPresented: Binding(get: { restoreTarget != nil }, set: { if !$0 { restoreTarget = nil } }), titleVisibility: .visible) {
            Button("Restore", role: .destructive) {
                guard let target = restoreTarget else { return }
                do { try model.backups.restore(projectID: projectID, backupID: target.id); status = "Backup restored" }
                catch { status = error.localizedDescription }
                restoreTarget = nil
            }
            Button("Cancel", role: .cancel) { restoreTarget = nil }
        }
        .task { reload() }
    }

    private func reload() { backups = model.backups.list(projectID: projectID) }
}

struct NexoraHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String?

    var body: some View {
        List(model.history.list(projectID: projectID)) { event in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(event.title).font(.headline)
                    Spacer()
                    Text(event.timestamp.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(event.kind.rawValue).font(.caption2.bold()).foregroundStyle(.secondary)
                if let detail = event.detail, !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(5) }
            }
            .padding(.vertical, 3)
        }
        .navigationTitle("History")
    }
}

struct NexoraProjectSearchView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    @State private var query = ""
    @State private var regex = false
    @State private var results: [String] = []
    @State private var status = ""

    var body: some View {
        List {
            Section {
                Toggle("Regex", isOn: $regex)
            }
            Section("Results") {
                ForEach(results, id: \.self) { path in
                    NavigationLink(path) { NexoraLocalEditorView(projectID: projectID, path: path) }
                        .font(.caption.monospaced())
                }
                if results.isEmpty && !query.isEmpty { Text("No matches.").foregroundStyle(.secondary) }
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .searchable(text: $query, prompt: "Search project")
        .onSubmit(of: .search) { run() }
        .navigationTitle("Search")
    }

    private func run() {
        do { results = try model.projects.search(projectID: projectID, query: query, regex: regex); status = "\(results.count) matches" }
        catch { status = error.localizedDescription }
    }
}

struct NexoraWebhookView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String?
    @State private var configs: [WebhookConfig] = []
    @State private var showCreate = false
    @State private var status = ""

    var body: some View {
        List {
            Section {
                Button("Add Webhook") { showCreate = true }
            }
            Section("Webhooks") {
                if configs.isEmpty { Text("No webhooks configured.").foregroundStyle(.secondary) }
                ForEach(configs) { config in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack { Text(config.name).font(.headline); Spacer(); Text(config.kind.rawValue).font(.caption).foregroundStyle(.secondary) }
                        Text(model.webhooks.maskedURL(config.id) ?? "URL not set").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        HStack {
                            Button("Send Test") { Task { await send(config) } }
                            Button("Delete", role: .destructive) { model.webhooks.delete(config.id); reload() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 3)
                }
            }
            if !status.isEmpty { Section("Status") { Text(status).font(.caption) } }
        }
        .navigationTitle("Webhooks")
        .sheet(isPresented: $showCreate) {
            NexoraWebhookEditor(projectID: projectID) { reload(); showCreate = false }
                .environmentObject(model)
        }
        .task { reload() }
    }

    private func reload() { configs = model.webhooks.list(projectID: projectID) }
    private func send(_ config: WebhookConfig) async {
        do {
            _ = try await model.webhooks.send(webhookID: config.id, variables: ["project.name": projectID.flatMap { model.projects.get($0)?.name } ?? "Nexora Host", "runtime.status": "test"])
            status = "Webhook delivered"
        } catch { status = error.localizedDescription }
    }
}

private struct NexoraWebhookEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: String?
    let onSaved: () -> Void

    @State private var name = "Discord"
    @State private var kind: WebhookConfig.Kind = .discord
    @State private var url = ""
    @State private var method = "POST"
    @State private var message = "Nexora: {{project.name}} · {{runtime.status}}"
    @State private var embedTitle = ""
    @State private var embedDescription = ""
    @State private var embedFooter = ""
    @State private var embedImageURL = ""
    @State private var embedThumbnailURL = ""
    @State private var embedTimestamp = false
    @State private var status = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Type", selection: $kind) { ForEach(WebhookConfig.Kind.allCases) { Text($0.rawValue).tag($0) } }
                SecureField("Webhook URL", text: $url).textInputAutocapitalization(.never).autocorrectionDisabled()
                if kind == .generic {
                    Picker("Method", selection: $method) { ForEach(["POST", "PUT", "PATCH"], id: \.self) { Text($0) } }
                }
                TextField("Message / JSON", text: $message, axis: .vertical).lineLimit(3...8)
                Text("Variables: {{project.name}}, {{runtime.status}}, {{error.message}}, {{timestamp}}")
                    .font(.caption).foregroundStyle(.secondary)

                if kind == .discord {
                    Section("Discord Embed") {
                        TextField("Title", text: $embedTitle)
                        TextField("Description", text: $embedDescription, axis: .vertical).lineLimit(2...6)
                        TextField("Footer", text: $embedFooter)
                        TextField("Image URL", text: $embedImageURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Thumbnail URL", text: $embedThumbnailURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Toggle("Timestamp", isOn: $embedTimestamp)
                    }

                    Section("Preview") {
                        VStack(alignment: .leading, spacing: 6) {
                            if !embedTitle.isEmpty { Text(embedTitle).font(.headline) }
                            if !embedDescription.isEmpty { Text(embedDescription).font(.subheadline) }
                            if !embedFooter.isEmpty { Text(embedFooter).font(.caption).foregroundStyle(.secondary) }
                            if embedTitle.isEmpty && embedDescription.isEmpty { Text("Add an embed title or description to preview it.").foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 6)
                    }
                }
                if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.red) }
            }
            .navigationTitle("New Webhook")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
        }
    }

    private func save() {
        let embed = kind == .discord ? DiscordEmbedConfig(title: embedTitle, description: embedDescription, footer: embedFooter, imageURL: embedImageURL, thumbnailURL: embedThumbnailURL, timestamp: embedTimestamp) : nil
        let config = WebhookConfig(id: UUID().uuidString, projectID: projectID, name: name, kind: kind, method: method, username: nil, avatarURL: nil, messageTemplate: message, headers: [:], enabled: true, embed: embed)
        do { try model.webhooks.save(config, secretURL: url); onSaved(); dismiss() }
        catch { status = error.localizedDescription }
    }
}

struct NexoraAutomationView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    @State private var items: [NexoraAutomation] = []
    @State private var showCreate = false
    @State private var status = ""

    var body: some View {
        List {
            Section { Button("Add Automation") { showCreate = true } }
            Section("Automations") {
                if items.isEmpty { Text("No automations configured.").foregroundStyle(.secondary) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack { Text(item.name).font(.headline); Spacer(); Text(item.enabled ? "On" : "Off").font(.caption).foregroundStyle(item.enabled ? .green : .secondary) }
                        Text("\(item.trigger.rawValue) → \(item.action.rawValue)").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if item.trigger == .manual {
                                Button("Run") { Task { await run(item) } }
                            }
                            Button("Delete", role: .destructive) { model.automations.delete(item.id); reload() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if !status.isEmpty { Text(status).font(.caption) }
        }
        .navigationTitle("Automations")
        .sheet(isPresented: $showCreate) {
            NexoraAutomationEditor(projectID: projectID) { reload(); showCreate = false }
                .environmentObject(model)
        }
        .task { reload() }
    }

    private func reload() { items = model.automations.list(projectID: projectID) }
    private func run(_ item: NexoraAutomation) async {
        await model.automations.fire(trigger: .manual, projectID: projectID, variables: ["project.name": model.projects.get(projectID)?.name ?? "Project", "runtime.status": model.projects.get(projectID)?.state.rawValue ?? "unknown"])
        status = "Manual automation fired"
    }
}

private struct NexoraAutomationEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: String
    let onSaved: () -> Void
    @State private var name = "Automation"
    @State private var trigger: NexoraAutomation.Trigger = .runFailed
    @State private var action: NexoraAutomation.Action = .createBackup
    @State private var webhookID = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Trigger", selection: $trigger) { ForEach(NexoraAutomation.Trigger.allCases) { Text($0.rawValue).tag($0) } }
                Picker("Action", selection: $action) { ForEach(NexoraAutomation.Action.allCases) { Text($0.rawValue).tag($0) } }
                if action == .sendWebhook {
                    Picker("Webhook", selection: $webhookID) {
                        Text("Choose").tag("")
                        ForEach(model.webhooks.list(projectID: projectID)) { Text($0.name).tag($0.id) }
                    }
                }
            }
            .navigationTitle("Automation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.automations.save(.init(id: UUID().uuidString, projectID: projectID, name: name, trigger: trigger, action: action, webhookID: webhookID.isEmpty ? nil : webhookID, enabled: true))
                        onSaved(); dismiss()
                    }
                    .disabled(action == .sendWebhook && webhookID.isEmpty)
                }
            }
        }
    }
}

struct NexoraStorageView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section("Projects") {
                ForEach(model.projects.list()) { project in
                    LabeledContent(project.name, value: ByteCountFormatter.string(fromByteCount: model.projects.projectSize(project.id), countStyle: .file))
                }
            }
            Section("Safety") {
                Text("Nexora never silently deletes project files. Delete projects or backups explicitly from their own screens.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Storage")
    }
}

struct NexoraGitHubSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var token = ""
    @State private var status = ""
    @State private var repos: [GitHubRepository] = []
    @State private var busy = false

    var body: some View {
        Form {
            Section("Token") {
                SecureField(model.github.maskedToken ?? "GitHub token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Save Token") {
                    model.github.saveToken(token)
                    token = ""
                    status = "Saved securely in Keychain"
                }
                Button("Delete Token", role: .destructive) {
                    model.github.deleteToken()
                    status = "Token deleted"
                }
                .disabled(!model.github.hasToken)
            }

            Section("Account repositories") {
                Button(busy ? "Loading…" : "Load Repositories") {
                    Task { await load() }
                }
                .disabled(busy || !model.github.hasToken)
                ForEach(repos.prefix(20)) { repo in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(repo.fullName)
                        Text(repo.defaultBranch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Import") {
                NavigationLink("Clone / Import Repository") {
                    NexoraGitHubImportView()
                }
            }

            if !status.isEmpty {
                Section("Status") { Text(status).font(.caption) }
            }
        }
        .navigationTitle("GitHub")
    }

    private func load() async {
        busy = true
        defer { busy = false }
        do {
            repos = try await model.github.repositories()
            status = "Loaded \(repos.count) repositories"
        } catch { status = error.localizedDescription }
    }
}

struct NexoraOnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var completed: Bool
    @State private var step = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 58))
                    .foregroundStyle(.primary)

                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(detail)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                if step == 1 {
                    VStack(spacing: 8) {
                        LabeledContent("Device", value: model.metrics.deviceClass)
                        LabeledContent("Thermal", value: model.metrics.thermal)
                        LabeledContent("Memory", value: String(format: "%.0f MB physical", model.metrics.physicalMemoryMB))
                        LabeledContent("Auto Tune", value: model.profile.rawValue)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                }

                if step == 2 {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.runtimeStatuses.filter(\.available)) { runtime in
                            Label("\(runtime.id.rawValue) · Available", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text("Unsupported desktop runtimes stay clearly marked unavailable.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                }

                Spacer()

                Button(step == 3 ? "Open Projects" : "Continue") {
                    if step < 3 { step += 1 }
                    else { completed = true }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)

                if step >= 2 {
                    Button("Skip optional setup") { completed = true }
                        .font(.caption)
                }
            }
            .padding(.bottom, 24)
            .task { model.refreshLocalState() }
        }
    }

    private var title: String {
        switch step {
        case 0: return "Welcome to Nexora Host"
        case 1: return "Device Detection"
        case 2: return "Runtime Capability Scan"
        default: return "Ready"
        }
    }

    private var detail: String {
        switch step {
        case 0: return "A local-first coding workspace for iPhone and iPad. No Debian server, account or AI key is required."
        case 1: return "Nexora uses available Apple APIs and safe heuristics to tune itself for the current device."
        case 2: return "Only runtimes that really work in this IPA are marked Available."
        default: return "GitHub and AI can be configured later from Settings. Your local workspace works without them."
        }
    }

    private var icon: String {
        switch step {
        case 0: return "chevron.left.forwardslash.chevron.right"
        case 1: return "iphone.gen3"
        case 2: return "shippingbox"
        default: return "checkmark.circle.fill"
        }
    }
}

struct NexoraAPIExplorerView: View {
    @State private var method = "GET"
    @State private var url = "https://"
    @State private var headers = ""
    @State private var requestBody = ""
    @State private var response = ""
    @State private var busy = false

    var body: some View {
        Form {
            Section("Request") {
                Picker("Method", selection: $method) {
                    ForEach(["GET", "POST", "PUT", "PATCH", "DELETE"], id: \.self) { Text($0) }
                }
                TextField("https://api.example.com", text: $url)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("Headers (one per line: Name: value)", text: $headers, axis: .vertical)
                    .lineLimit(2...6)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if method != "GET" && method != "DELETE" {
                    TextField("JSON / body", text: $requestBody, axis: .vertical)
                        .lineLimit(3...10)
                        .font(.system(.body, design: .monospaced))
                }
                Button(busy ? "Sending…" : "Send Request") {
                    Task { await send() }
                }
                .disabled(busy)
            }

            Section("Response") {
                ScrollView(.horizontal) {
                    Text(response.isEmpty ? "Response appears here." : response)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160)
            }

            Section("Privacy") {
                Text("Requests are sent directly from the device to the URL you enter. Nexora does not add AI or GitHub credentials automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("API Explorer")
    }

    private func send() async {
        busy = true
        defer { busy = false }
        guard let target = URL(string: url), ["https", "http"].contains(target.scheme?.lowercased() ?? "") else {
            response = "Invalid URL"
            return
        }

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = 30
        for line in headers.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            request.setValue(parts[1].trimmingCharacters(in: .whitespaces), forHTTPHeaderField: parts[0].trimmingCharacters(in: .whitespaces))
        }
        if method != "GET" && method != "DELETE" && !requestBody.isEmpty {
            request.httpBody = Data(requestBody.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        }

        do {
            let (data, rawResponse) = try await URLSession.shared.data(for: request)
            guard let http = rawResponse as? HTTPURLResponse else { response = "Invalid HTTP response"; return }
            var lines = ["HTTP \(http.statusCode)"]
            for (key, value) in http.allHeaderFields.sorted(by: { String(describing: $0.key) < String(describing: $1.key) }) {
                lines.append("\(key): \(value)")
            }
            lines.append("")
            if let object = try? JSONSerialization.jsonObject(with: data), let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), let text = String(data: pretty, encoding: .utf8) {
                lines.append(text)
            } else {
                lines.append(String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>")
            }
            response = lines.joined(separator: "\n")
        } catch {
            response = error.localizedDescription
        }
    }
}

struct NexoraZIPImportView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showPicker = false
    @State private var projectName = ""
    @State private var status = ""
    @State private var importedProjectID: String?

    private var zipType: UTType { UTType(filenameExtension: "zip") ?? .data }

    var body: some View {
        Form {
            Section("Import ZIP") {
                TextField("Project name (optional)", text: $projectName)
                Button("Choose ZIP") { showPicker = true }
            }

            Section {
                Text("The ZIP is unpacked locally on the device. Hidden Git metadata and Nexora metadata are ignored during import.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let importedProjectID, let project = model.projects.get(importedProjectID) {
                Section("Imported") {
                    NavigationLink("Open \(project.name)") {
                        NexoraLocalProjectWorkspaceView(projectID: project.id)
                    }
                }
            }

            if !status.isEmpty {
                Section("Status") { Text(status).font(.caption) }
            }
        }
        .navigationTitle("Import Project")
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [zipType], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importZIP(url)
            case .failure(let error):
                status = error.localizedDescription
            }
        }
    }

    private func importZIP(_ url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let localCopy = FileManager.default.temporaryDirectory.appendingPathComponent("nexora-import-\(UUID().uuidString).zip")
            try? FileManager.default.removeItem(at: localCopy)
            try FileManager.default.copyItem(at: url, to: localCopy)
            defer { try? FileManager.default.removeItem(at: localCopy) }
            let project = try model.archives.importZIP(
                url: localCopy,
                name: projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : projectName,
                projects: model.projects,
                history: model.history
            )
            model.refreshLocalState()
            importedProjectID = project.id
            status = "Imported \(project.name)"
        } catch {
            status = error.localizedDescription
        }
    }
}

struct NexoraProjectExportView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    @State private var exportURL: URL?
    @State private var status = ""

    var body: some View {
        List {
            Section("Project ZIP") {
                Button("Create Export ZIP") {
                    do {
                        exportURL = try model.archives.exportProject(projectID: projectID, projects: model.projects)
                        status = "Export ready"
                    } catch { status = error.localizedDescription }
                }

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Label("Share / Save ZIP", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if !status.isEmpty { Section("Status") { Text(status).font(.caption) } }
        }
        .navigationTitle("Export Project")
    }
}

struct NexoraProjectSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: String

    @State private var name = ""
    @State private var duplicateName = ""
    @State private var status = ""
    @State private var showDelete = false

    var body: some View {
        Form {
            Section("Project") {
                TextField("Name", text: $name)
                Button("Rename") {
                    do {
                        _ = try model.projects.renameProject(projectID, name: name)
                        model.refreshLocalState()
                        status = "Project renamed"
                    } catch { status = "Rename failed: \(error)" }
                }
            }

            Section("Duplicate") {
                TextField("Copy name (optional)", text: $duplicateName)
                Button("Duplicate Project") {
                    do {
                        let copy = try model.projects.duplicateProject(projectID, name: duplicateName.isEmpty ? nil : duplicateName)
                        model.refreshLocalState()
                        status = "Created \(copy.name)"
                    } catch { status = "Duplicate failed: \(error)" }
                }
            }

            Section("Danger Zone") {
                Button("Delete Project", role: .destructive) { showDelete = true }
            }

            if !status.isEmpty { Section("Status") { Text(status).font(.caption) } }
        }
        .navigationTitle("Project Settings")
        .onAppear { name = model.projects.get(projectID)?.name ?? "" }
        .confirmationDialog("Delete this project and its local files?", isPresented: $showDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try model.projects.delete(projectID)
                    model.refreshLocalState()
                    dismiss()
                } catch { status = "Delete failed: \(error)" }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
