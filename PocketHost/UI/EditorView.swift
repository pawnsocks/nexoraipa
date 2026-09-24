import SwiftUI

struct EditorView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Open a project file from Projects → Files or Projects → Code. Nexora edits the real local project files instead of a disconnected scratch editor.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Section("Projects") {
                    ForEach(model.projects.list()) { project in
                        NavigationLink {
                            NexoraLocalEditorView(projectID: project.id, path: project.entrypoint)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(project.name)
                                Text(project.entrypoint)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Code")
            .task { model.refreshLocalState() }
        }
    }
}
