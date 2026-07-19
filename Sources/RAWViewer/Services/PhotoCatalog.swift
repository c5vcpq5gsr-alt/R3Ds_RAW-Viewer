import Foundation
import SQLite3

enum PhotoCatalogError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message): "Der Fotoindex konnte nicht geöffnet werden: \(message)"
        }
    }
}

actor PhotoCatalog {
    nonisolated(unsafe) private var database: OpaquePointer?

    deinit {
        if let database { sqlite3_close(database) }
    }

    func configure(cacheDirectory: URL) throws {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }

        let databaseURL = cacheDirectory.appendingPathComponent("index.sqlite")
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &handle, flags, nil) == SQLITE_OK,
              let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unbekannter SQLite-Fehler"
            if let handle { sqlite3_close(handle) }
            throw PhotoCatalogError.unavailable(message)
        }
        database = handle

        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA case_sensitive_like=ON")
        try execute("""
            CREATE TABLE IF NOT EXISTS photo_files (
                path TEXT PRIMARY KEY NOT NULL,
                kind TEXT NOT NULL,
                modification_date REAL NOT NULL,
                byte_size INTEGER NOT NULL,
                capture_date REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS photo_files_path_index ON photo_files(path)")
        try execute("""
            CREATE TABLE IF NOT EXISTS photo_analysis (
                photo_id TEXT PRIMARY KEY NOT NULL,
                source_path TEXT NOT NULL,
                source_modification_date REAL NOT NULL,
                model_identifier TEXT NOT NULL,
                keywords_json TEXT NOT NULL,
                description TEXT NOT NULL,
                analyzed_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS photo_analysis_source_path_index ON photo_analysis(source_path)")
        try execute("""
            CREATE TABLE IF NOT EXISTS xmp_exports (
                photo_id TEXT PRIMARY KEY NOT NULL,
                keywords_json TEXT NOT NULL,
                sidecar_path TEXT NOT NULL,
                exported_at REAL NOT NULL,
                FOREIGN KEY(photo_id) REFERENCES photo_analysis(photo_id) ON DELETE CASCADE
            )
            """)
        try migrateXMPExportsIfNeeded()
        try execute("""
            CREATE TABLE IF NOT EXISTS people (
                person_id TEXT PRIMARY KEY NOT NULL,
                display_name TEXT NOT NULL,
                normalized_name TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS person_scans (
                photo_id TEXT PRIMARY KEY NOT NULL,
                source_path TEXT NOT NULL,
                source_modification_date REAL NOT NULL,
                model_identifier TEXT NOT NULL,
                clustering_identifier TEXT NOT NULL,
                face_count INTEGER NOT NULL,
                analyzed_at REAL NOT NULL
            )
            """)
        try migratePersonScansIfNeeded()
        try execute("CREATE INDEX IF NOT EXISTS person_scans_source_path_index ON person_scans(source_path)")
        try execute("""
            CREATE TABLE IF NOT EXISTS face_clusters (
                cluster_id TEXT PRIMARY KEY NOT NULL,
                person_id TEXT,
                model_identifier TEXT NOT NULL,
                centroid BLOB NOT NULL,
                member_count INTEGER NOT NULL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                FOREIGN KEY(person_id) REFERENCES people(person_id) ON DELETE SET NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS face_clusters_person_index ON face_clusters(person_id)")
        try execute("""
            CREATE TABLE IF NOT EXISTS face_observations (
                face_id TEXT PRIMARY KEY NOT NULL,
                photo_id TEXT NOT NULL,
                source_path TEXT NOT NULL,
                box_x REAL NOT NULL,
                box_y REAL NOT NULL,
                box_width REAL NOT NULL,
                box_height REAL NOT NULL,
                confidence REAL NOT NULL,
                embedding BLOB NOT NULL,
                cluster_id TEXT NOT NULL,
                assignment_kind TEXT NOT NULL,
                match_similarity REAL,
                detected_at REAL NOT NULL,
                FOREIGN KEY(photo_id) REFERENCES person_scans(photo_id) ON DELETE CASCADE,
                FOREIGN KEY(cluster_id) REFERENCES face_clusters(cluster_id) ON DELETE CASCADE
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS face_observations_photo_index ON face_observations(photo_id)")
        try execute("CREATE INDEX IF NOT EXISTS face_observations_cluster_index ON face_observations(cluster_id)")
        try execute("PRAGMA user_version=2")
    }

    func files(in folderURL: URL) throws -> [IndexedPhotoFile] {
        let statement = try prepare("""
            SELECT path, kind, modification_date, byte_size, capture_date
            FROM photo_files
            WHERE path LIKE ? ESCAPE '\\'
            ORDER BY path
            """)
        defer { sqlite3_finalize(statement) }
        bind(scopePattern(for: folderURL), at: 1, to: statement)

        var files: [IndexedPhotoFile] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = textColumn(statement, at: 0),
                  let kindValue = textColumn(statement, at: 1),
                  let kind = PhotoFileKind(rawValue: kindValue) else { continue }
            files.append(IndexedPhotoFile(
                url: URL(fileURLWithPath: path),
                kind: kind,
                modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                byteSize: sqlite3_column_int64(statement, 3),
                captureDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return files
    }

    func replaceFiles(in folderURL: URL, with files: [IndexedPhotoFile]) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let delete = try prepare("DELETE FROM photo_files WHERE path LIKE ? ESCAPE '\\'")
            bind(scopePattern(for: folderURL), at: 1, to: delete)
            guard sqlite3_step(delete) == SQLITE_DONE else {
                let message = errorMessage
                sqlite3_finalize(delete)
                throw PhotoCatalogError.unavailable(message)
            }
            sqlite3_finalize(delete)

            let insert = try prepare("""
                INSERT INTO photo_files(path, kind, modification_date, byte_size, capture_date)
                VALUES (?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(insert) }
            for file in files {
                sqlite3_reset(insert)
                sqlite3_clear_bindings(insert)
                bind(file.path, at: 1, to: insert)
                bind(file.kind.rawValue, at: 2, to: insert)
                sqlite3_bind_double(insert, 3, file.modificationDate.timeIntervalSince1970)
                sqlite3_bind_int64(insert, 4, file.byteSize)
                sqlite3_bind_double(insert, 5, file.captureDate.timeIntervalSince1970)
                guard sqlite3_step(insert) == SQLITE_DONE else {
                    throw PhotoCatalogError.unavailable(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func upsertFiles(_ files: [IndexedPhotoFile]) throws {
        guard !files.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare("""
                INSERT INTO photo_files(path, kind, modification_date, byte_size, capture_date)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    kind = excluded.kind,
                    modification_date = excluded.modification_date,
                    byte_size = excluded.byte_size,
                    capture_date = excluded.capture_date
                """)
            defer { sqlite3_finalize(statement) }
            for file in files {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(file.path, at: 1, to: statement)
                bind(file.kind.rawValue, at: 2, to: statement)
                sqlite3_bind_double(statement, 3, file.modificationDate.timeIntervalSince1970)
                sqlite3_bind_int64(statement, 4, file.byteSize)
                sqlite3_bind_double(statement, 5, file.captureDate.timeIntervalSince1970)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw PhotoCatalogError.unavailable(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func removePathsAndDescendants(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let statement = try prepare("DELETE FROM photo_files WHERE path = ? OR path LIKE ? ESCAPE '\\'")
            defer { sqlite3_finalize(statement) }
            for path in Set(paths) {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                bind(path, at: 1, to: statement)
                bind(escapeLike(path + "/") + "%", at: 2, to: statement)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw PhotoCatalogError.unavailable(errorMessage)
                }
            }

            let analysisStatement = try prepare(
                "DELETE FROM photo_analysis WHERE source_path = ? OR source_path LIKE ? ESCAPE '\\'"
            )
            defer { sqlite3_finalize(analysisStatement) }
            for path in Set(paths) {
                sqlite3_reset(analysisStatement)
                sqlite3_clear_bindings(analysisStatement)
                bind(path, at: 1, to: analysisStatement)
                bind(escapeLike(path + "/") + "%", at: 2, to: analysisStatement)
                guard sqlite3_step(analysisStatement) == SQLITE_DONE else {
                    throw PhotoCatalogError.unavailable(errorMessage)
                }
            }

            let scanStatement = try prepare(
                "DELETE FROM person_scans WHERE source_path = ? OR source_path LIKE ? ESCAPE '\\'"
            )
            defer { sqlite3_finalize(scanStatement) }
            let exportStatement = try prepare(
                "DELETE FROM xmp_exports WHERE source_path = ? OR source_path LIKE ? ESCAPE '\\'"
            )
            defer { sqlite3_finalize(exportStatement) }
            for path in Set(paths) {
                for target in [scanStatement, exportStatement] {
                    sqlite3_reset(target)
                    sqlite3_clear_bindings(target)
                    bind(path, at: 1, to: target)
                    bind(escapeLike(path + "/") + "%", at: 2, to: target)
                    guard sqlite3_step(target) == SQLITE_DONE else {
                        throw PhotoCatalogError.unavailable(errorMessage)
                    }
                }
            }
            try removeOrphanedClustersAndPeople()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func removeAllFiles() throws {
        try execute("DELETE FROM photo_files")
    }

    func indexedFileCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM photo_files")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func analyses(in folderURL: URL) throws -> [PhotoAnalysis] {
        let statement = try prepare("""
            SELECT photo_id, source_path, source_modification_date, model_identifier,
                   keywords_json, description, analyzed_at
            FROM photo_analysis
            WHERE source_path LIKE ? ESCAPE '\\'
            ORDER BY source_path
            """)
        defer { sqlite3_finalize(statement) }
        bind(scopePattern(for: folderURL), at: 1, to: statement)

        var results: [PhotoAnalysis] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let photoID = textColumn(statement, at: 0),
                  let sourcePath = textColumn(statement, at: 1),
                  let modelIdentifier = textColumn(statement, at: 3),
                  let keywordsJSON = textColumn(statement, at: 4),
                  let description = textColumn(statement, at: 5),
                  let keywordsData = keywordsJSON.data(using: .utf8),
                  let keywords = try? JSONDecoder().decode([String].self, from: keywordsData) else { continue }
            results.append(PhotoAnalysis(
                photoID: photoID,
                sourcePath: sourcePath,
                sourceModificationDate: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                modelIdentifier: modelIdentifier,
                keywords: keywords,
                description: description,
                analyzedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            ))
        }
        return results
    }

    func saveAnalysis(_ analysis: PhotoAnalysis) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try saveAnalysisInTransaction(analysis)
            let resetExport = try prepare("DELETE FROM xmp_exports WHERE photo_id = ?")
            defer { sqlite3_finalize(resetExport) }
            bind(analysis.photoID, at: 1, to: resetExport)
            guard sqlite3_step(resetExport) == SQLITE_DONE else {
                throw PhotoCatalogError.unavailable(errorMessage)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func saveAnalysisInTransaction(_ analysis: PhotoAnalysis) throws {
        let statement = try prepare("""
            INSERT INTO photo_analysis(
                photo_id, source_path, source_modification_date, model_identifier,
                keywords_json, description, analyzed_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET
                source_path = excluded.source_path,
                source_modification_date = excluded.source_modification_date,
                model_identifier = excluded.model_identifier,
                keywords_json = excluded.keywords_json,
                description = excluded.description,
                analyzed_at = excluded.analyzed_at
            """)
        defer { sqlite3_finalize(statement) }
        let keywordsData = try JSONEncoder().encode(analysis.keywords)
        guard let keywordsJSON = String(data: keywordsData, encoding: .utf8) else {
            throw PhotoCatalogError.unavailable("Schlagwörter konnten nicht gespeichert werden")
        }
        bind(analysis.photoID, at: 1, to: statement)
        bind(analysis.sourcePath, at: 2, to: statement)
        sqlite3_bind_double(statement, 3, analysis.sourceModificationDate.timeIntervalSince1970)
        bind(analysis.modelIdentifier, at: 4, to: statement)
        bind(keywordsJSON, at: 5, to: statement)
        bind(analysis.description, at: 6, to: statement)
        sqlite3_bind_double(statement, 7, analysis.analyzedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
    }

    func xmpExports(in folderURL: URL) throws -> [XMPExportRecord] {
        let statement = try prepare("""
            SELECT photo_id, source_path, keywords_json, sidecar_path, exported_at
            FROM xmp_exports AS export
            WHERE source_path LIKE ? ESCAPE '\\'
            ORDER BY source_path
            """)
        defer { sqlite3_finalize(statement) }
        bind(scopePattern(for: folderURL), at: 1, to: statement)

        var results: [XMPExportRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let photoID = textColumn(statement, at: 0),
                  let sourcePath = textColumn(statement, at: 1),
                  let keywordsJSON = textColumn(statement, at: 2),
                  let sidecarPath = textColumn(statement, at: 3) else { continue }
            results.append(XMPExportRecord(
                photoID: photoID,
                sourcePath: sourcePath,
                keywordsJSON: keywordsJSON,
                sidecarPath: sidecarPath,
                exportedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            ))
        }
        return results
    }

    func saveXMPExport(_ record: XMPExportRecord) throws {
        let statement = try prepare("""
            INSERT INTO xmp_exports(photo_id, source_path, keywords_json, sidecar_path, exported_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(photo_id) DO UPDATE SET
                source_path = excluded.source_path,
                keywords_json = excluded.keywords_json,
                sidecar_path = excluded.sidecar_path,
                exported_at = excluded.exported_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.photoID, at: 1, to: statement)
        bind(record.sourcePath, at: 2, to: statement)
        bind(record.keywordsJSON, at: 3, to: statement)
        bind(record.sidecarPath, at: 4, to: statement)
        sqlite3_bind_double(statement, 5, record.exportedAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
    }

    func analysisCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM photo_analysis")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func personDataCount() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM face_observations")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }


    func deleteAllPersonData() throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("DELETE FROM face_observations")
            try execute("DELETE FROM face_clusters")
            try execute("DELETE FROM person_scans")
            try execute("DELETE FROM people")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func removeOrphanedClustersAndPeople() throws {
        try execute("DELETE FROM face_clusters WHERE cluster_id NOT IN (SELECT DISTINCT cluster_id FROM face_observations)")
        try execute("DELETE FROM people WHERE person_id NOT IN (SELECT DISTINCT person_id FROM face_clusters WHERE person_id IS NOT NULL)")
    }

    private func migrateXMPExportsIfNeeded() throws {
        guard !tableHasColumn("xmp_exports", column: "source_path") else { return }
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try execute("""
                CREATE TABLE xmp_exports_v2 (
                    photo_id TEXT PRIMARY KEY NOT NULL,
                    source_path TEXT NOT NULL,
                    keywords_json TEXT NOT NULL,
                    sidecar_path TEXT NOT NULL,
                    exported_at REAL NOT NULL
                )
                """)
            try execute("""
                INSERT INTO xmp_exports_v2(photo_id, source_path, keywords_json, sidecar_path, exported_at)
                SELECT export.photo_id, analysis.source_path, export.keywords_json, export.sidecar_path, export.exported_at
                FROM xmp_exports AS export
                INNER JOIN photo_analysis AS analysis ON analysis.photo_id = export.photo_id
                """)
            try execute("DROP TABLE xmp_exports")
            try execute("ALTER TABLE xmp_exports_v2 RENAME TO xmp_exports")
            try execute("CREATE INDEX xmp_exports_source_path_index ON xmp_exports(source_path)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func migratePersonScansIfNeeded() throws {
        guard !tableHasColumn("person_scans", column: "clustering_identifier") else { return }
        try execute(
            "ALTER TABLE person_scans ADD COLUMN clustering_identifier TEXT NOT NULL DEFAULT 'removed-feature-legacy'"
        )
    }

    private func tableHasColumn(_ table: String, column: String) -> Bool {
        guard let statement = try? prepare("PRAGMA table_info(\(table))") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if textColumn(statement, at: 1) == column { return true }
        }
        return false
    }

    private var errorMessage: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "Keine Datenbank geöffnet"
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw PhotoCatalogError.unavailable("Keine Datenbank geöffnet") }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw PhotoCatalogError.unavailable(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let database else { throw PhotoCatalogError.unavailable("Keine Datenbank geöffnet") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PhotoCatalogError.unavailable(errorMessage)
        }
        return statement
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func textColumn(_ statement: OpaquePointer, at index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func scopePattern(for folderURL: URL) -> String {
        let path = folderURL.standardizedFileURL.path
        let prefix = path == "/" ? "/" : path + "/"
        return escapeLike(prefix) + "%"
    }

    private func escapeLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
