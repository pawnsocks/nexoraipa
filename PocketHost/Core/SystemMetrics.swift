import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

final class SystemMetricsSampler: @unchecked Sendable {
    private var lastCPUSeconds: Double?
    private var lastWallTime: TimeInterval?

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    func sample(requestsPerSecond: Double, keyValueCount: Int) -> MetricsSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuSeconds = CPUTimeProbe.totalSeconds()
        var cpuPercent = 0.0
        if let lastCPUSeconds, let lastWallTime {
            let cpuDelta = max(0, cpuSeconds - lastCPUSeconds)
            let wallDelta = max(0.001, now - lastWallTime)
            cpuPercent = min(100.0 * Double(ProcessInfo.processInfo.activeProcessorCount), (cpuDelta / wallDelta) * 100.0)
        }
        self.lastCPUSeconds = cpuSeconds
        self.lastWallTime = now

        let device = UIDevice.current
        let level = device.batteryLevel >= 0 ? Int(device.batteryLevel * 100) : 0
        let charging = device.batteryState == .charging || device.batteryState == .full

        return MetricsSnapshot(
            residentMemoryMB: MemoryProbe.residentMegabytes(),
            cpuPercent: cpuPercent,
            thermal: Self.thermalName(ProcessInfo.processInfo.thermalState),
            batteryPercent: level,
            isCharging: charging,
            requestsPerSecond: requestsPerSecond,
            keyValueCount: keyValueCount,
            timestamp: .now
        )
    }

    private static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
}

enum MemoryProbe {
    static func residentMegabytes() -> Double {
        #if canImport(Darwin)
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576.0
        #else
        return 0
        #endif
    }
}

enum CPUTimeProbe {
    static func totalSeconds() -> Double {
        #if canImport(Darwin)
        var info = task_thread_times_info()
        var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000.0
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000.0
        return user + system
        #else
        return 0
        #endif
    }
}
