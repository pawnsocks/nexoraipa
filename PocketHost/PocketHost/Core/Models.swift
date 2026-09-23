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
}

enum TuneProfile: String, CaseIterable, Identifiable, Sendable, Codable {
    case eco = "Eco"
    case balanced = "Balanced"
    case aggressive = "Aggressive"
    case turbo = "Turbo"

    var id: String { rawValue }
}

struct TunedPolicy: Sendable, Equatable, Codable {
    var workerLimit: Int
    var cacheLimitMB: Int
    var tickIntervalMS: Int
    var suspendIdleRuntimes: Bool
    var note: String
}

enum RuntimeKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case javascript = "JavaScript"
    case python = "Python"
    case lua = "Lua"

    var id: String { rawValue }

    static func apiValue(_ raw: String) -> RuntimeKind? {
        switch raw.lowercased() {
        case "javascript", "js": return .javascript
        case "python", "py": return .python
        case "lua": return .lua
        default: return nil
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
