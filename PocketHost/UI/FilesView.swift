import SwiftUI

struct FilesView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.projects.list().isEmpty {
                    Text("Create a project first.")
                        .foregroundStyle(.secondary)
                }

                ForEach(model.projects.list()) { project in
                    NavigationLink {
                        NexoraLocalFilesView(projectID: project.id, path: "")
                    } label: {
                        VStack(alignment: .leading) {
                            Text(project.name)
                            Text(project.runtime.rawValue)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Files")
            .task { model.refreshLocalState() }
        }
    }
}
