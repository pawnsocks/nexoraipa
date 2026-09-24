import Foundation
import SQLite3

final class ProjectDatabaseManager: @unchecked Sendable {
    enum DBError: Error { case openFailed, prepareFailed(String), executionFailed(String) }
    private let lock = NSLock()
    private let projects: ProjectManager

    init(projects: ProjectManager) { self.projects = projects }

    func execute(projectID: String, sql: String) throws -> SQLResult {
        guard projects.get(projectID) != nil else { throw ProjectManager.ProjectError.notFound }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sql.utf8.count <= 65_536 else { throw DBError.executionFailed("Invalid SQL") }
        lock.lock(); defer { lock.unlock() }
        var db: OpaquePointer?
        guard sqlite3_open(projects.databaseURL(projectID).path, &db) == SQLITE_OK, let db else { throw DBError.openFailed }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw DBError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let columnCount = Int(sqlite3_column_count(stmt))
        var columns: [String] = []
        for i in 0..<columnCount { columns.append(String(cString: sqlite3_column_name(stmt, Int32(i)))) }
        var rows: [[String: String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw DBError.executionFailed(String(cString: sqlite3_errmsg(db))) }
            var row: [String: String?] = [:]
            for i in 0..<columnCount {
                if sqlite3_column_type(stmt, Int32(i)) == SQLITE_NULL { row[columns[i]] = .some(nil) }
                else if let text = sqlite3_column_text(stmt, Int32(i)) { row[columns[i]] = String(cString: text) }
                else { row[columns[i]] = nil }
            }
            rows.append(row)
            if rows.count >= 1000 { break }
        }
        return SQLResult(columns: columns, rows: rows, changes: Int(sqlite3_changes(db)))
    }

    func listTables(projectID: String) throws -> [String] {
        let result = try execute(projectID: projectID, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
        return result.rows.compactMap { row in
            if let wrapped = row["name"], let value = wrapped { return value }
            return nil
        }
    }

    func rows(projectID: String, table: String, limit: Int = 100) throws -> SQLResult {
        let safe = table.replacingOccurrences(of: "\"", with: "\"\"")
        return try execute(projectID: projectID, sql: "SELECT * FROM \"\(safe)\" LIMIT \(max(1, min(limit, 500)));")
    }

}
