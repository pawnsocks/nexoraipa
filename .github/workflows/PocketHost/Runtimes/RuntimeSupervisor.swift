import Foundation
import JavaScriptCore
#if canImport(LuaSwift)
import LuaSwift
#endif
#if canImport(PythonKit)
import PythonKit
#endif

final class RuntimeSupervisor: @unchecked Sendable {
    private let lock = NSLock()
    private let logs: LogBroker?
    private var javascriptSessions: [String: JSContext] = [:]
    private var pythonSessions: Set<String> = []
    #if canImport(LuaSwift)
    private var luaSessions: [String: LuaEngine] = [:]
    #endif

    init(logs: LogBroker? = nil) {
        self.logs = logs
    }

    func statuses() -> [RuntimeStatus] {
        [
            .init(id: .javascript, available: true, detail: "JavaScriptCore embedded runtime"),
            .init(id: .python, available: pythonFrameworkPresent, detail: pythonFrameworkPresent ? "CPython iOS framework + PythonKit" : "Install Vendor/Python.xcframework; adapter is wired"),
            .init(id: .lua, available: luaAvailable, detail: luaAvailable ? "Lua 5.4 embedded via LuaSwift" : "LuaSwift dependency unavailable"),
        ]
    }

    func run(kind: RuntimeKind, code: String) -> RuntimeResult {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .javascript: return runJavaScript(code, projectID: nil, keepContext: false).result
        case .python: return runPython(code, projectID: nil)
        case .lua: return runLua(code, projectID: nil, keepEngine: false).result
        }
    }

    func startProject(projectID: String, kind: RuntimeKind, code: String) -> RuntimeResult {
        lock.lock(); defer { lock.unlock() }
        stopProjectLocked(projectID: projectID)
        let result: RuntimeResult
        switch kind {
        case .javascript:
            let execution = runJavaScript(code, projectID: projectID, keepContext: true)
            if let context = execution.context, execution.result.succeeded { javascriptSessions[projectID] = context }
            result = execution.result
        case .python:
            result = runPython(code, projectID: projectID)
            if result.succeeded { pythonSessions.insert(projectID) }
        case .lua:
            let execution = runLua(code, projectID: projectID, keepEngine: true)
            #if canImport(LuaSwift)
            if let engine = execution.engine, execution.result.succeeded { luaSessions[projectID] = engine }
            #endif
            result = execution.result
        }
        logs?.append(projectID: projectID, level: result.succeeded ? "info" : "error", result.output)
        return result
    }

    func stopProject(projectID: String) {
        lock.lock(); defer { lock.unlock() }
        stopProjectLocked(projectID: projectID)
        logs?.append(projectID: projectID, "Runtime stopped")
    }

    func isProjectRunning(_ projectID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        #if canImport(LuaSwift)
        return javascriptSessions[projectID] != nil || luaSessions[projectID] != nil || pythonSessions.contains(projectID)
        #else
        return javascriptSessions[projectID] != nil || pythonSessions.contains(projectID)
        #endif
    }

    private func stopProjectLocked(projectID: String) {
        javascriptSessions[projectID] = nil
        pythonSessions.remove(projectID)
        #if canImport(LuaSwift)
        luaSessions[projectID] = nil
        #endif
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
        context.setObject(log, forKeyedSubscript: "__ph_log" as NSString)
        context.evaluateScript("var console = { log: function(x) { __ph_log(x); }, error: function(x) { __ph_log(x); } };")
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

    #if canImport(LuaSwift)
    private func runLua(_ code: String, projectID: String?, keepEngine: Bool) -> (result: RuntimeResult, engine: LuaEngine?) {
        do {
            let engine = try LuaEngine()
            let result = try engine.evaluate(code)
            let output = String(describing: result)
            if let projectID { logs?.append(projectID: projectID, output) }
            return (.init(output: output.isEmpty ? "OK" : output, succeeded: true), keepEngine ? engine : nil)
        } catch {
            return (.init(output: "Lua error: \(error.localizedDescription)", succeeded: false), nil)
        }
    }
    #else
    private func runLua(_ code: String, projectID: String?, keepEngine: Bool) -> (result: RuntimeResult, engine: AnyObject?) {
        (.init(output: "Lua runtime is not linked.", succeeded: false), nil)
    }
    #endif

    private func runPython(_ code: String, projectID: String?) -> RuntimeResult {
        #if canImport(PythonKit)
        guard let binary = pythonFrameworkBinary else {
            return .init(output: "Python.xcframework is not embedded. Run Scripts/build-cpython-ios.sh and add the generated framework to the app target.", succeeded: false)
        }
        setenv("PYTHON_LIBRARY", binary.path, 1)
        do {
            let sys = try Python.attemptImport("sys")
            let io = try Python.attemptImport("io")
            let buffer = try io.StringIO.throwing.dynamicallyCall()
            let oldOut = sys.stdout
            let oldErr = sys.stderr
            sys.stdout = buffer
            sys.stderr = buffer
            defer {
                sys.stdout = oldOut
                sys.stderr = oldErr
            }
            let execFunction = Python.builtins["exec"]
            _ = try execFunction.throwing.dynamicallyCall(withArguments: [code])
            let value = try buffer.getvalue.throwing.dynamicallyCall()
            let output = String(value) ?? "OK"
            if let projectID, !output.isEmpty { logs?.append(projectID: projectID, output) }
            return .init(output: output.isEmpty ? "OK" : output, succeeded: true)
        } catch {
            return .init(output: "Python error: \(error)", succeeded: false)
        }
        #else
        return .init(output: "PythonKit is not linked.", succeeded: false)
        #endif
    }

    private var luaAvailable: Bool {
        #if canImport(LuaSwift)
        return true
        #else
        return false
        #endif
    }

    private var pythonFrameworkPresent: Bool { pythonFrameworkBinary != nil }
    private var pythonFrameworkBinary: URL? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("Python.framework/Python"),
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/Python.framework/Python"),
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
