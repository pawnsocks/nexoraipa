import SwiftUI

struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var name = ""
    @State private var runtime: RuntimeKind = .javascript
    @State private var projects: [ProjectRecord] = []
    @State private var errorText = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Create") {
                    TextField("Project name", text: $name)
                    Picker("Runtime", selection: $runtime) { ForEach(RuntimeKind.allCases) { Text($0.rawValue).tag($0) } }
                    Button("Create project") {
                        do { _ = try model.projects.create(name: name, runtime: runtime, entrypoint: nil); name = ""; refresh() }
                        catch { errorText = "Could not create project" }
                    }
                }
                Section("Projects") {
                    ForEach(projects) { project in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(project.name).font(.headline); Spacer(); Text(project.state.rawValue).font(.caption).foregroundStyle(.secondary) }
                            Text("\(project.runtime.rawValue) · \(project.entrypoint)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !errorText.isEmpty { Text(errorText).foregroundStyle(.red) }
            }
            .navigationTitle("Projects")
            .task { refresh() }
        }
    }
    private func refresh() { projects = model.projects.list() }
}
