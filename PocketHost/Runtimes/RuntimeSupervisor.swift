import Foundation
import JavaScriptCore
import Darwin
#if canImport(LuaSwift)
import LuaSwift
#endif
#if canImport(PythonKit)
import PythonKit
#endif

final class RuntimeSupervisor: @unchecked Sendable {
    private struct NodeSession {
        let stopURL: URL
        let logURL: URL
        let timer: DispatchSourceTimer
    }

    private let lock = NSLock()
    private let logs: LogBroker?
    private var javascriptSessions: [String: JSContext] = [:]
    private var pythonSessions: Set<String> = []
    private var nodeSessions: [String: NodeSession] = [:]
    private var nodeLogOffsets: [String: UInt64] = [:]
    private let nodeQueue = DispatchQueue(label: "app.nexorahost.node", qos: .userInitiated)
    private let nodeLogQueue = DispatchQueue(label: "app.nexorahost.node.logs")
    #if canImport(LuaSwift)
    private var luaSessions: [String: LuaEngine] = [:]
    #endif

    init(logs: LogBroker? = nil) {
        self.logs = logs
    }

    func statuses() -> [RuntimeStatus] {
        RuntimeKind.allCases.map { kind in
            switch kind {
            case .javascript:
                return .init(id: kind, available: true, detail: "Built-in · JavaScriptCore")
            case .node:
                return .init(
                    id: kind,
                    available: NodeMobileLoader.isAvailable,
                    detail: NodeMobileLoader.isAvailable
                        ? "Embedded · NodeMobile 24 runtime"
                        : "Unavailable · NodeMobile.framework is not bundled in this IPA"
                )
            case .python:
                return .init(
                    id: kind,
                    available: pythonFrameworkPresent,
                    detail: pythonFrameworkPresent
                        ? "Interpreter · CPython iOS framework"
                        : "Unavailable · signed Python.framework is not bundled in this IPA"
                )
            case .lua:
                return .init(
                    id: kind,
                    available: luaAvailable,
                    detail: luaAvailable ? "Interpreter · embedded Lua" : "Unavailable · LuaSwift is not linked"
                )
            case .typescript:
                return .init(
                    id: kind,
                    available: NodeMobileLoader.isAvailable,
                    detail: NodeMobileLoader.isAvailable
                        ? "Embedded · NodeMobile 24 type stripping"
                        : "Unavailable · NodeMobile.framework is not bundled in this IPA"
                )
            case .bun:
                return .init(id: kind, available: false, detail: "Not available on iOS · native Bun")
            case .docker:
                return .init(id: kind, available: false, detail: "Not available on normal iOS")
            default:
                return .init(id: kind, available: false, detail: kind.supportDescription)
            }
        }
    }

    func run(kind: RuntimeKind, code: String) -> RuntimeResult {
        lock.lock(); defer { lock.unlock() }
        switch kind {
        case .javascript:
            return runJavaScript(code, projectID: nil, keepContext: false).result
        case .python:
            return runPython(code, projectID: nil, workspaceURL: nil, entrypoint: nil)
        case .lua:
            return runLua(code, projectID: nil, keepEngine: false).result
        case .node, .typescript:
            return .init(output: "Node.js/TypeScript needs a project workspace. Run it from the project screen.", succeeded: false)
        default:
            return unavailable(kind)
        }
    }

