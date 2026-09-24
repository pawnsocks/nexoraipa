import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showCreate = false
    @State private var errorText = ""

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Quick Actions")
                        .font(.headline)

                    LazyVGrid(columns: columns, spacing: 12) {
                        Button {
                            showCreate = true
                        } label: {
                            NexoraActionCard(
                                label: "PROJECT",
                                title: "Create Project",
                                subtitle: "Start a new local project.",
                                symbol: "plus.rectangle.on.folder"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            RuntimesView()
                        } label: {
                            NexoraActionCard(
                                label: "RUNTIMES",
                                title: "Capabilities",
                                subtitle: "See what really runs on this device.",
                                symbol: "shippingbox"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            NexoraGitHubImportView()
                        } label: {
                            NexoraActionCard(
                                label: "GITHUB",
                                title: "Clone Repository",
                                subtitle: "Import a GitHub repository to this device.",
                                symbol: "arrow.down.doc"
                            )
                        }
                        .buttonStyle(.plain)

                        NavigationLink {
                            NexoraZIPImportView()
                        } label: {
                            NexoraActionCard(
                                label: "IMPORT",
                                title: "Import ZIP",
                                subtitle: "Unpack an existing project locally.",
                                symbol: "square.and.arrow.down"
                            )
                        }
                        .buttonStyle(.plain)

                        if let recent = model.localProjects.first {
                            NavigationLink {
                                NexoraLocalProjectWorkspaceView(projectID: recent.id)
                            } label: {
                                NexoraActionCard(
                                    label: "RECENT",
                                    title: recent.name,
                                    subtitle: "Continue your latest project.",
                                    symbol: "clock.arrow.circlepath"
                                )
                            }
                            .buttonStyle(.plain)
                        }

                        if model.ai.hasAPIKey {
                            NavigationLink {
                                AIView()
                            } label: {
                                NexoraActionCard(
                                    label: "AI",
                                    title: "Coding Assistant",
                                    subtitle: "Open project-aware AI tools.",
                                    symbol: "sparkles"
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        Text("Projects")
                            .font(.headline)
                        Spacer()
                        Button {
                            model.refreshLocalState()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }

                    if model.localProjects.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "folder")
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                            Text("No projects yet")
                                .font(.headline)
                            Text("Create a local JavaScript, Lua or available Python project.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(model.localProjects) { project in
                            NavigationLink {
                                NexoraLocalProjectWorkspaceView(projectID: project.id)
                            } label: {
                                NexoraProjectCard(project: project)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !errorText.isEmpty {
                        Text(errorText)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding()
            }
            .navigationTitle("Nexora Host")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showCreate = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreate) {
                NexoraCreateLocalProjectSheet {
                    model.refreshLocalState()
                    showCreate = false
                }
                .environmentObject(model)
            }
            .task { model.refreshLocalState() }
        }
    }
}

private struct NexoraActionCard: View {
    let label: String
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.title2)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .topLeading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct NexoraProjectCard: View {
    let project: ProjectRecord

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.title2)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text("\(project.runtime.rawValue) · \(project.entrypoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(project.state.rawValue.capitalized)
                .font(.caption2.bold())
                .foregroundStyle(project.state.rawValue == "running" ? .green : .secondary)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct NexoraCreateLocalProjectSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onCreated: () -> Void

    @State private var name = ""
    @State private var runtime: RuntimeKind = .javascript
    @State private var status = ""

    private var available: [RuntimeKind] {
        model.runtimeStatuses.filter(\.available).map(\.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Project") {
                    TextField("Project name", text: $name)
                    Picker("Runtime", selection: $runtime) {
                        ForEach(available) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                }

                Section {
                    Text("Only runtimes that are actually available in this IPA are offered here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !status.isEmpty {
                    Section("Status") {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(
                            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !available.contains(runtime)
                        )
                }
            }
            .onAppear {
                model.refreshLocalState()
                if !available.contains(runtime), let first = available.first {
                    runtime = first
                }
            }
        }
    }

    private func create() {
        do {
            _ = try model.projects.create(name: name, runtime: runtime, entrypoint: nil)
            model.refreshLocalState()
            onCreated()
            dismiss()
        } catch {
            status = "Could not create project: \(error)"
        }
    }
}

struct NexoraLocalProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String

    @State private var project: ProjectRecord?
    @State private var runStatus = ""

    var body: some View {
        List {
            if let project {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(project.name)
                                    .font(.title2.bold())
                                Text("\(project.runtime.rawValue) · \(project.entrypoint)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(project.state.rawValue.capitalized)
                                .font(.caption.bold())
                                .foregroundStyle(project.state.rawValue == "running" ? .green : .secondary)
                        }

                        HStack {
                            Button {
                                let result = model.runProject(projectID)
                                runStatus = result.output
                                refresh()
                            } label: {
                                Label("Run", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                model.stopProject(projectID)
                                runStatus = "Stopped"
                                refresh()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .buttonStyle(.bordered)

                            Button {
                                let result = model.restartProject(projectID)
                                runStatus = result.output
                                refresh()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Workspace") {
                    NavigationLink {
                        NexoraLocalFilesView(projectID: projectID, path: "")
                    } label: {
                        Label("Files", systemImage: "folder")
                    }

                    NavigationLink {
                        NexoraLocalEditorView(projectID: projectID, path: project.entrypoint)
                    } label: {
                        Label("Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }

                    NavigationLink {
                        NexoraLocalConsoleView(projectID: projectID)
                    } label: {
                        Label("Console", systemImage: "terminal")
                    }

                    NavigationLink {
                        NexoraLocalDatabaseView(projectID: projectID)
                    } label: {
                        Label("SQLite", systemImage: "cylinder")
                    }

                    NavigationLink {
                        NexoraStaticPreviewView(projectID: projectID)
                    } label: {
                        Label("Preview", systemImage: "safari")
                    }

                    NavigationLink {
                        NexoraGitHubProjectView(projectID: projectID)
                    } label: {
                        Label("GitHub", systemImage: "point.3.connected.trianglepath.dotted")
                    }

                    NavigationLink {
                        NexoraProjectSearchView(projectID: projectID)
                    } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }

                    NavigationLink {
                        NexoraBackupView(projectID: projectID)
                    } label: {
                        Label("Backups", systemImage: "externaldrive")
                    }

                    NavigationLink {
                        NexoraProjectExportView(projectID: projectID)
                    } label: {
                        Label("Export ZIP", systemImage: "square.and.arrow.up")
                    }

                    NavigationLink {
                        NexoraHistoryView(projectID: projectID)
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }

                    NavigationLink {
                        NexoraWebhookView(projectID: projectID)
                    } label: {
                        Label("Webhooks", systemImage: "link")
                    }

                    NavigationLink {
                        NexoraAutomationView(projectID: projectID)
                    } label: {
                        Label("Automation", systemImage: "bolt")
                    }

                    NavigationLink {
                        NexoraProjectSettingsView(projectID: projectID)
                    } label: {
                        Label("Project Settings", systemImage: "gearshape")
                    }

                    if model.ai.hasAPIKey {
                        NavigationLink {
                            AIView(projectID: projectID, filePath: project.entrypoint)
                        } label: {
                            Label("AI", systemImage: "sparkles")
                        }
                    } else {
                        HStack {
                            Label("AI", systemImage: "sparkles")
                            Spacer()
                            Text("Optional · not configured")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Runtime") {
                    let runtime = model.runtimeStatuses.first(where: { $0.id == project.runtime })
                    LabeledContent("Runtime", value: project.runtime.rawValue)
                    LabeledContent("Capability", value: runtime?.available == true ? "Available" : "Unavailable")
                    if let detail = runtime?.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !runStatus.isEmpty {
                    Section("Latest Run") {
                        Text(runStatus)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            } else {
                Text("Project not found.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(project?.name ?? "Project")
        .task { refresh() }
    }

    private func refresh() {
        model.refreshLocalState()
        project = model.projects.get(projectID)
    }
}

struct NexoraLocalFilesView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    let path: String

    @State private var files: [ProjectFileInfo] = []
    @State private var newName = ""
    @State private var showNewFile = false
    @State private var showNewFolder = false
    @State private var deleteCandidate: ProjectFileInfo?
    @State private var showDelete = false
    @State private var renameCandidate: ProjectFileInfo?
    @State private var renameName = ""
    @State private var showRename = false
    @State private var status = ""

    var body: some View {
        List {
            if files.isEmpty {
                Text("This folder is empty.")
                    .foregroundStyle(.secondary)
            }

            ForEach(files, id: \.path) { file in
                if file.isDirectory {
                    NavigationLink {
                        NexoraLocalFilesView(projectID: projectID, path: file.path)
                    } label: {
                        fileRow(file)
                    }
                    .contextMenu { fileMenu(file) }
                } else {
                    NavigationLink {
                        NexoraLocalEditorView(projectID: projectID, path: file.path)
                    } label: {
                        fileRow(file)
                    }
                    .contextMenu { fileMenu(file) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteCandidate = file
                            showDelete = true
                        } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(path.isEmpty ? "Files" : URL(fileURLWithPath: path).lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("New File") {
                        newName = ""
                        showNewFile = true
                    }
                    Button("New Folder") {
                        newName = ""
                        showNewFolder = true
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New File", isPresented: $showNewFile) {
            TextField("name.ext", text: $newName)
            Button("Create") { createFile() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("New name", text: $renameName)
            Button("Rename") { renameSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete \(deleteCandidate?.name ?? "file")?",
            isPresented: $showDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        }
        .task { reload() }
    }

    @ViewBuilder
    private func fileMenu(_ file: ProjectFileInfo) -> some View {
        Button {
            renameCandidate = file
            renameName = file.name
            showRename = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            do { _ = try model.projects.duplicatePath(projectID: projectID, path: file.path); reload() }
            catch { status = "Duplicate failed: \(error)" }
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            deleteCandidate = file
            showDelete = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ProjectFileInfo) -> some View {
        HStack {
            Image(systemName: file.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(file.isDirectory ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                if !file.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func joined(_ name: String) -> String {
        path.isEmpty ? name : path + "/" + name
    }

    private func reload() {
        do {
            files = try model.projects.listFiles(projectID: projectID, path: path)
            status = ""
        } catch {
            status = "Could not load files: \(error)"
        }
    }

    private func createFile() {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            _ = try model.projects.writeFile(
                projectID: projectID,
                path: joined(clean),
                request: .init(content: "", encoding: "utf8")
            )
            reload()
        } catch {
            status = "Could not create file: \(error)"
        }
    }

    private func createFolder() {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try model.projects.createDirectory(projectID: projectID, path: joined(clean))
            reload()
        } catch {
            status = "Could not create folder: \(error)"
        }
    }

    private func renameSelected() {
        guard let candidate = renameCandidate else { return }
        do {
            try model.projects.renamePath(projectID: projectID, path: candidate.path, newName: renameName)
            renameCandidate = nil
            reload()
        } catch {
            status = "Rename failed: \(error)"
        }
    }

    private func deleteSelected() {
        guard let candidate = deleteCandidate else { return }
        do {
            try model.projects.deleteFile(projectID: projectID, path: candidate.path)
            deleteCandidate = nil
            reload()
        } catch {
            status = "Delete failed: \(error)"
        }
    }
}

struct NexoraLocalEditorView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String
    let path: String

    @State private var content = ""
    @State private var savedContent = ""
    @State private var status = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                Spacer()
                if content != savedContent {
                    Text("Modified")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Button("Save") { save() }
                    .buttonStyle(.bordered)
                Button {
                    save()
                    let result = model.runProject(projectID)
                    status = result.output
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(8)

            if !status.isEmpty {
                Divider()
                ScrollView {
                    Text(status)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding()
                }
                .frame(maxHeight: 150)
            }
        }
        .navigationTitle(URL(fileURLWithPath: path).lastPathComponent)
        .task { load() }
    }

    private func load() {
        do {
            let file = try model.projects.readFile(projectID: projectID, path: path)
            guard file.encoding == "utf8" else {
                status = "Binary files are not editable in the text editor."
                return
            }
            content = file.content
            savedContent = file.content
        } catch {
            status = "Could not open file: \(error)"
        }
    }

    private func save() {
        do {
            _ = try model.projects.writeFile(
                projectID: projectID,
                path: path,
                request: .init(content: content, encoding: "utf8")
            )
            savedContent = content
            status = "Saved"
        } catch {
            status = "Save failed: \(error)"
        }
    }
}

struct NexoraLocalConsoleView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String

    @State private var entries: [LogEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    _ = model.restartProject(projectID)
                    refresh()
                } label: {
                    Label("Restart", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    model.stopProject(projectID)
                    refresh()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)

                Spacer()
                Button {
                    refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if entries.isEmpty {
                        Text("No console output yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(entries, id: \.id) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.level.uppercased())
                                .font(.caption2.bold())
                                .foregroundStyle(entry.level == "error" ? .red : .secondary)
                            Text(entry.message)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Console")
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func refresh() {
        entries = model.logs.recent(projectID: projectID, limit: 250)
    }
}

struct NexoraLocalDatabaseView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: String

    @State private var sql = "SELECT name, type FROM sqlite_master ORDER BY type, name;"
    @State private var output = ""
    @State private var tables: [String] = []
    @State private var selectedTable = ""
    @State private var newTableName = "notes"
    @State private var showCreateTable = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Tables").font(.headline)
                    Spacer()
                    Button { reloadTables() } label: { Image(systemName: "arrow.clockwise") }
                    Button { showCreateTable = true } label: { Image(systemName: "plus") }
                }

                if tables.isEmpty {
                    Text("No user tables yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(tables, id: \.self) { table in
                                if selectedTable == table {
                                    Button(table) {
                                        selectedTable = table
                                        loadTable(table)
                                    }
                                    .buttonStyle(.borderedProminent)
                                } else {
                                    Button(table) {
                                        selectedTable = table
                                        loadTable(table)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                Text("SQL").font(.headline)
                TextEditor(text: $sql)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Button("Run Query") { run() }
                        .buttonStyle(.borderedProminent)
                    Button("Clear Output") { output = "" }
                        .buttonStyle(.bordered)
                }

                Text("Result").font(.headline)
                ScrollView(.horizontal) {
                    Text(output.isEmpty ? "Query results appear here." : output)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120)
            }
            .padding()
        }
        .navigationTitle("SQLite")
        .alert("Create Table", isPresented: $showCreateTable) {
            TextField("Table name", text: $newTableName)
            Button("Create") { createTable() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Creates an id INTEGER PRIMARY KEY and text TEXT column. You can change the schema later with SQL.")
        }
        .task { reloadTables() }
    }

    private func reloadTables() {
        do { tables = try model.projectDB.listTables(projectID: projectID) }
        catch { output = "SQLite error: \(error)" }
    }

    private func loadTable(_ table: String) {
        do { render(try model.projectDB.rows(projectID: projectID, table: table)) }
        catch { output = "SQLite error: \(error)" }
    }

    private func createTable() {
        let clean = newTableName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            output = "Table name may only contain letters, numbers and underscore."
            return
        }
        do {
            _ = try model.projectDB.execute(projectID: projectID, sql: "CREATE TABLE IF NOT EXISTS \"\(clean)\" (id INTEGER PRIMARY KEY, text TEXT);")
            reloadTables()
            selectedTable = clean
            loadTable(clean)
        } catch { output = "SQLite error: \(error)" }
    }

    private func run() {
        do {
            render(try model.projectDB.execute(projectID: projectID, sql: sql))
            reloadTables()
        } catch { output = "SQL error: \(error)" }
    }

    private func render(_ result: SQLResult) {
        var lines: [String] = []
        if !result.columns.isEmpty { lines.append(result.columns.joined(separator: " | ")) }
        for row in result.rows {
            lines.append(result.columns.map { column in
                if let wrapped = row[column], let value = wrapped { return value }
                return "NULL"
            }.joined(separator: " | "))
        }
        lines.append("Changes: \(result.changes)")
        output = lines.joined(separator: "\n")
    }
}
