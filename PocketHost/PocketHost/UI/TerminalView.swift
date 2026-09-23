import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.terminalOutput)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("bottom")
                    }
                    .onChange(of: model.terminalOutput) { _, _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                HStack {
                    TextField("command", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }
                    Button("Run") { submit() }.buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Terminal")
        }
    }

    private func submit() {
        let value = command
        command = ""
        Task { await model.runCommand(value) }
    }
}