    func startProject(
        projectID: String,
        kind: RuntimeKind,
        code: String,
        workspaceURL: URL? = nil,
        entrypoint: String? = nil
    ) -> RuntimeResult {
        if kind == .node || kind == .typescript {
            guard let workspaceURL, let entrypoint else {
                return .init(output: "Node.js project workspace is missing.", succeeded: false)
            }
            return startNodeProject(projectID: projectID, workspaceURL: workspaceURL, entrypoint: entrypoint)
        }

        lock.lock(); defer { lock.unlock() }
        stopProjectLocked(projectID: projectID)

        let result: RuntimeResult
        switch kind {
        case .javascript:
            let execution = runJavaScript(code, projectID: projectID, keepContext: true)
            if let context = execution.context, execution.result.succeeded {
                javascriptSessions[projectID] = context
            }
            result = execution.result
        case .python:
            result = runPython(code, projectID: projectID, workspaceURL: workspaceURL, entrypoint: entrypoint)
            if result.succeeded { pythonSessions.insert(projectID) }
        case .lua:
            let execution = runLua(code, projectID: projectID, keepEngine: true)
            #if canImport(LuaSwift)
            if let engine = execution.engine, execution.result.succeeded {
                luaSessions[projectID] = engine
            }
            #endif
            result = execution.result
        default:
            result = unavailable(kind)
        }

        logs?.append(projectID: projectID, level: result.succeeded ? "info" : "error", result.output)
        return result
    }

    func stopProject(projectID: String) {
        lock.lock()
        if let node = nodeSessions[projectID] {
            FileManager.default.createFile(atPath: node.stopURL.path, contents: Data())
            logs?.append(projectID: projectID, "Stop requested for Node.js runtime")
        }
        stopNonNodeProjectLocked(projectID: projectID)
        lock.unlock()
    }

    func isProjectRunning(_ projectID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        #if canImport(LuaSwift)
        return javascriptSessions[projectID] != nil
            || luaSessions[projectID] != nil
            || pythonSessions.contains(projectID)
            || nodeSessions[projectID] != nil
        #else
        return javascriptSessions[projectID] != nil
            || pythonSessions.contains(projectID)
            || nodeSessions[projectID] != nil
        #endif
    }

    private func startNodeProject(projectID: String, workspaceURL: URL, entrypoint: String) -> RuntimeResult {
        guard NodeMobileLoader.isAvailable else {
            return .init(output: "NodeMobile.framework is missing from this IPA.", succeeded: false)
        }

        let entryURL = workspaceURL.appendingPathComponent(entrypoint)
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            return .init(output: "Node.js entry point not found: \(entrypoint)", succeeded: false)
        }

        lock.lock()
        if !nodeSessions.isEmpty && nodeSessions[projectID] == nil {
            lock.unlock()
            return .init(output: "Only one embedded Node.js project can run at a time on this iOS build.", succeeded: false)
        }
        stopNonNodeProjectLocked(projectID: projectID)

        let meta = workspaceURL.appendingPathComponent(".nexora", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        } catch {
            lock.unlock()
            return .init(output: "Could not prepare Node runtime folder: \(error.localizedDescription)", succeeded: false)
        }

        let stopURL = meta.appendingPathComponent("node.stop")
        let logURL = meta.appendingPathComponent("node.log")
        let bootstrapURL = meta.appendingPathComponent("node-bootstrap.cjs")
        try? FileManager.default.removeItem(at: stopURL)
        try? Data().write(to: logURL, options: .atomic)

        let bootstrap = NodeMobileLoader.bootstrapScript(
            workspacePath: workspaceURL.path,
            entrypoint: entrypoint,
            logPath: logURL.path,
            stopPath: stopURL.path
        )
        do {
            try Data(bootstrap.utf8).write(to: bootstrapURL, options: .atomic)
        } catch {
            lock.unlock()
            return .init(output: "Could not write Node bootstrap: \(error.localizedDescription)", succeeded: false)
        }

        let timer = DispatchSource.makeTimerSource(queue: nodeLogQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.tailNodeLog(projectID: projectID, logURL: logURL)
        }
        nodeLogOffsets[projectID] = 0
        nodeSessions[projectID] = NodeSession(stopURL: stopURL, logURL: logURL, timer: timer)
        timer.resume()
        lock.unlock()

        logs?.append(projectID: projectID, "Starting embedded Node.js: \(entrypoint)")
        nodeQueue.async { [weak self] in
            let exitCode = NodeMobileLoader.run(scriptURL: bootstrapURL)
            self?.finishNodeProject(projectID: projectID, exitCode: exitCode)
        }

