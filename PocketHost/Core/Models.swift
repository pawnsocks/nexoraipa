import Foundation

struct MetricsSnapshot: Sendable, Equatable, Codable {
    var residentMemoryMB: Double = 0
    var cpuPercent: Double = 0
    var thermal: String = "Nominal"
    var batteryPercent: Int = 0
    var isCharging: Bool = false
    var requestsPerSecond: Double = 0
    var keyValueCount: Int = 0
    var timestamp: Date = .now
    var lowPowerMode: Bool = false
    var processorCount: Int = 1
    var physicalMemoryMB: Double = 0
    var deviceClass: String = "Apple device"
}

enum TuneProfile: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "Auto"
    case performance = "Performance"
    case balanced = "Balanced"
    case batterySaver = "Battery Saver"

    var id: String { rawValue }
}

struct TunedPolicy: Sendable, Equatable, Codable {
    var workerLimit: Int
    var cacheLimitMB: Int
    var tickIntervalMS: Int
    var suspendIdleRuntimes: Bool
    var note: String
    var previewFPS: Int = 60
    var indexingMode: String = "Normal"
    var runtimeMemoryTargetMB: Int = 384
}

enum RuntimeSupportMode: String, Sendable, Codable {
    case builtIn = "Built-in"
    case interpreter = "Interpreter"
    case wasmPack = "WASM pack"
    case experimental = "Experimental"
    case unavailable = "Not available on iOS"

    var symbol: String {
        switch self {
        case .builtIn: return "checkmark.seal.fill"
        case .interpreter: return "shippingbox.fill"
        case .wasmPack: return "cube.transparent"
        case .experimental: return "flask"
        case .unavailable: return "nosign"
        }
    }
}

