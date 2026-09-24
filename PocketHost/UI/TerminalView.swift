import SwiftUI

struct TerminalView: View {
    @EnvironmentObject private var model: AppModel
    @State private var command = ""

    private let helperKeys = ["ESC", "CTRL", "TAB", "↑", "↓", "←", "→", "/", "|", "-", "_", "~", "{", "}", "[", "]"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.terminalOutput)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("bottom")
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.terminalOutput) { _ in
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(helperKeys, id: \.self) { key in
                            Button(key) {
                                if ["ESC", "CTRL", "TAB", "↑", "↓", "←", "→"].contains(key) { return }
                                command += key
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                HStack {
                    TextField("local command", text: $command)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.body, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { submit() }

                    Button("Run") { submit() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Console")
        }
    }

    private func submit() {
        let value = command
        command = ""
        Task { await model.runCommand(value) }
    }
}
