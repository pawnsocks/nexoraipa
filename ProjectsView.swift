import SwiftUI
import WebKit

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var projects: [RemoteProject] = []
    @State private var status = ""
    @State private var showCreate = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if !model.remote.isConfigured {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Connect your backend", systemImage: "server.rack")
                                .font(.headline)
                            Text("Nexora Host keeps projects, terminals, builds and runtimes on your Debian server. Add the backend URL and owner token in Settings first.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }

                Section("Projects") {
                    if projects.isEmpty {
                        Text(loading ? "Loading…" : "No remote projects yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(projects) { project in
                        NavigationLink {
                            NexoraProjectWorkspaceView(projectID: project.id)
                        } label: {
                            ProjectRow(project: project)
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
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .disabled(!model.remote.isConfigured)
                }
            }
            .sheet(isPresented: $showCreate) {
                NexoraCreateProjectSheet { project in
                    projects.insert(project, at: 0)
                    showCreate = false
                }
                .environmentObject(model)
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        guard model.remote.isConfigured else {
            projects = []
            status = "Backend not configured"
            return
        }
        loading = true
        defer { loading = false }
        do {
            projects = try await model.remote.listProjects()
            model.remoteProjects = projects
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct ProjectRow: View {
    let project: RemoteProject

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(project.name)
                    .font(.headline)
                Spacer()
                Text(project.status.uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(project.status == "running" ? .green : .secondary)
            }

            HStack(spacing: 8) {
                Text(project.runtime)
                if let framework = project.framework, !framework.isEmpty { Text(framework) }
                Text(project.branch)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let repo = project.repoURL, !repo.isEmpty {
                Text(repo)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct NexoraCreateProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let onCreated: (RemoteProject) -> Void

    @State private var mode = 0
    @State private var githubURL = ""
    @State private var branch = ""
    @State private var name = ""
    @State private var template = "Node.js"
    @State private var busy = false
    @State private var status = ""

    private let templates = [
        "Node.js", "Bun", "Python", "FastAPI", "Flask", "Discord Bot",
        "Go", "Rust", "Java", "C#", "Lua", "Static Website"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Source", selection: $mode) {
                    Text("GitHub").tag(0)
                    Text("Empty").tag(1)
                }
                .pickerStyle(.segmented)

                if mode == 0 {
                    Section("Clone GitHub repository") {
                        TextField("https://github.com/owner/repo", text: $githubURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Branch (optional)", text: $branch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Project name (optional)", text: $name)
                    }
                } else {
                    Section("Create empty project") {
                        TextField("Project name", text: $name)
                        Picker("Template", selection: $template) {
                            ForEach(templates, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }

                Section {
                    Button(busy ? "Creating…" : (mode == 0 ? "Clone & detect" : "Create project")) {
                        Task { await create() }
                    }
                    .disabled(busy || (mode == 0 ? githubURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }

                if !status.isEmpty {
                    Section("Status") {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            let project: RemoteProject
            if mode == 0 {
                project = try await model.remote.cloneProject(
                    url: githubURL.trimmingCharacters(in: .whitespacesAndNewlines),
                    branch: branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : branch,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
                )
            } else {
                project = try await model.remote.createProject(name: name, template: template)
            }
            onCreated(project)
        } catch {
            status = error.localizedDescription
        }
    }
}

enum NexoraWorkspaceSection: String, CaseIterable, Identifiable {
    case code = "Code"
    case files = "Files"
    case terminal = "Terminal"
    case preview = "Preview"
    case git = "Git"
    case logs = "Logs"
    case ai = "AI"
    case more = "More"
    var id: String { rawValue }
}

struct NexoraProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String

    @State private var project: RemoteProject?
    @State private var section: NexoraWorkspaceSection = .code
    @State private var activeFilePath: String?
    @State private var activeFileContent = ""
    @State private var status = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 0) {
            if let project {
                projectHeader(project)
                Divider()

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(NexoraWorkspaceSection.allCases) { item in
                            Button(item.rawValue) { section = item }
                                .buttonStyle(.bordered)
                                .tint(section == item ? .accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }

                Divider()

                Group {
                    switch section {
                    case .code:
                        NexoraRemoteCodeView(
                            project: project,
                            activePath: $activeFilePath,
                            activeContent: $activeFileContent,
                            onOpenFiles: { section = .files }
                        )
                    case .files:
                        NexoraRemoteFilesView(project: project) { path in
                            activeFilePath = path
                            section = .code
                        }
                    case .terminal:
                        NexoraRemoteTerminalView(project: project)
                    case .preview:
                        NexoraPreviewView(project: project)
                    case .git:
                        NexoraGitView(project: project)
                    case .logs:
                        NexoraLogsView(project: project)
                    case .ai:
                        RemoteAICodingAssistantView(
                            project: project,
                            activeFilePath: activeFilePath,
                            activeFileContent: activeFileContent,
                            onApplyFile: { path, content in
                                Task {
                                    do {
                                        _ = try await model.remote.writeFile(projectID: project.id, path: path, content: content)
                                        if activeFilePath == path { activeFileContent = content }
                                        status = "Applied \(path)"
                                    } catch {
                                        status = error.localizedDescription
                                    }
                                }
                            }
                        )
                    case .more:
                        NexoraMoreProjectView(project: project)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(status.isEmpty ? "Loading project…" : status)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(project?.name ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshProject() }
    }

    @ViewBuilder
    private func projectHeader(_ project: RemoteProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(project.status == "running" ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                        Text(project.status.uppercased())
                            .font(.caption.bold())
                    }
                    Text([project.runtime, project.framework, project.branch].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let port = project.port {
                    Label("\(port)", systemImage: "network")
                        .font(.caption)
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await start() }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)

                Button {
                    Task { await stop() }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Button {
                    Task { await restart() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Button("Setup") {
                    Task { await setup() }
                }
                .buttonStyle(.bordered)
                .disabled(busy)

                Spacer()

                Button {
                    Task { await refreshProject() }
                } label: {
                    Image(systemName: "arrow.clockwise.circle")
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func refreshProject() async {
        do {
            project = try await model.remote.project(projectID)
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    private func start() async {
        await runLifecycle("Starting") { try await model.remote.startProject(projectID: projectID) }
    }

    private func restart() async {
        await runLifecycle("Restarting") { try await model.remote.restartProject(projectID: projectID) }
    }

    private func setup() async {
        await runLifecycle("Installing dependencies") { try await model.remote.setupProject(projectID: projectID) }
    }

    private func stop() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await model.remote.stopProject(projectID: projectID)
            status = "Stopped"
            await refreshProject()
        } catch {
            status = error.localizedDescription
        }
    }

    private func runLifecycle(_ label: String, operation: () async throws -> RemoteTask) async {
        busy = true
        defer { busy = false }
        do {
            var task = try await operation()
            status = "\(label)…"
            task = try await waitForTask(task)
            status = task.status == "completed" ? "\(label) completed" : (task.output.isEmpty ? task.status : task.output)
            await refreshProject()
        } catch {
            status = error.localizedDescription
        }
    }

    private func waitForTask(_ initial: RemoteTask) async throws -> RemoteTask {
        var current = initial
        for _ in 0..<120 {
            if ["completed", "failed", "cancelled"].contains(current.status) { return current }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            current = try await model.remote.task(current.id)
        }
        return current
    }
}

private struct NexoraRemoteCodeView: View {
    @EnvironmentObject private var model: AppModel
    let project: RemoteProject
    @Binding var activePath: String?
    @Binding var activeContent: String
    let onOpenFiles: () -> Void

    @State private var status = ""
    @State private var saving = false
    @State private var taskOutput = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button {
                    onOpenFiles()
                } label: {
                    Label(activePath ?? "Choose file", systemImage: "doc.text")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    Task { await save() }
                }
                .disabled(activePath == nil || saving)

                Button {
                    Task { await runCurrentFile() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(activePath == nil)
            }

            TextEditor(text: $activeContent)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            if !taskOutput.isEmpty {
                ScrollView {
                    Text(taskOutput)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
                .padding(8)
                .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .task {
            if activePath == nil, let entry = project.entrypoint, !entry.isEmpty {
                await open(entry)
            }
        }
        .onChange(of: activePath) { value in
            guard let value else { return }
            Task { await open(value) }
        }
    }

    private func open(_ path: String) async {
        do {
            let file = try await model.remote.readFile(projectID: project.id, path: path)
            guard file.encoding == "utf8" else {
                status = "Binary files are not editable in the code editor."
                return
            }
            activePath = file.path
            activeContent = file.content
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    private func save() async {
        guard let path = activePath else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await model.remote.writeFile(projectID: project.id, path: path, content: activeContent)
            status = "Saved \(path)"
        } catch {
            status = error.localizedDescription
        }
    }

    private func runCurrentFile() async {
        guard let path = activePath else { return }
        await save()
        guard let command = commandFor(path) else {
            status = "Use the project Start button or Terminal for this file type."
            return
        }
        do {
            var task = try await model.remote.runCommand(projectID: project.id, command: command)
            taskOutput = "Running: \(command)"
            for _ in 0..<120 {
                if ["completed", "failed", "cancelled"].contains(task.status) { break }
                try await Task.sleep(nanoseconds: 750_000_000)
                task = try await model.remote.task(task.id)
                taskOutput = task.output
            }
            taskOutput = task.output
            status = task.status
        } catch {
            status = error.localizedDescription
        }
    }

    private func commandFor(_ path: String) -> String? {
        let quoted = shellQuote(path)
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "js": return "node \(quoted)"
        case "ts": return "bun \(quoted)"
        case "py": return "python3 \(quoted)"
        case "lua": return "lua \(quoted)"
        case "go": return "go run \(quoted)"
        case "rs": return "rustc \(quoted) -o /tmp/nexora-run && /tmp/nexora-run"
        case "java": return "javac \(quoted) && java \(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)"
        case "sh": return "bash \(quoted)"
        case "rb": return "ruby \(quoted)"
        case "php": return "php \(quoted)"
        default: return nil
        }
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private struct NexoraRemoteFilesView: View {
    @EnvironmentObject private var model: AppModel
    let project: RemoteProject
    let onOpen: (String) -> Void

    @State private var path = ""
    @State private var files: [RemoteFileInfo] = []
    @State private var status = ""
    @State private var showCreate = false
    @State private var createFolder = false
    @State private var newName = ""
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if !path.isEmpty {
                    Button {
                        path = parent(path)
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                }
                Text(path.isEmpty ? "/" : "/\(path)")
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("New file") { createFolder = false; newName = ""; showCreate = true }
                    Button("New folder") { createFolder = true; newName = ""; showCreate = true }
                } label: {
                    Image(systemName: "plus")
                }
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            List(filteredFiles) { file in
                Button {
                    if file.isDirectory {
                        path = file.path
                        Task { await refresh() }
                    } else {
                        onOpen(file.path)
                    }
                } label: {
                    HStack {
                        Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                            .foregroundStyle(file.isDirectory ? .blue : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .foregroundStyle(.primary)
                            Text(file.isDirectory ? "Folder" : byteText(file.size))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !file.isDirectory {
                        Button("Open") { onOpen(file.path) }
                        Button("Ask AI") { onOpen(file.path) }
                    }
                    Button("Delete", role: .destructive) {
                        Task { await delete(file) }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search this folder")

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
            }
        }
        .task { await refresh() }
        .alert(createFolder ? "New Folder" : "New File", isPresented: $showCreate) {
            TextField(createFolder ? "Folder name" : "File name", text: $newName)
            Button("Cancel", role: .cancel) { }
            Button("Create") { Task { await create() } }
        }
    }

    private var filteredFiles: [RemoteFileInfo] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return files }
        return files.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    private func refresh() async {
        do {
            files = try await model.remote.listFiles(projectID: project.id, path: path)
            status = ""
        } catch {
            status = error.localizedDescription
        }
    }

    private func create() async {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let target = path.isEmpty ? clean : path + "/" + clean
        do {
            if createFolder {
                try await model.remote.createFolder(projectID: project.id, path: target)
            } else {
                _ = try await model.remote.writeFile(projectID: project.id, path: target, content: "")
            }
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    private func delete(_ file: RemoteFileInfo) async {
        do {
            try await model.remote.deletePath(projectID: project.id, path: file.path)
            await refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    private func parent(_ value: String) -> String {
        let parts = value.split(separator: "/")
        guard parts.count > 1 else { return "" }
        return parts.dropLast().joined(separator: "/")
    }

    private func byteText(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .file)
    }
}

private struct NexoraRemoteTerminalView: View {
    @EnvironmentObject private var model: AppModel
    let project: RemoteProject

    @State private var command = ""
    @State private var output = "Remote terminal ready."
    @State private var currentTask: RemoteTask?
    @State private var status = ""
    @FocusState private var focused: Bool

    private let helpers = ["ESC", "CTRL+C", "TAB", "↑", "↓", "|", "/", "-", "~"]

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                Text(output)
                    .font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding()
            }
            .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(helpers, id: \.self) { key in
                        Button(key) { helper(key) }
                            .buttonStyle(.bordered)
                            .font(.caption.monospaced())
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack {
                TextField("command", text: $command)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit { Task { await run() } }
                Button("Run") { Task { await run() } }
                    .buttonStyle(.borderedProminent)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }

    private func helper(_ key: String) {
        switch key {
        case "CTRL+C":
            if let currentTask {
                Task {
                    do {
                        _ = try await model.remote.cancelTask(currentTask.id)
                        status = "Cancelled"
                    } catch { status = error.localizedDescription }
                }
            }
        case "TAB": command += "\t"
        case "|", "/", "-", "~": command += key
        case "↑", "↓", "ESC": break
        default: break
        }
    }

    private func run() async {
        let clean = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        output += "\n$ \(clean)\n"
        command = ""
        do {
            var task = try await model.remote.runCommand(projectID: project.id, command: clean)
            currentTask = task
            for _ in 0..<600 {
                output = "$ \(clean)\n" + task.output
                if ["completed", "failed", "cancelled"].contains(task.status) { break }
                try await Task.sleep(nanoseconds: 500_000_000)
                task = try await model.remote.task(task.id)
                currentTask = task
            }
            output = "$ \(clean)\n" + task.output
            status = "\(task.status)" + (task.exitCode.map { " · exit \($0)" } ?? "")
        } catch {
            status = error.localizedDescription
        }
    }
}

private struct NexoraPreviewView: View {
    let project: RemoteProject

    var body: some View {
        if let urlText = project.previewURL, let url = URL(string: urlText) {
            VStack(spacing: 0) {
                HStack {
                    Text(urlText)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                    Link(destination: url) { Image(systemName: "safari") }
                }
                .padding(8)
                Divider()
                NexoraWebView(url: url)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No preview yet")
                    .font(.headline)
                Text("Start the project. Nexora Host will show a preview after the backend detects an HTTP port.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NexoraWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.allowsBackForwardNavigationGestures = true
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url != url {
            uiView.load(URLRequest(url: url))
        }
    }
}

private struct NexoraGitView: View {
    @EnvironmentObject private var model: AppModel
    let project: RemoteProject

    @State private var git: RemoteGitStatus?
    @State private var message = ""
    @State private var status = ""
    @State private var push = false

    var body: some View {
        Form {
            Section("Repository") {
                LabeledContent("Branch", value: git?.branch ?? project.branch)
                LabeledContent("State", value: git?.clean == true ? "Clean" : "Changes")
                if let commit = git?.latestCommit { Text(commit).font(.caption.monospaced()) }
                Button("Pull") { Task { await pull() } }
                Button("Refresh") { Task { await refresh() } }
            }

            if let changed = git?.changed, !changed.isEmpty {
                Section("Changed files") {
                    ForEach(changed, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
            }

            Section("Commit") {
                TextField("Commit message", text: $message)
                Toggle("Push after commit", isOn: $push)
                Button("Commit") { Task { await commit() } }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        do { git = try await model.remote.gitStatus(projectID: project.id); status = "" }
        catch { status = error.localizedDescription }
    }

    private func pull() async {
        do {
            let task = try await model.remote.gitPull(projectID: project.id)
            status = "Pull task \(task.status)"
        } catch { status = error.localizedDescription }
    }

    private func commit() async {
        do {
            let task = try await model.remote.gitCommit(projectID: project.id, message: message, push: push)
            status = "Commit task \(task.status)"
            message = ""
        } catch { status = error.localizedDescription }
    }
}

private struct NexoraLogsView: View {
    @EnvironmentObject private var model: AppModel
    let project: RemoteProject
    @State private var logs: [RemoteLogLine] = []
    @State private var filter = "All"
    @State private var status = ""

    var body: some View {
        VStack(spacing: 8) {
            Picker("Filter", selection: $filter) {
                ForEach(["All", "Info", "Warning", "Error"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            List(filtered) { line in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(line.level.uppercased())
                            .font(.caption2.bold())
                            .foregroundStyle(logColor(line.level))
                        Spacer()
                        Text(line.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(line.message)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .task { await refresh() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
            }
        }
    }

    private var filtered: [RemoteLogLine] {
        guard filter != "All" else { return logs }
        let key = filter.lowercased()
        return logs.filter { $0.level.lowercased().contains(key == "warning" ? "warn" : key) }
    }

    private func refresh() async {
        do { logs = try await model.remote.logs(projectID: project.id); status = "" }
        catch { status = error.localizedDescription }
    }

    private func logColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "error": return .red
        case "warn", "warning": return .orange
        default: return .secondary
        }
    }
}

private struct NexoraMoreProjectView: View {
    let project: RemoteProject

    var body: some View {
        List {
            Section("Next platform modules") {
                feature("Deployments", "Build/deploy history, rollback and health checks are Phase 3.")
                feature("Database Manager", "PostgreSQL, MySQL/MariaDB, MongoDB and Redis management are Phase 5.")
                feature("Integrations", "Discord/webhooks and automation are Phase 4.")
                feature("Problems & Tests", "Diagnostics, test panels and autonomous Agent Mode are Phase 2.")
            }

            Section("Current vertical slice") {
                Label("GitHub clone/import", systemImage: "checkmark.circle.fill")
                Label("Remote files/editor", systemImage: "checkmark.circle.fill")
                Label("Remote terminal/tasks", systemImage: "checkmark.circle.fill")
                Label("Runtime/framework detection", systemImage: "checkmark.circle.fill")
                Label("Start/stop/restart", systemImage: "checkmark.circle.fill")
                Label("Port detection + preview", systemImage: "checkmark.circle.fill")
                Label("Project-aware AI edits", systemImage: "checkmark.circle.fill")
            }
        }
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}