        return .init(output: "Node.js started locally. Console output will appear in the project console.", succeeded: true)
    }

    private func finishNodeProject(projectID: String, exitCode: Int32) {
        lock.lock()
        let logURL = nodeSessions[projectID]?.logURL
        lock.unlock()
        tailNodeLog(projectID: projectID, logURL: logURL)
        lock.lock()
        if let session = nodeSessions.removeValue(forKey: projectID) {
            session.timer.cancel()
        }
        nodeLogOffsets.removeValue(forKey: projectID)
        lock.unlock()
        logs?.append(
            projectID: projectID,
            level: exitCode == 0 ? "info" : "error",
            "Node.js exited with code \(exitCode)"
        )
    }

    private func tailNodeLog(projectID: String, logURL: URL?) {
        guard let logURL else { return }
        lock.lock()
        let offset = nodeLogOffsets[projectID] ?? 0
        lock.unlock()

        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            guard !data.isEmpty else { return }
            let next = offset + UInt64(data.count)
            lock.lock(); nodeLogOffsets[projectID] = next; lock.unlock()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                logs?.append(projectID: projectID, String(line))
            }
        } catch {
            return
        }
    }

    private func stopProjectLocked(projectID: String) {
        if let node = nodeSessions[projectID] {
            FileManager.default.createFile(atPath: node.stopURL.path, contents: Data())
        }
        stopNonNodeProjectLocked(projectID: projectID)
    }

    private func stopNonNodeProjectLocked(projectID: String) {
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
        if lines.isEmpty, let value, !value.isUndefined {
            lines.append(value.toString() ?? "undefined")
        }
        return (.init(output: lines.isEmpty ? "OK" : lines.joined(separator: "\n"), succeeded: true), keepContext ? context : nil)
    }

    #if canImport(LuaSwift)
    private func runLua(_ code: String, projectID: String?, keepEngine: Bool) -> (result: RuntimeResult, engine: LuaEngine?) {
        do {
            let engine = try LuaEngine()
            let value = try engine.evaluate(code)
            let output = String(describing: value)
            if let projectID, !output.isEmpty { logs?.append(projectID: projectID, output) }
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

    private func runPython(
        _ code: String,
        projectID: String?,
        workspaceURL: URL?,
        entrypoint: String?
    ) -> RuntimeResult {
        #if canImport(PythonKit)
        guard let binary = pythonFrameworkBinary else {
            return .init(output: "Python.framework is not bundled in this IPA.", succeeded: false)
        }

        setenv("PYTHON_LIBRARY", binary.path, 1)
        let pythonHome = Bundle.main.bundleURL.appendingPathComponent("python", isDirectory: true)
        if FileManager.default.fileExists(atPath: pythonHome.path) {
            setenv("PYTHONHOME", pythonHome.path, 1)
        }

        do {
            let sys = try Python.attemptImport("sys")
            let io = try Python.attemptImport("io")
            let os = try Python.attemptImport("os")
            let buffer = io.StringIO()
            let oldOut = sys.stdout
            let oldErr = sys.stderr
            let oldCwd = os.getcwd()
            sys.stdout = buffer
            sys.stderr = buffer

            if let workspaceURL {
                _ = os.chdir(workspaceURL.path)
                _ = sys.path.insert(0, workspaceURL.path)
            }

            defer {
                sys.stdout = oldOut
                sys.stderr = oldErr
                _ = os.chdir(oldCwd)
            }

            let globals = Python.dict()
            globals["__name__"] = "__main__"
            globals["__file__"] = PythonObject(entrypoint ?? "<nexora>")
            let compiled = Python.builtins.compile(code, entrypoint ?? "<nexora>", "exec")
            _ = Python.builtins.exec(compiled, globals, globals)
            let value = buffer.getvalue()
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

    private func unavailable(_ kind: RuntimeKind) -> RuntimeResult {
        .init(
            output: "\(kind.rawValue) local execution is not implemented on this iOS build. Editor support does not mean runtime support.",
            succeeded: false
        )
    }

    private var luaAvailable: Bool {
        #if canImport(LuaSwift)
        return true
        #else
        return false
        #endif
    }

    private var pythonFrameworkPresent: Bool {
        guard pythonFrameworkBinary != nil else { return false }
        let lib = Bundle.main.bundleURL.appendingPathComponent("python/lib", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(at: lib, includingPropertiesForKeys: nil) else { return false }
        return entries.contains { $0.lastPathComponent.hasPrefix("python3.") }
    }

    private var pythonFrameworkBinary: URL? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("Python.framework/Python"),
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/Python.framework/Python")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

private enum NodeMobileLoader {
    typealias NodeStart = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32

    static var frameworkBinary: URL? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("NodeMobile.framework/NodeMobile"),
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/NodeMobile.framework/NodeMobile")
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var isAvailable: Bool {
        guard let binary = frameworkBinary,
              let handle = dlopen(binary.path, RTLD_LAZY | RTLD_LOCAL) else { return false }
        defer { dlclose(handle) }
        return dlsym(handle, "node_start") != nil
    }

    static func run(scriptURL: URL) -> Int32 {
        guard let binary = frameworkBinary else { return -100 }
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_GLOBAL) else { return -101 }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "node_start") else { return -102 }
        let start = unsafeBitCast(symbol, to: NodeStart.self)

        let arguments = ["node", scriptURL.path]
        let duplicated: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { duplicated.forEach { if let pointer = $0 { free(pointer) } } }
        var argv = duplicated
        return argv.withUnsafeMutableBufferPointer { buffer in
            start(Int32(arguments.count), buffer.baseAddress)
        }
    }

    static func bootstrapScript(workspacePath: String, entrypoint: String, logPath: String, stopPath: String) -> String {
        func js(_ value: String) -> String {
            let data = try? JSONSerialization.data(withJSONObject: [value])
            guard let data, let json = String(data: data, encoding: .utf8), json.count >= 4 else { return "\"\"" }
            return String(json.dropFirst().dropLast())
        }

        return """
        const fs = require('fs');
        const path = require('path');
        const zlib = require('zlib');
        const Module = require('module');
        const { pathToFileURL } = require('url');
        const workspace = \(js(workspacePath));
        const entrypoint = \(js(entrypoint));
        const logPath = \(js(logPath));
        const stopPath = \(js(stopPath));
        process.chdir(workspace);

        function render(value) {
          if (typeof value === 'string') return value;
          try { return JSON.stringify(value); } catch (_) { return String(value); }
        }
        function write(level, values) {
          const line = '[' + level + '] ' + values.map(render).join(' ') + '\\n';
          try { fs.appendFileSync(logPath, line); } catch (_) {}
        }
        console.log = (...args) => write('log', args);
        console.info = (...args) => write('info', args);
        console.warn = (...args) => write('warn', args);
        console.error = (...args) => write('error', args);
        process.on('uncaughtException', error => {
          write('error', [error && error.stack ? error.stack : error]);
          process.exitCode = 1;
        });
        process.on('unhandledRejection', error => {
          write('error', [error && error.stack ? error.stack : error]);
        });

        const stopTimer = setInterval(() => {
          if (fs.existsSync(stopPath)) {
            try { fs.unlinkSync(stopPath); } catch (_) {}
            write('info', ['Nexora stop requested']);
            process.exit(0);
          }
        }, 400);
        if (stopTimer.unref) stopTimer.unref();

        const builtins = new Set(Module.builtinModules.map(x => x.replace(/^node:/, '')));
        const installSeen = new Set();
        let installCount = 0;

        function packageNameFromImport(value) {
          const clean = value.replace(/^node:/, '');
          if (builtins.has(clean)) return null;
          if (clean.startsWith('.') || clean.startsWith('/') || clean.startsWith('file:')) return null;
          if (clean.startsWith('@')) return clean.split('/').slice(0, 2).join('/');
          return clean.split('/')[0];
        }

        function importedPackages(source) {
          const found = new Set();
          const patterns = [
            /require\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)/g,
            /from\\s+['\"]([^'\"]+)['\"]/g,
            /import\\s*\\(\\s*['\"]([^'\"]+)['\"]\\s*\\)/g,
            /import\\s+['\"]([^'\"]+)['\"]/g
          ];
          for (const regex of patterns) {
            let match;
            while ((match = regex.exec(source)) !== null) {
              const name = packageNameFromImport(match[1]);
              if (name) found.add(name);
            }
          }
          return [...found];
        }

        function parts(version) {
          const clean = String(version || '').replace(/^v/, '').split('-')[0];
          const values = clean.split('.').map(x => Number.parseInt(x, 10) || 0);
          return [values[0] || 0, values[1] || 0, values[2] || 0];
        }
        function compareVersion(a, b) {
          const x = parts(a), y = parts(b);
          for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i];
          return 0;
        }
        function satisfies(version, range) {
          if (!range || range === '*' || range === 'latest') return true;
          const r = String(range).trim();
          if (r.includes('||')) return r.split('||').some(x => satisfies(version, x.trim()));
          if (/^\\d+\\.x$/i.test(r)) return parts(version)[0] === Number(r.split('.')[0]);
          if (/^\\d+\\.\\d+\\.x$/i.test(r)) {
            const a = parts(version), b = parts(r.replace(/x/i, '0'));
            return a[0] === b[0] && a[1] === b[1];
          }
          if (r.startsWith('^')) {
            const a = parts(version), b = parts(r.slice(1));
            if (b[0] > 0) return a[0] === b[0] && compareVersion(version, r.slice(1)) >= 0;
            if (b[1] > 0) return a[0] === 0 && a[1] === b[1] && compareVersion(version, r.slice(1)) >= 0;
            return a[0] === 0 && a[1] === 0 && a[2] === b[2];
          }
          if (r.startsWith('~')) {
            const a = parts(version), b = parts(r.slice(1));
            return a[0] === b[0] && a[1] === b[1] && compareVersion(version, r.slice(1)) >= 0;
          }
          if (/^\\d+\\.\\d+\\.\\d+/.test(r)) return compareVersion(version, r.match(/^\\d+\\.\\d+\\.\\d+/)[0]) === 0;
          if (r.startsWith('>=')) return compareVersion(version, r.slice(2).trim().split(/\\s/)[0]) >= 0;
          return true;
        }

        async function fetchJSON(url) {
          const response = await fetch(url, { headers: { 'User-Agent': 'Nexora-Host' } });
          if (!response.ok) throw new Error('HTTP ' + response.status + ' for ' + url);
          return await response.json();
        }

        async function resolvePackage(name, range) {
          const metadata = await fetchJSON('https://registry.npmjs.org/' + encodeURIComponent(name));
          if (metadata['dist-tags'] && metadata['dist-tags'][range]) {
            const v = metadata['dist-tags'][range];
            return { metadata, version: v, info: metadata.versions[v] };
          }
          const versions = Object.keys(metadata.versions || {})
            .filter(v => !v.includes('-') && satisfies(v, range))
            .sort(compareVersion);
          const version = versions[versions.length - 1] || (metadata['dist-tags'] || {}).latest;
          if (!version || !metadata.versions[version]) throw new Error('No compatible version for ' + name + '@' + range);
          return { metadata, version, info: metadata.versions[version] };
        }

        function safeTarget(base, relative) {
          const normalized = relative.replace(/^package\\//, '').replace(/\\\\/g, '/');
          if (!normalized || normalized.startsWith('/') || normalized.split('/').includes('..')) return null;
          const target = path.resolve(base, normalized);
          const root = path.resolve(base) + path.sep;
          if (target !== path.resolve(base) && !target.startsWith(root)) return null;
          return target;
        }

        function extractTGZ(buffer, destination) {
          const tar = zlib.gunzipSync(buffer);
          let offset = 0;
          while (offset + 512 <= tar.length) {
            const header = tar.subarray(offset, offset + 512);
            if (header.every(byte => byte === 0)) break;
            const name = header.subarray(0, 100).toString('utf8').replace(/\\0.*$/, '');
            const prefix = header.subarray(345, 500).toString('utf8').replace(/\\0.*$/, '');
            const fullName = prefix ? prefix + '/' + name : name;
            const sizeText = header.subarray(124, 136).toString('ascii').replace(/\\0.*$/, '').trim();
            const size = Number.parseInt(sizeText || '0', 8) || 0;
            const type = String.fromCharCode(header[156] || 48);
            const dataStart = offset + 512;
            const dataEnd = dataStart + size;
            const target = safeTarget(destination, fullName);
            if (target && (type === '0' || type === '\\0')) {
              fs.mkdirSync(path.dirname(target), { recursive: true });
              fs.writeFileSync(target, tar.subarray(dataStart, dataEnd));
            } else if (target && type === '5') {
              fs.mkdirSync(target, { recursive: true });
            }
            offset = dataStart + Math.ceil(size / 512) * 512;
          }
        }

        async function installPackage(name, range = 'latest') {
          const key = name + '@' + range;
          if (installSeen.has(key)) return;
          installSeen.add(key);
          if (++installCount > 160) throw new Error('Dependency limit exceeded');

          const target = path.join(workspace, 'node_modules', ...name.split('/'));
          const packageFile = path.join(target, 'package.json');
          if (fs.existsSync(packageFile)) return;

          write('info', ['Installing', name + '@' + range]);
          const resolved = await resolvePackage(name, range);
          const tarball = resolved.info && resolved.info.dist && resolved.info.dist.tarball;
          if (!tarball) throw new Error('No tarball for ' + name + '@' + resolved.version);
          const response = await fetch(tarball, { headers: { 'User-Agent': 'Nexora-Host' } });
          if (!response.ok) throw new Error('Download failed ' + response.status + ' for ' + name);
          const bytes = Buffer.from(await response.arrayBuffer());
          fs.rmSync(target, { recursive: true, force: true });
          fs.mkdirSync(target, { recursive: true });
          extractTGZ(bytes, target);

          const installed = JSON.parse(fs.readFileSync(packageFile, 'utf8'));
          const dependencies = Object.assign({}, installed.dependencies || {}, installed.optionalDependencies || {});
          for (const [child, childRange] of Object.entries(dependencies)) {
            try { await installPackage(child, String(childRange)); }
            catch (error) {
              if ((installed.optionalDependencies || {})[child] !== undefined) {
                write('warn', ['Optional dependency skipped', child, String(error)]);
              } else {
                throw error;
              }
            }
          }
        }

        async function ensureDependencies() {
          const desired = {};
          const packagePath = path.join(workspace, 'package.json');
          if (fs.existsSync(packagePath)) {
            const pkg = JSON.parse(fs.readFileSync(packagePath, 'utf8'));
            Object.assign(desired, pkg.dependencies || {}, pkg.optionalDependencies || {});
          }
          const entryPath = path.resolve(workspace, entrypoint);
          if (fs.existsSync(entryPath)) {
            const source = fs.readFileSync(entryPath, 'utf8');
            for (const name of importedPackages(source)) if (!desired[name]) desired[name] = 'latest';
          }
          const entries = Object.entries(desired);
          if (!entries.length) return;
          fs.mkdirSync(path.join(workspace, 'node_modules'), { recursive: true });
          for (const [name, range] of entries) await installPackage(name, String(range));
          write('info', ['Dependencies ready']);
        }

        (async () => {
          try {
            await ensureDependencies();
            const target = path.resolve(workspace, entrypoint);
            await import(pathToFileURL(target).href);
          } catch (error) {
            write('error', [error && error.stack ? error.stack : error]);
            process.exitCode = 1;
          }
        })();
        """
    }
}
