import SwiftUI

struct FilesView: View {
    @State private var files: [URL] = []

    var body: some View {
        NavigationStack {
            List(files, id: \.path) { file in
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.lastPathComponent)
                    Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .overlay {
                if files.isEmpty { ContentUnavailableView("No files", systemImage: "folder") }
            }
            .navigationTitle("Files")
            .toolbar { Button("Refresh") { reload() } }
            .onAppear { reload() }
        }
    }

    private func reload() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    }
}
