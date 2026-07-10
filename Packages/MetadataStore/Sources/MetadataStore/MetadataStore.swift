import Foundation
import SQLite3
import MacStorageCore

public enum MetadataStoreError: Error, LocalizedError {
    case openFailed(String)
    case prepareFailed(String)
    case stepFailed(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .openFailed(let s): return "Failed to open database: \(s)"
        case .prepareFailed(let s): return "SQL prepare failed: \(s)"
        case .stepFailed(let s): return "SQL step failed: \(s)"
        case .notFound: return "Record not found"
        }
    }
}

/// Local SQLite store. Thread-safe via serial queue.
public final class MetadataStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.macstoragestudio.metadatastore")
    public let databaseURL: URL

    public init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let code = databaseURL.path.withCString { path in
            sqlite3_open_v2(path, &db, flags, nil)
        }
        guard code == SQLITE_OK else {
            throw MetadataStoreError.openFailed(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS scan_sessions (
            id TEXT PRIMARY KEY,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            roots_json TEXT NOT NULL,
            files_scanned INTEGER NOT NULL DEFAULT 0,
            bytes_scanned INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            checkpoint_path TEXT
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS file_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            path TEXT NOT NULL,
            parent_path TEXT,
            name TEXT NOT NULL,
            is_directory INTEGER NOT NULL,
            size INTEGER NOT NULL,
            allocated_size INTEGER NOT NULL,
            created_at REAL,
            modified_at REAL,
            accessed_at REAL,
            owner_id INTEGER,
            permissions INTEGER,
            inode INTEGER,
            device INTEGER,
            link_count INTEGER NOT NULL,
            is_symlink INTEGER NOT NULL,
            extension TEXT,
            category TEXT NOT NULL,
            is_package INTEGER NOT NULL DEFAULT 0,
            UNIQUE(session_id, path)
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_entries_session_parent ON file_entries(session_id, parent_path);")
        try exec("CREATE INDEX IF NOT EXISTS idx_entries_session_size ON file_entries(session_id, size DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_entries_session_category ON file_entries(session_id, category);")
        try exec("""
        CREATE TABLE IF NOT EXISTS recommendations (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            path TEXT NOT NULL,
            title TEXT NOT NULL,
            reason TEXT NOT NULL,
            explanation TEXT NOT NULL,
            confidence REAL NOT NULL,
            reclaimable_bytes INTEGER NOT NULL,
            owner TEXT,
            risk TEXT NOT NULL,
            regenerable INTEGER NOT NULL,
            category TEXT NOT NULL,
            dependencies_json TEXT NOT NULL
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS idx_reco_session ON recommendations(session_id);")
    }

    // MARK: - Sessions

    public func upsertSession(_ session: ScanSession) throws {
        try queue.sync {
            let sql = """
            INSERT INTO scan_sessions
            (id, started_at, finished_at, status, roots_json, files_scanned, bytes_scanned, error_message, checkpoint_path)
            VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
              finished_at=excluded.finished_at,
              status=excluded.status,
              files_scanned=excluded.files_scanned,
              bytes_scanned=excluded.bytes_scanned,
              error_message=excluded.error_message,
              checkpoint_path=excluded.checkpoint_path;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            let rootsData = try JSONEncoder().encode(session.roots)
            let rootsJSON = String(data: rootsData, encoding: .utf8) ?? "[]"
            bindText(stmt, 1, session.id.uuidString)
            bindDouble(stmt, 2, session.startedAt.timeIntervalSince1970)
            if let finished = session.finishedAt {
                bindDouble(stmt, 3, finished.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bindText(stmt, 4, session.status.rawValue)
            bindText(stmt, 5, rootsJSON)
            bindInt64(stmt, 6, Int64(session.filesScanned))
            bindInt64(stmt, 7, session.bytesScanned)
            bindTextOptional(stmt, 8, session.errorMessage)
            bindTextOptional(stmt, 9, session.checkpointPath)
            try stepDone(stmt)
        }
    }

    public func latestSession() throws -> ScanSession? {
        try queue.sync {
            let sql = "SELECT * FROM scan_sessions ORDER BY started_at DESC LIMIT 1;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readSession(stmt)
        }
    }

    public func session(id: UUID) throws -> ScanSession? {
        try queue.sync {
            let sql = "SELECT * FROM scan_sessions WHERE id = ? LIMIT 1;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, id.uuidString)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readSession(stmt)
        }
    }

    public func allSessions() throws -> [ScanSession] {
        try queue.sync {
            let sql = "SELECT * FROM scan_sessions ORDER BY started_at DESC;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            var result: [ScanSession] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(readSession(stmt))
            }
            return result
        }
    }

    // MARK: - Entries

    public func insertEntries(_ entries: [FileEntry]) throws {
        guard !entries.isEmpty else { return }
        try queue.sync {
            try exec("BEGIN TRANSACTION;")
            defer { try? exec("COMMIT;") }
            let sql = """
            INSERT INTO file_entries
            (session_id, path, parent_path, name, is_directory, size, allocated_size,
             created_at, modified_at, accessed_at, owner_id, permissions, inode, device,
             link_count, is_symlink, extension, category, is_package)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(session_id, path) DO UPDATE SET
              size=excluded.size,
              allocated_size=excluded.allocated_size,
              category=excluded.category;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, entry.sessionID.uuidString)
                bindText(stmt, 2, entry.path)
                bindTextOptional(stmt, 3, entry.parentPath)
                bindText(stmt, 4, entry.name)
                bindInt64(stmt, 5, entry.isDirectory ? 1 : 0)
                bindInt64(stmt, 6, entry.size)
                bindInt64(stmt, 7, entry.allocatedSize)
                bindDateOptional(stmt, 8, entry.createdAt)
                bindDateOptional(stmt, 9, entry.modifiedAt)
                bindDateOptional(stmt, 10, entry.accessedAt)
                if let owner = entry.ownerID { bindInt64(stmt, 11, Int64(owner)) } else { sqlite3_bind_null(stmt, 11) }
                if let perms = entry.permissions { bindInt64(stmt, 12, Int64(perms)) } else { sqlite3_bind_null(stmt, 12) }
                if let inode = entry.inode { bindInt64(stmt, 13, Int64(bitPattern: inode)) } else { sqlite3_bind_null(stmt, 13) }
                if let device = entry.device { bindInt64(stmt, 14, Int64(bitPattern: device)) } else { sqlite3_bind_null(stmt, 14) }
                bindInt64(stmt, 15, Int64(entry.linkCount))
                bindInt64(stmt, 16, entry.isSymbolicLink ? 1 : 0)
                bindTextOptional(stmt, 17, entry.fileExtension)
                bindText(stmt, 18, entry.category.rawValue)
                bindInt64(stmt, 19, entry.isPackage ? 1 : 0)
                try stepDone(stmt)
            }
        }
    }

    public func children(sessionID: UUID, parentPath: String?) throws -> [FileEntry] {
        try queue.sync {
            let sql: String
            let stmt: OpaquePointer
            if let parentPath {
                sql = """
                SELECT * FROM file_entries
                WHERE session_id = ? AND parent_path = ?
                ORDER BY is_directory DESC, size DESC, name COLLATE NOCASE;
                """
                stmt = try prepare(sql)
                bindText(stmt, 1, sessionID.uuidString)
                bindText(stmt, 2, parentPath)
            } else {
                // Roots: entries whose parent is null or not in this session as a scanned path under roots
                sql = """
                SELECT * FROM file_entries
                WHERE session_id = ? AND (parent_path IS NULL OR parent_path = '')
                ORDER BY is_directory DESC, size DESC, name COLLATE NOCASE;
                """
                stmt = try prepare(sql)
                bindText(stmt, 1, sessionID.uuidString)
            }
            defer { sqlite3_finalize(stmt) }
            var rows: [FileEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readEntry(stmt))
            }
            return rows
        }
    }


    public func largestDirectories(sessionID: UUID, limit: Int = 50) throws -> [FileEntry] {
        try queue.sync {
            let sql = """
            SELECT * FROM file_entries
            WHERE session_id = ? AND is_directory = 1
            ORDER BY size DESC
            LIMIT ?;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            bindInt64(stmt, 2, Int64(limit))
            var rows: [FileEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readEntry(stmt))
            }
            return rows
        }
    }

    public func largestEntries(sessionID: UUID, limit: Int = 50) throws -> [FileEntry] {
        try queue.sync {
            let sql = """
            SELECT * FROM file_entries
            WHERE session_id = ? AND is_directory = 0
            ORDER BY size DESC
            LIMIT ?;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            bindInt64(stmt, 2, Int64(limit))
            var rows: [FileEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readEntry(stmt))
            }
            return rows
        }
    }

    public func entries(sessionID: UUID, category: StorageCategory) throws -> [FileEntry] {
        try queue.sync {
            let sql = """
            SELECT * FROM file_entries
            WHERE session_id = ? AND category = ?
            ORDER BY size DESC;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            bindText(stmt, 2, category.rawValue)
            var rows: [FileEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readEntry(stmt))
            }
            return rows
        }
    }

    public func search(sessionID: UUID, query: String, limit: Int = 200) throws -> [FileEntry] {
        try queue.sync {
            let sql = """
            SELECT * FROM file_entries
            WHERE session_id = ? AND name LIKE ?
            ORDER BY size DESC
            LIMIT ?;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            bindText(stmt, 2, "%\(query)%")
            bindInt64(stmt, 3, Int64(limit))
            var rows: [FileEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readEntry(stmt))
            }
            return rows
        }
    }

    public func categoryBreakdown(sessionID: UUID) throws -> [(StorageCategory, Int64, Int)] {
        try queue.sync {
            let sql = """
            SELECT category, SUM(size) as total, COUNT(*) as cnt
            FROM file_entries
            WHERE session_id = ? AND is_directory = 0
            GROUP BY category
            ORDER BY total DESC;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            var result: [(StorageCategory, Int64, Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let raw = String(cString: sqlite3_column_text(stmt, 0))
                let cat = StorageCategory(rawValue: raw) ?? .unknown
                let total = sqlite3_column_int64(stmt, 1)
                let cnt = Int(sqlite3_column_int64(stmt, 2))
                result.append((cat, total, cnt))
            }
            return result
        }
    }

    public func directoryRollup(sessionID: UUID, path: String) throws -> DirectoryAggregate? {
        try queue.sync {
            // Approximate: sum sizes of files whose path is under path/
            let prefix = path.hasSuffix("/") ? path : path + "/"
            let sql = """
            SELECT
              COALESCE(SUM(CASE WHEN is_directory = 0 THEN size ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN is_directory = 0 THEN allocated_size ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN is_directory = 0 THEN 1 ELSE 0 END), 0),
              COALESCE(SUM(CASE WHEN parent_path = ? THEN 1 ELSE 0 END), 0)
            FROM file_entries
            WHERE session_id = ? AND (path = ? OR path LIKE ?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, path)
            bindText(stmt, 2, sessionID.uuidString)
            bindText(stmt, 3, path)
            bindText(stmt, 4, prefix + "%")
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let name = (path as NSString).lastPathComponent
            return DirectoryAggregate(
                path: path,
                name: name.isEmpty ? path : name,
                totalSize: sqlite3_column_int64(stmt, 0),
                totalAllocated: sqlite3_column_int64(stmt, 1),
                fileCount: Int(sqlite3_column_int64(stmt, 2)),
                childCount: Int(sqlite3_column_int64(stmt, 3))
            )
        }
    }

    public func deleteEntries(sessionID: UUID) throws {
        try queue.sync {
            let sql = "DELETE FROM file_entries WHERE session_id = ?;"
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            try stepDone(stmt)
        }
    }


    /// Set each directory size to the sum of descendant file sizes (prefix sum).
    public func rollupDirectorySizes(sessionID: UUID) throws {
        try queue.sync {
            let dirsSQL = """
            SELECT path FROM file_entries
            WHERE session_id = ? AND is_directory = 1;
            """
            let dirsStmt = try prepare(dirsSQL)
            bindText(dirsStmt, 1, sessionID.uuidString)
            var dirs: [String] = []
            while sqlite3_step(dirsStmt) == SQLITE_ROW {
                dirs.append(textColumn(dirsStmt, 0))
            }
            sqlite3_finalize(dirsStmt)

            let sumSQL = """
            SELECT COALESCE(SUM(size), 0) FROM file_entries
            WHERE session_id = ? AND is_directory = 0 AND path LIKE ?;
            """
            let updSQL = """
            UPDATE file_entries SET size = ?, allocated_size = ?
            WHERE session_id = ? AND path = ?;
            """
            let sumStmt = try prepare(sumSQL)
            let updStmt = try prepare(updSQL)
            defer {
                sqlite3_finalize(sumStmt)
                sqlite3_finalize(updStmt)
            }

            try exec("BEGIN TRANSACTION;")
            for dir in dirs {
                let prefix = dir.hasSuffix("/") ? (dir + "%") : (dir + "/%")
                sqlite3_reset(sumStmt)
                sqlite3_clear_bindings(sumStmt)
                bindText(sumStmt, 1, sessionID.uuidString)
                bindText(sumStmt, 2, prefix)
                var total: Int64 = 0
                if sqlite3_step(sumStmt) == SQLITE_ROW {
                    total = sqlite3_column_int64(sumStmt, 0)
                }
                sqlite3_reset(updStmt)
                sqlite3_clear_bindings(updStmt)
                bindInt64(updStmt, 1, total)
                bindInt64(updStmt, 2, total)
                bindText(updStmt, 3, sessionID.uuidString)
                bindText(updStmt, 4, dir)
                try stepDone(updStmt)
            }
            try exec("COMMIT;")
        }
    }

    // MARK: - Recommendations

    public func replaceRecommendations(_ items: [CleanupRecommendation], sessionID: UUID) throws {
        try queue.sync {
            try exec("BEGIN TRANSACTION;")
            defer { try? exec("COMMIT;") }
            let del = try prepare("DELETE FROM recommendations WHERE session_id = ?;")
            bindText(del, 1, sessionID.uuidString)
            try stepDone(del)
            sqlite3_finalize(del)

            let sql = """
            INSERT INTO recommendations
            (id, session_id, path, title, reason, explanation, confidence, reclaimable_bytes,
             owner, risk, regenerable, category, dependencies_json)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            for item in items {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, item.id.uuidString)
                bindText(stmt, 2, item.sessionID.uuidString)
                bindText(stmt, 3, item.path)
                bindText(stmt, 4, item.title)
                bindText(stmt, 5, item.reason)
                bindText(stmt, 6, item.explanation)
                sqlite3_bind_double(stmt, 7, item.confidence)
                bindInt64(stmt, 8, item.reclaimableBytes)
                bindTextOptional(stmt, 9, item.owner)
                bindText(stmt, 10, item.risk.rawValue)
                bindInt64(stmt, 11, item.regenerable ? 1 : 0)
                bindText(stmt, 12, item.category.rawValue)
                let deps = (try? String(data: JSONEncoder().encode(item.dependencies), encoding: .utf8)) ?? "[]"
                bindText(stmt, 13, deps)
                try stepDone(stmt)
            }
        }
    }

    public func recommendations(sessionID: UUID) throws -> [CleanupRecommendation] {
        try queue.sync {
            let sql = """
            SELECT * FROM recommendations
            WHERE session_id = ?
            ORDER BY reclaimable_bytes DESC;
            """
            let stmt = try prepare(sql)
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID.uuidString)
            var rows: [CleanupRecommendation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append(readRecommendation(stmt))
            }
            return rows
        }
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(db, sql, nil, nil, &err)
        if code != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw MetadataStoreError.stepFailed(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard code == SQLITE_OK, let stmt else {
            throw MetadataStoreError.prepareFailed(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let code = sqlite3_step(stmt)
        guard code == SQLITE_DONE else {
            throw MetadataStoreError.stepFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { sqlite3_bind_text(stmt, idx, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    }

    private func bindTextOptional(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value { bindText(stmt, idx, value) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double) {
        sqlite3_bind_double(stmt, idx, value)
    }

    private func bindInt64(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, idx, value)
    }

    private func bindDateOptional(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Date?) {
        if let value { bindDouble(stmt, idx, value.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, idx) }
    }

    private func textColumn(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private func textColumnOptional(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        return textColumn(stmt, idx)
    }

    private func readSession(_ stmt: OpaquePointer?) -> ScanSession {
        let id = UUID(uuidString: textColumn(stmt, 0)) ?? UUID()
        let started = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
        let finished: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
        let status = ScanStatus(rawValue: textColumn(stmt, 3)) ?? .failed
        let rootsJSON = textColumn(stmt, 4)
        let roots = (try? JSONDecoder().decode([String].self, from: Data(rootsJSON.utf8))) ?? []
        return ScanSession(
            id: id,
            startedAt: started,
            finishedAt: finished,
            status: status,
            roots: roots,
            filesScanned: Int(sqlite3_column_int64(stmt, 5)),
            bytesScanned: sqlite3_column_int64(stmt, 6),
            errorMessage: textColumnOptional(stmt, 7),
            checkpointPath: textColumnOptional(stmt, 8)
        )
    }

    private func readEntry(_ stmt: OpaquePointer?) -> FileEntry {
        // Columns: 0 id, 1 session_id, 2 path, 3 parent_path, 4 name, 5 is_directory,
        // 6 size, 7 allocated_size, 8 created_at, 9 modified_at, 10 accessed_at,
        // 11 owner_id, 12 permissions, 13 inode, 14 device, 15 link_count, 16 is_symlink,
        // 17 extension, 18 category, 19 is_package
        let sessionID = UUID(uuidString: textColumn(stmt, 1)) ?? UUID()
        let created: Date? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let modified: Date? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))
        let accessed: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        let owner: UInt32? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : UInt32(sqlite3_column_int64(stmt, 11))
        let perms: UInt16? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : UInt16(sqlite3_column_int64(stmt, 12))
        let inode: UInt64? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(stmt, 13))
        let device: UInt64? = sqlite3_column_type(stmt, 14) == SQLITE_NULL ? nil : UInt64(bitPattern: sqlite3_column_int64(stmt, 14))
        return FileEntry(
            rowID: sqlite3_column_int64(stmt, 0),
            sessionID: sessionID,
            path: textColumn(stmt, 2),
            parentPath: textColumnOptional(stmt, 3),
            name: textColumn(stmt, 4),
            isDirectory: sqlite3_column_int64(stmt, 5) != 0,
            size: sqlite3_column_int64(stmt, 6),
            allocatedSize: sqlite3_column_int64(stmt, 7),
            createdAt: created,
            modifiedAt: modified,
            accessedAt: accessed,
            ownerID: owner,
            permissions: perms,
            inode: inode,
            device: device,
            linkCount: UInt16(max(0, sqlite3_column_int64(stmt, 15))),
            isSymbolicLink: sqlite3_column_int64(stmt, 16) != 0,
            fileExtension: textColumnOptional(stmt, 17),
            category: StorageCategory(rawValue: textColumn(stmt, 18)) ?? .unknown,
            isPackage: sqlite3_column_int64(stmt, 19) != 0
        )
    }

    private func readRecommendation(_ stmt: OpaquePointer?) -> CleanupRecommendation {
        let id = UUID(uuidString: textColumn(stmt, 0)) ?? UUID()
        let sessionID = UUID(uuidString: textColumn(stmt, 1)) ?? UUID()
        let depsJSON = textColumn(stmt, 12)
        let deps = (try? JSONDecoder().decode([String].self, from: Data(depsJSON.utf8))) ?? []
        return CleanupRecommendation(
            id: id,
            sessionID: sessionID,
            path: textColumn(stmt, 2),
            title: textColumn(stmt, 3),
            reason: textColumn(stmt, 4),
            explanation: textColumn(stmt, 5),
            confidence: sqlite3_column_double(stmt, 6),
            reclaimableBytes: sqlite3_column_int64(stmt, 7),
            owner: textColumnOptional(stmt, 8),
            risk: RiskLevel(rawValue: textColumn(stmt, 9)) ?? .medium,
            regenerable: sqlite3_column_int64(stmt, 10) != 0,
            category: StorageCategory(rawValue: textColumn(stmt, 11)) ?? .unknown,
            dependencies: deps
        )
    }
}
