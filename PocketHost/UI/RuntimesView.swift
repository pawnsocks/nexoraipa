import SwiftUI

struct RuntimesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        List {
            if !available.isEmpty {
                Section("Available on this IPA") {
                    ForEach(available) { runtime in row(runtime) }
                }
            }
            if !unavailable.isEmpty {
                Section("Not embedded / not supported") {
                    ForEach(unavailable) { runtime in row(runtime) }
                }
            }
        }
        .searchable(text: $query, prompt: "Search runtimes")
        .navigationTitle("Runtimes")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { model.refreshLocalState() } label: { Image(systemName: "arrow.clockwise") }
            }
        }
        .task { model.refreshLocalState() }
    }

    @ViewBuilder
    private func row(_ runtime: RuntimeStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: runtime.available ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(runtime.available ? .green : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(runtime.id.rawValue).font(.headline)
                    Spacer()
                    Text(runtime.available ? "Available" : "Unavailable")
                        .font(.caption2.bold())
                        .foregroundStyle(runtime.available ? .green : .secondary)
                }
                Text(runtime.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var filtered: [RuntimeStatus] {
        guard !query.isEmpty else { return model.runtimeStatuses }
        return model.runtimeStatuses.filter {
            $0.id.rawValue.localizedCaseInsensitiveContains(query)
            || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var available: [RuntimeStatus] { filtered.filter(\.available) }
    private var unavailable: [RuntimeStatus] { filtered.filter { !$0.available } }
}
