import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var runtimes: [RemoteRuntimeInfo] = []
    @State private var query = ""
    @State private var status = ""

    var body: some View {
        List {
            Section("Execution model") {
                Text("Nexora Host runs project runtimes on your Debian backend or isolated workers. The iPhone is the controller/editor and does not compile or host project servers locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !installed.isEmpty {
                Section("Installed on backend") {
                    ForEach(installed) { runtimeRow($0) }
                }
            }

            Section("Runtime catalog") {
                ForEach(catalog) { kind in
                    HStack(spacing: 12) {
                        Image(systemName: "cloud")
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(kind.rawValue)
                                .font(.headline)
                            Text(kind.supportDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let remote = runtimes.first(where: { $0.name.caseInsensitiveCompare(kind.rawValue) == .orderedSame || RuntimeKind.apiValue($0.name) == kind }) {
                            Text(remote.installed ? (remote.version ?? "Ready") : "Missing")
                                .font(.caption2)
                                .foregroundStyle(remote.installed ? .green : .secondary)
                        } else {
                            Text("Detect")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
        .searchable(text: $query, prompt: "Search languages")
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .task { await refresh() }
    }

    private var installed: [RemoteRuntimeInfo] {
        runtimes.filter { $0.installed && matches($0.name) }
    }

    private var catalog: [RuntimeKind] {
        RuntimeKind.allCases.filter { query.isEmpty || $0.rawValue.localizedCaseInsensitiveContains(query) }
    }

    private func runtimeRow(_ item: RemoteRuntimeInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.installed ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(item.installed ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                Text(item.command + (item.version.map { " · \($0)" } ?? ""))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func matches(_ value: String) -> Bool {
        query.isEmpty || value.localizedCaseInsensitiveContains(query)
    }

    private func refresh() async {
        guard model.remote.isConfigured else {
            status = "Configure backend in Settings"
            return
        }
        do {
            runtimes = try await model.remote.listRuntimes()
            status = "Detected \(runtimes.filter(\.installed).count) installed runtimes"
        } catch {
            status = error.localizedDescription
        }
    }
}
