import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let refreshID = "app.nexorahost.maintenance"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            task.expirationHandler = {
                task.setTaskCompleted(success: false)
            }
            Task {
                await MaintenanceService.shared.performMaintenance()
                task.setTaskCompleted(success: true)
            }
        }

        BackgroundHostingManager.shared.registerContinuedProcessingHandler()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleMaintenance()
        BackgroundHostingManager.shared.sceneDidEnterBackground()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        BackgroundHostingManager.shared.sceneDidBecomeActive()
    }

    private func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: refreshID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

/// Best-effort background protection for locally running projects.
///
/// On iOS/iPadOS 26+, Nexora uses BGContinuedProcessingTask, which Apple designed
/// for user-started work that continues after the app is backgrounded. On older
/// systems it falls back to UIApplication background time. Neither API promises
/// permanent 24/7 execution; iOS can still expire/suspend work under resource pressure.
final class BackgroundHostingManager: @unchecked Sendable {
    static let shared = BackgroundHostingManager()

    static let continuedTaskID = "app.nexorahost.continuedHosting"
    static let enabledDefaultsKey = "nexora.backgroundHosting.enabled"

    private let lock = NSLock()
    private let continuedQueue = DispatchQueue(label: "app.nexorahost.background-hosting", qos: .utility)
    private var activeProjects: [String: String] = [:]
    private var continuedRequestSubmitted = false
    private var continuedRequestSubmittedAt: Date?
    private var continuedTaskAttached = false
    private var continuedTaskExpired = false
    private var fallbackTaskID: UIBackgroundTaskIdentifier = .invalid
    private var latestStatus = "Ready"
    private var handlerRegistered = false

    private init() {
        if UserDefaults.standard.object(forKey: Self.enabledDefaultsKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledDefaultsKey)
        }
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    var statusText: String {
        lock.lock(); defer { lock.unlock() }
        return latestStatus
    }

