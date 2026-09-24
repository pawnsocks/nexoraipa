import Foundation

final class AutoTuneEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var currentProfile: TuneProfile = .auto
    private var currentPolicy = TunedPolicy(
        workerLimit: 2,
        cacheLimitMB: 64,
        tickIntervalMS: 500,
        suspendIdleRuntimes: true,
        note: "Auto"
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
    func setProfile(_ value: TuneProfile, isCharging: Bool) -> TuneProfile {
        lock.lock(); defer { lock.unlock() }
        currentProfile = value
        return currentProfile
    }

    func evaluate(_ metrics: MetricsSnapshot) -> TunedPolicy {
        lock.lock(); defer { lock.unlock() }
        let cores = max(1, metrics.processorCount)
        var next: TunedPolicy

        switch currentProfile {
        case .auto:
            if metrics.lowPowerMode || metrics.batteryPercent <= 20 {
                next = batteryPolicy(note: "Auto · battery protection")
            } else if metrics.isCharging && metrics.thermal == "Nominal" {
                next = performancePolicy(cores: cores, note: "Auto · charging and thermals healthy")
            } else {
                next = balancedPolicy(cores: cores, note: "Auto · balanced")
            }
        case .performance:
            next = performancePolicy(cores: cores, note: "Performance")
        case .balanced:
            next = balancedPolicy(cores: cores, note: "Balanced")
        case .batterySaver:
            next = batteryPolicy(note: "Battery Saver")
        }

        if metrics.thermal == "Serious" || metrics.thermal == "Critical" {
            next.workerLimit = 1
            next.cacheLimitMB = min(next.cacheLimitMB, 24)
            next.runtimeMemoryTargetMB = min(next.runtimeMemoryTargetMB, 192)
            next.tickIntervalMS = max(next.tickIntervalMS, 1200)
            next.previewFPS = 30
            next.indexingMode = "Paused"
            next.suspendIdleRuntimes = true
            next.note = "Thermal protection active"
        }

        if metrics.residentMemoryMB > 1100 {
            next.workerLimit = 1
            next.cacheLimitMB = 16
            next.runtimeMemoryTargetMB = 160
            next.indexingMode = "Minimal"
            next.suspendIdleRuntimes = true
            next.note = "Memory protection active"
        } else if metrics.residentMemoryMB > 850 {
            next.workerLimit = min(next.workerLimit, 2)
            next.cacheLimitMB = min(next.cacheLimitMB, 32)
            next.runtimeMemoryTargetMB = min(next.runtimeMemoryTargetMB, 256)
            next.indexingMode = "Reduced"
            next.note = "Memory pressure guard"
        }

        currentPolicy = next
        return next
    }

    private func performancePolicy(cores: Int, note: String) -> TunedPolicy {
        .init(
            workerLimit: min(max(2, cores - 1), 6),
            cacheLimitMB: 128,
            tickIntervalMS: 250,
            suspendIdleRuntimes: false,
            note: note,
            previewFPS: 60,
            indexingMode: "Full",
            runtimeMemoryTargetMB: 512
        )
    }

    private func balancedPolicy(cores: Int, note: String) -> TunedPolicy {
        .init(
            workerLimit: min(max(2, cores / 2), 4),
            cacheLimitMB: 64,
            tickIntervalMS: 500,
            suspendIdleRuntimes: true,
            note: note,
            previewFPS: 60,
            indexingMode: "Normal",
            runtimeMemoryTargetMB: 384
        )
    }

    private func batteryPolicy(note: String) -> TunedPolicy {
        .init(
            workerLimit: 1,
            cacheLimitMB: 32,
            tickIntervalMS: 1000,
            suspendIdleRuntimes: true,
            note: note,
            previewFPS: 30,
            indexingMode: "Reduced",
            runtimeMemoryTargetMB: 224
        )
    }
}
