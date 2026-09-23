import Foundation
import JavaScriptCore

// Legacy/local supervisor retained only for lightweight JavaScript snippets and
// compatibility with the existing Xcode target. Nexora project execution is
// remote-first and happens on the configured Debian backend.
final class RuntimeSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private let logs: LogBroker?
    private var javascriptSessions: [String: JSContext] = [:]

    init(logs: LogBroker? = nil) {
        self.logs = logs
    }

    func statuses() -> [RuntimeStatus] {
        RuntimeKind.allCases.map { kind in
            if kind == .javascript {
                return .init(id: kind, available: true, detail: "Editor snippets only · project servers run remotely")
            }
            return .init(id: kind, available: false, detail: "Remote backend runtime · not executed on iPhone")
        }
    }

    func run(kind: RuntimeKind, code: String) -> RuntimeResult {
        lock.lock(); defer { lock.unlock() }
        guard kind == .javascript else { return unavailable(kind) }
        return runJavaScript(code, projectID: nil, keepContext: false).result
    }

    func startProject(projectID: String, kind: RuntimeKind, code: String) -> RuntimeResult {
        lock.lock(); defer { lock.unlock() }
        guard kind == .javascript else { return unavailable(kind) }
        let execution = runJavaScript(code, projectID: projectID, keepContext: true)
        if let context = execution.context, execution.result.succeeded {
            javascriptSessions[projectID] = context
        }
        logs?.append(projectID: projectID, level: execution.result.succeeded ? "info" : "error", execution.result.output)
        return execution.result
    }

    func stopProject(projectID: String) {
        lock.lock(); defer { lock.unlock() }
        javascriptSessions[projectID] = nil
        logs?.append(projectID: projectID, "Local snippet context stopped")
    }

    func isProjectRunning(_ projectID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return javascriptSessions[projectID] != nil
    }

    private func runJavaScript(_ code: String, projectID: String?, keepContext: Bool) -> (result: RuntimeResult, context: JSContext?) {
        guard let context = JSContext() else {
            return (.init(output: "Could not create JavaScript context.", succeeded: false), nil)
        }
        var lines: [String] = []
        let log: @convention(block) (JSValue) -> Void = { [weak self] value in
            let text = value.toString() ?? "undefined"
            lines.append(text)
            if let projectID { self?.logs?.append(projectID: projectID, text) }
        }
        context.setObject(log, forKeyedSubscript: "__nexora_log" as NSString)
        context.evaluateScript("var console = { log: function(x) { __nexora_log(x); }, error: function(x) { __nexora_log(x); } };")
        context.exceptionHandler = { [weak self] _, exception in
            if let text = exception?.toString() {
                lines.append("Error: \(text)")
                if let projectID { self?.logs?.append(projectID: projectID, level: "error", text) }
            }
        }
        let value = context.evaluateScript(code)
        if let exception = context.exception, !exception.isUndefined {
            return (.init(output: lines.joined(separator: "\n"), succeeded: false), keepContext ? context : nil)
        }
        if lines.isEmpty, let value, !value.isUndefined { lines.append(value.toString() ?? "undefined") }
        return (.init(output: lines.isEmpty ? "OK" : lines.joined(separator: "\n"), succeeded: true), keepContext ? context : nil)
    }

    private func unavailable(_ kind: RuntimeKind) -> RuntimeResult {
        .init(output: "\(kind.rawValue) project execution runs on the Nexora Host backend. Configure it in Settings.", succeeded: false)
    }
}