    var activeProjectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return activeProjects.count
    }

    func registerContinuedProcessingHandler() {
        guard #available(iOS 26.0, *) else {
            setStatus("Ready · legacy background-time fallback")
            return
        }

        lock.lock()
        guard !handlerRegistered else {
            lock.unlock()
            return
        }
        handlerRegistered = true
        lock.unlock()

        let registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.continuedTaskID,
            using: continuedQueue
        ) { task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            BackgroundHostingManager.shared.handleContinuedProcessingTask(continued)
        }

        setStatus(registered
            ? "Ready · iOS 26 continued processing available"
            : "Background hosting unavailable · task identifier not registered")
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        if enabled {
            setStatus(activeProjectCount > 0 ? "Background hosting enabled" : readyStatus())
            requestProtectionIfNeeded()
        } else {
            endFallbackLease()
            lock.lock()
            continuedTaskExpired = true
            continuedRequestSubmitted = false
            continuedRequestSubmittedAt = nil
            lock.unlock()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskID)
            setStatus("Background hosting disabled")
        }
    }

    func projectStarted(id: String, name: String) {
        lock.lock()
        activeProjects[id] = name
        continuedTaskExpired = false
        lock.unlock()
        guard isEnabled else {
            setStatus("Project running · background hosting disabled")
            return
        }
        requestProtectionIfNeeded()
    }

    func projectStopped(id: String) {
        lock.lock()
        activeProjects[id] = nil
        let remaining = activeProjects.count
        lock.unlock()

        if remaining == 0 {
            lock.lock()
            continuedRequestSubmitted = false
            continuedRequestSubmittedAt = nil
            lock.unlock()
            endFallbackLease()
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.continuedTaskID)
            setStatus(readyStatus())
        } else {
            setStatus("Protecting \(remaining) running project\(remaining == 1 ? "" : "s")")
        }
    }

    func syncRunningProjects(_ projects: [(id: String, name: String)]) {
        lock.lock()
        activeProjects = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.name) })
        let count = activeProjects.count
        lock.unlock()

        if count == 0 {
            endFallbackLease()
            setStatus(readyStatus())
        } else if isEnabled {
            requestProtectionIfNeeded()
        }
    }

    func sceneDidEnterBackground() {
        guard isEnabled, activeProjectCount > 0 else { return }
        if #available(iOS 26.0, *) {
            // A continued-processing request should already have been submitted by
            // the explicit Run action. Keep a short legacy lease as a safety net
            // until the continued task is attached by the scheduler.
            lock.lock()
            let attached = continuedTaskAttached
            lock.unlock()
            if !attached { beginFallbackLeaseIfNeeded() }
        } else {
            beginFallbackLeaseIfNeeded()
        }
    }

    func sceneDidBecomeActive() {
        endFallbackLease()
        guard activeProjectCount > 0 else {
            setStatus(readyStatus())
            return
        }
        if isEnabled {
            setStatus("Foreground · \(activeProjectCount) project\(activeProjectCount == 1 ? "" : "s") running")
        }
    }

    private func requestProtectionIfNeeded() {
        guard isEnabled else { return }

        lock.lock()
        let count = activeProjects.count
        let submittedIsFresh = continuedRequestSubmittedAt.map { Date().timeIntervalSince($0) < 15 } ?? false
        if continuedRequestSubmitted && !submittedIsFresh && !continuedTaskAttached {
            continuedRequestSubmitted = false
            continuedRequestSubmittedAt = nil
        }
        let alreadyProtected = continuedRequestSubmitted || continuedTaskAttached
        let projectName = activeProjects.values.sorted().first ?? "Local project"
        lock.unlock()

        guard count > 0 else { return }

        if #available(iOS 26.0, *) {
            guard !alreadyProtected else {
                setStatus("Continued background hosting active · \(count) project\(count == 1 ? "" : "s")")
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard UIApplication.shared.applicationState == .active else {
                    self.beginFallbackLeaseIfNeeded()
                    self.setStatus("Waiting for foreground to request continued hosting")
                    return
                }

                self.lock.lock()
                if self.continuedRequestSubmitted || self.continuedTaskAttached {
                    self.lock.unlock()
                    return
                }
                self.continuedRequestSubmitted = true
                self.continuedRequestSubmittedAt = Date()
                self.lock.unlock()

                let request = BGContinuedProcessingTaskRequest(
                    identifier: Self.continuedTaskID,
                    title: "Nexora Host",
                    subtitle: "Hosting \(projectName)"
                )
                request.strategy = .queue

                do {
                    try BGTaskScheduler.shared.submit(request)
                    self.setStatus("Continued background hosting requested")
                } catch {
                    self.lock.lock()
                    self.continuedRequestSubmitted = false
                    self.continuedRequestSubmittedAt = nil
                    self.lock.unlock()
                    self.beginFallbackLeaseIfNeeded()
                    self.setStatus("Continued hosting request failed · using fallback")
                }
            }
        } else {
            beginFallbackLeaseIfNeeded()
            setStatus("Legacy background-time fallback active")
        }
    }

    @available(iOS 26.0, *)
    private func handleContinuedProcessingTask(_ task: BGContinuedProcessingTask) {
        lock.lock()
        continuedRequestSubmitted = false
        continuedRequestSubmittedAt = nil
        continuedTaskAttached = true
        continuedTaskExpired = false
        let initialCount = activeProjects.count
        lock.unlock()

        endFallbackLease()
        setStatus("Continued background hosting active · \(initialCount) project\(initialCount == 1 ? "" : "s")")

        // A hosting session has no natural percentage completion. Represent a
        // 24-hour hosting window as elapsed-time progress so iOS receives real,
        // monotonic progress updates instead of a fake completed percentage.
        let sessionSeconds: Int64 = 24 * 60 * 60
        task.progress.totalUnitCount = sessionSeconds
        task.progress.completedUnitCount = 0
        let startedAt = Date()

        task.expirationHandler = { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.continuedTaskExpired = true
            self.lock.unlock()
            self.setStatus("iOS ended continued background time")
        }

        var lastTitleUpdate = Date.distantPast
        while true {
            lock.lock()
            let expired = continuedTaskExpired
            let enabled = isEnabled
            let names = activeProjects.values.sorted()
            lock.unlock()

            if expired || !enabled || names.isEmpty { break }

            let elapsed = min(sessionSeconds - 1, Int64(Date().timeIntervalSince(startedAt)))
            task.progress.completedUnitCount = max(0, elapsed)

            if Date().timeIntervalSince(lastTitleUpdate) >= 20 {
                let subtitle: String
                if names.count == 1 {
                    subtitle = "Hosting \(names[0]) · \(formatElapsed(elapsed))"
                } else {
                    subtitle = "Hosting \(names.count) projects · \(formatElapsed(elapsed))"
                }
                task.updateTitle("Nexora Host", subtitle: subtitle)
                lastTitleUpdate = Date()
            }

            Thread.sleep(forTimeInterval: 5)
        }

        lock.lock()
        let expired = continuedTaskExpired
        continuedTaskAttached = false
        continuedTaskExpired = false
        let stillRunning = !activeProjects.isEmpty
        lock.unlock()

        task.setTaskCompleted(success: !expired)
        setStatus(stillRunning ? "Background time ended · project remains running when app resumes" : readyStatus())
    }

    private func beginFallbackLeaseIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.activeProjectCount > 0 else { return }
            self.lock.lock()
            if self.fallbackTaskID != .invalid {
                self.lock.unlock()
                return
            }
            self.lock.unlock()

            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "Nexora Local Hosting") { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.fallbackTaskID
                self.fallbackTaskID = .invalid
                self.lock.unlock()
                if current != .invalid {
                    UIApplication.shared.endBackgroundTask(current)
                }
                self.setStatus("Legacy background time expired")
            }

            self.lock.lock()
            self.fallbackTaskID = taskID
            self.lock.unlock()
        }
    }

    private func endFallbackLease() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.fallbackTaskID
            self.fallbackTaskID = .invalid
            self.lock.unlock()
            guard current != .invalid else { return }
            UIApplication.shared.endBackgroundTask(current)
        }
    }

    private func readyStatus() -> String {
        if #available(iOS 26.0, *) {
            return "Ready · continued processing available"
        }
        return "Ready · legacy background-time fallback"
    }

    private func formatElapsed(_ seconds: Int64) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func setStatus(_ text: String) {
        lock.lock()
        latestStatus = text
        lock.unlock()
    }
}