enum RuntimeKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case javascript = "JavaScript"
    case node = "Node.js"
    case bun = "Bun"
    case typescript = "TypeScript"
    case python = "Python"
    case lua = "Lua"
    case ruby = "Ruby"
    case php = "PHP"
    case perl = "Perl"
    case tcl = "Tcl"
    case scheme = "Scheme"
    case prolog = "Prolog"
    case shell = "Bash / Zsh"
    case c = "C"
    case cpp = "C++"
    case rust = "Rust"
    case go = "Go"
    case zig = "Zig"
    case kotlinNative = "Kotlin/Native"
    case dart = "Dart"
    case csharp = "C#"
    case java = "Java"
    case dotnet = ".NET"
    case docker = "Docker"
    case julia = "Julia"
    case haskell = "Haskell"
    case elixir = "Elixir"
    case erlang = "Erlang"
    case clojure = "Clojure"
    case ocaml = "OCaml"
    case nim = "Nim"
    case crystal = "Crystal"
    case scala = "Scala"
    case r = "R"
    case fortran = "Fortran"
    case cobol = "COBOL"
    case v = "V"
    case groovy = "Groovy"
    case wren = "Wren"

    var id: String { rawValue }

    static func apiValue(_ raw: String) -> RuntimeKind? {
        let key = raw.lowercased().replacingOccurrences(of: " ", with: "")
        switch key {
        case "javascript", "js": return .javascript
        case "node", "nodejs", "node.js": return .node
        case "bun": return .bun
        case "typescript", "ts": return .typescript
        case "python", "py": return .python
        case "lua": return .lua
        case "ruby", "rb": return .ruby
        case "php": return .php
        case "perl", "pl": return .perl
        case "tcl": return .tcl
        case "scheme", "scm": return .scheme
        case "prolog": return .prolog
        case "bash", "zsh", "shell", "bash/zsh": return .shell
        case "c": return .c
        case "c++", "cpp", "cxx": return .cpp
        case "rust", "rs": return .rust
        case "go", "golang": return .go
        case "zig": return .zig
        case "kotlin/native", "kotlinnative", "kotlin": return .kotlinNative
        case "dart": return .dart
        case "c#", "csharp", "cs": return .csharp
        case "java", "jdk": return .java
        case "dotnet", ".net": return .dotnet
        case "docker", "compose": return .docker
        case "julia", "jl": return .julia
        case "haskell", "hs": return .haskell
        case "elixir", "ex": return .elixir
        case "erlang", "erl": return .erlang
        case "clojure", "clj": return .clojure
        case "ocaml", "ml": return .ocaml
        case "nim": return .nim
        case "crystal", "cr": return .crystal
        case "scala": return .scala
        case "r": return .r
        case "fortran", "f90": return .fortran
        case "cobol", "cbl": return .cobol
        case "v": return .v
        case "groovy": return .groovy
        case "wren": return .wren
        default: return RuntimeKind.allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
        }
    }

    var defaultEntrypoint: String {
        switch self {
        case .javascript, .node: return "index.js"
        case .bun, .typescript: return "index.ts"
        case .python: return "main.py"
        case .lua: return "main.lua"
        case .ruby: return "main.rb"
        case .php: return "index.php"
        case .perl: return "main.pl"
        case .tcl: return "main.tcl"
        case .scheme: return "main.scm"
        case .prolog: return "main.pl"
        case .shell: return "run.sh"
        case .c: return "main.c"
        case .cpp: return "main.cpp"
        case .rust: return "main.rs"
        case .go: return "main.go"
        case .zig: return "main.zig"
        case .kotlinNative: return "main.kt"
        case .dart: return "main.dart"
        case .csharp, .dotnet: return "Program.cs"
        case .java: return "Main.java"
        case .docker: return "compose.yaml"
        case .julia: return "main.jl"
        case .haskell: return "Main.hs"
        case .elixir: return "main.exs"
        case .erlang: return "main.erl"
        case .clojure: return "main.clj"
        case .ocaml: return "main.ml"
        case .nim: return "main.nim"
        case .crystal: return "main.cr"
        case .scala: return "Main.scala"
        case .r: return "main.R"
        case .fortran: return "main.f90"
        case .cobol: return "main.cob"
        case .v: return "main.v"
        case .groovy: return "main.groovy"
        case .wren: return "main.wren"
        }
    }

    var supportMode: RuntimeSupportMode {
        switch self {
        case .javascript, .node, .typescript: return .builtIn
        case .python, .lua: return .interpreter
        case .c, .cpp, .rust, .go, .zig, .haskell, .ocaml, .nim, .fortran, .cobol, .v, .wren:
            return .wasmPack
        default:
            return .unavailable
        }
    }

    var supportDescription: String {
        switch self {
        case .javascript:
            return "Runs locally with JavaScriptCore."
        case .python:
            return "Runs locally only when the signed CPython iOS framework is bundled."
        case .lua:
            return "Runs locally with the embedded Lua interpreter when LuaSwift is linked."
        case .typescript:
            return "Runs locally through embedded NodeMobile 24 using Node's built-in type stripping."
        case .node:
            return "Runs locally with embedded NodeMobile 24 when the framework is bundled."
        case .bun:
            return "Native desktop Bun is not available on normal iOS."
        case .docker:
            return "Docker is not available on normal iOS."
        case .c, .cpp, .rust, .go, .zig, .haskell, .ocaml, .nim, .fortran, .cobol, .v, .wren:
            return "Potential WASM/WASI path. Execution remains unavailable until a compatible runtime pack is genuinely installed."
        default:
            return "Editor support only right now. Nexora does not claim local execution for this runtime."
        }
    }

    var starterSource: String {
        switch self {
        case .javascript: return "console.log('Hello from Nexora Host');\n"
        case .node: return "console.log('Hello from Node.js on Nexora Host');\n"
        case .bun: return "console.log('Bun is not a local Nexora runtime on iOS.');\n"
        case .typescript: return "const message: string = 'Hello from Nexora Host';\nconsole.log(message);\n"
        case .python: return "print('Hello from Nexora Host')\n"
        case .lua: return "print('Hello from Nexora Host')\n"
        case .ruby: return "puts 'Hello from Nexora Host'\n"
        case .php: return "<?php\necho \"Hello from Nexora Host\\n\";\n"
        case .perl: return "print \"Hello from Nexora Host\\n\";\n"
        case .tcl: return "puts \"Hello from Nexora Host\"\n"
        case .scheme: return "(display \"Hello from Nexora Host\")\n(newline)\n"
        case .prolog: return ":- initialization(main).\nmain :- writeln('Hello from Nexora Host').\n"
        case .shell: return "echo \"Hello from Nexora Host\"\n"
        case .c: return "#include <stdio.h>\nint main(void) { puts(\"Hello from Nexora Host\"); return 0; }\n"
        case .cpp: return "#include <iostream>\nint main() { std::cout << \"Hello from Nexora Host\\n\"; }\n"
        case .rust: return "fn main() { println!(\"Hello from Nexora Host\"); }\n"
        case .go: return "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"Hello from Nexora Host\") }\n"
        case .zig: return "const std = @import(\"std\");\npub fn main() !void { try std.io.getStdOut().writer().print(\"Hello from Nexora Host\\n\", .{}); }\n"
        case .kotlinNative: return "fun main() { println(\"Hello from Nexora Host\") }\n"
        case .dart: return "void main() { print('Hello from Nexora Host'); }\n"
        case .csharp, .dotnet: return "System.Console.WriteLine(\"Hello from Nexora Host\");\n"
        case .java: return "public class Main { public static void main(String[] args) { System.out.println(\"Hello from Nexora Host\"); } }\n"
        case .docker: return "# Docker is unavailable on normal iOS.\n"
        case .julia: return "println(\"Hello from Nexora Host\")\n"
        case .haskell: return "main = putStrLn \"Hello from Nexora Host\"\n"
        case .elixir: return "IO.puts(\"Hello from Nexora Host\")\n"
        case .erlang: return "-module(main).\n-export([main/0]).\nmain() -> io:format(\"Hello from Nexora Host~n\").\n"
        case .clojure: return "(println \"Hello from Nexora Host\")\n"
        case .ocaml: return "print_endline \"Hello from Nexora Host\"\n"
        case .nim: return "echo \"Hello from Nexora Host\"\n"
        case .crystal: return "puts \"Hello from Nexora Host\"\n"
        case .scala: return "@main def main() = println(\"Hello from Nexora Host\")\n"
        case .r: return "cat(\"Hello from Nexora Host\\n\")\n"
        case .fortran: return "program main\n  print *, \"Hello from Nexora Host\"\nend program main\n"
        case .cobol: return "IDENTIFICATION DIVISION.\nPROGRAM-ID. MAIN.\nPROCEDURE DIVISION.\n    DISPLAY 'Hello from Nexora Host'.\n    STOP RUN.\n"
        case .v: return "fn main() { println('Hello from Nexora Host') }\n"
        case .groovy: return "println 'Hello from Nexora Host'\n"
        case .wren: return "System.print(\"Hello from Nexora Host\")\n"
        }
    }
}

struct RuntimeStatus: Identifiable, Sendable, Equatable, Codable {
    let id: RuntimeKind
    let available: Bool
    let detail: String
}

struct RuntimeResult: Sendable, Equatable, Codable {
    let output: String
    let succeeded: Bool
}

enum NexoraConstants {
    static let supportDiscordURL = URL(string: "https://discord.gg/SXZkjcBkFA")!
}
