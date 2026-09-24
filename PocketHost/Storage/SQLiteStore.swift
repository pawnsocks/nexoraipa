import Foundation
import SQLite3

final class SQLiteStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "PocketHost.SQLite")

    init() {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("pockethost.sqlite")
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            exec("PRAGMA journal_mode=WAL;")
            exec("CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value BLOB NOT NULL);")
        }
    }

    deinit { sqlite3_close(db) }

    func set(_ key: String, value: Data) {
        queue.sync {
            guard let db else { return }
            var stmt: OpaquePointer?
            let sql = "INSERT INTO kv(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            value.withUnsafeBytes { raw in
                _ = sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), nil)
            }
            _ = sqlite3_step(stmt)
        }
    }

    func get(_ key: String) -> Data? {
        queue.sync {
            guard let db else { return nil }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT value FROM kv WHERE key=? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            return Data(bytes: bytes, count: count)
        }
    }

    func checkpointAndVacuum() {
        queue.sync {
            exec("PRAGMA wal_checkpoint(TRUNCATE);")
            exec("VACUUM;")
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}
