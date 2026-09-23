import Foundation

actor MaintenanceService {
    static let shared = MaintenanceService()

    func performMaintenance() async {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory
        guard let files = try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let date = values?.contentModificationDate, date < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }
}
