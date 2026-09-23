import Foundation

final class AutoTuneEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProfile: TuneProfile = .balanced
    private var currentPolicy = TunedPolicy(
        workerLimit: 2,
        cacheLimitMB: 64,
        tickIntervalMS: 500,
        suspendIdleRuntimes: true,
        note: "Balanced baseline"
    )

    var profile: TuneProfile {
        lock.lock(); defer { lock.unlock() }
        return currentProfile
    }

    var policy: TunedPolicy {
        lock.lock(); defer { lock.unlock() }
        return currentPolicy
    }

    @discardableResult
    func setProfile(_ newValue: TuneProfile, isCharging: Bool) -> TuneProfile {
        lock.lock(); defer { lock.unlock() }
        currentProfile = (newValue == .turbo && !isCharging) ? .aggressive : newValue
        return currentProfile
    }

    func evaluate(_ metrics: MetricsSnapshot) -> TunedPolicy {
        lock.lock(); defer { lock.unlock() }

        var next: TunedPolicy
        switch currentProfile {
        case .eco:
            next = .init(workerLimit: 1, cacheLimitMB: 32, tickIntervalMS: 1000, suspendIdleRuntimes: true, note: "Eco")
        case .balanced:
            next = .init(workerLimit: 2, cacheLimitMB: 64, tickIntervalMS: 500, suspendIdleRuntimes: true, note: "Balanced")
        case .aggressive:
            next = .init(workerLimit: 3, cacheLimitMB: 96, tickIntervalMS: 250, suspendIdleRuntimes: false, note: "Aggressive")
        case .turbo:
            next = .init(workerLimit: metrics.isCharging ? 4 : 3, cacheLimitMB: 128, tickIntervalMS: 150, suspendIdleRuntimes: false, note: metrics.isCharging ? "Turbo" : "Turbo limited: not charging")
        }

        if metrics.thermal == "Serious" || metrics.thermal == "Critical" {
            next.workerLimit = 1
            next.cacheLimitMB = min(next.cacheLimitMB, 32)
            next.tickIntervalMS = max(next.tickIntervalMS, 1000)
            next.suspendIdleRuntimes = true
            next.note = "Thermal protection active"
        }

        if metrics.residentMemoryMB > 1000 {
            next.cacheLimitMB = 16
            next.workerLimit = min(next.workerLimit, 1)
            next.suspendIdleRuntimes = true
            next.note = "Memory protection active"
        } else if metrics.residentMemoryMB > 800 {
            next.cacheLimitMB = min(next.cacheLimitMB, 32)
            next.workerLimit = min(next.workerLimit, 2)
            next.note = "Memory pressure guard"
        }

        currentPolicy = next
        return next
    }
}
