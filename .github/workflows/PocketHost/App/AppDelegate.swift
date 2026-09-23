import UIKit
import BackgroundTasks

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let refreshID = "app.pockethost.maintenance"

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
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        scheduleMaintenance()
    }

    private func scheduleMaintenance() {
        let request = BGProcessingTaskRequest(identifier: refreshID)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
