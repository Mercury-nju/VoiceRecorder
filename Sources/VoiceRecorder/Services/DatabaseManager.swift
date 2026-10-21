import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: LocalizedError {
    case sqlite(message: String)

    var errorDescription: String? {
        switch self {
        case .sqlite(let message): return message
        }
    }
}

final class DatabaseManager: @unchecked Sendable {
    private var database: OpaquePointer?
    private let queue = DispatchQueue(label: "com.local.voicerecorder.database", qos: .utility)

    init(url: URL) throws {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let handle else {
            defer { if let handle { sqlite3_close(handle) } }
            throw DatabaseError.sqlite(message: "无法创建本地索引数据库")
        }
        database = handle
        try queue.sync {
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
            try execute("PRAGMA synchronous = FULL;")
            try execute("""
                CREATE TABLE IF NOT EXISTS segments (
                    id TEXT PRIMARY KEY NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    path TEXT NOT NULL,
                    transcription_state TEXT NOT NULL DEFAULT 'queued',
                    created_at REAL NOT NULL
                );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_segments_range ON segments(start_time, end_time);")
            try execute("""
                CREATE TABLE IF NOT EXISTS transcript_items (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    segment_id TEXT NOT NULL REFERENCES segments(id) ON DELETE CASCADE,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    text TEXT NOT NULL
                );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_transcript_range ON transcript_items(start_time, end_time);")
            try execute("CREATE INDEX IF NOT EXISTS idx_transcript_segment ON transcript_items(segment_id);")
            try execute("""
                CREATE TABLE IF NOT EXISTS transcription_jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    segment_id TEXT NOT NULL,
                    start_time REAL NOT NULL,
                    end_time REAL NOT NULL,
                    path TEXT NOT NULL,
                    state TEXT NOT NULL DEFAULT 'queued',
                    attempts INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL
                );
            """)
            try execute("CREATE INDEX IF NOT EXISTS idx_transcription_jobs_state ON transcription_jobs(state, created_at);")
            try execute("CREATE TABLE IF NOT EXISTS favorites (transcript_id INTEGER PRIMARY KEY NOT NULL, created_at REAL NOT NULL);")
            try execute("CREATE TABLE IF NOT EXISTS search_history (query TEXT PRIMARY KEY NOT NULL, searched_at REAL NOT NULL);")
            try execute("""
                CREATE VIRTUAL TABLE IF NOT EXISTS transcript_fts USING fts5(
                    item_id UNINDEXED,
                    text,
                    tokenize = 'unicode61 remove_diacritics 2'
                );
            """)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func insert(segment: RecordingSegment) throws {
        try queue.sync {
            let placeholder = try prepare("INSERT OR IGNORE INTO segments(id, start_time, end_time, path, transcription_state, created_at) VALUES(?, ?, ?, ?, ?, ?);")
            defer { sqlite3_finalize(placeholder) }
            bind(segment.id, to: placeholder, at: 1)
            sqlite3_bind_double(placeholder, 2, segment.startTime.timeIntervalSince1970)
            sqlite3_bind_double(placeholder, 3, segment.endTime.timeIntervalSince1970)
            bind(segment.fileURL.path, to: placeholder, at: 4)
            bind(segment.transcriptionState, to: placeholder, at: 5)
            sqlite3_bind_double(placeholder, 6, Date().timeIntervalSince1970)
            try stepDone(placeholder)
            let sql = """
                INSERT INTO segments(id, start_time, end_time, path, transcription_state, created_at)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET end_time=excluded.end_time, path=excluded.path,
                    transcription_state=excluded.transcription_state;
            """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(segment.id, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, segment.startTime.timeIntervalSince1970)
            sqlite3_bind_double(statement, 3, segment.endTime.timeIntervalSince1970)
            bind(segment.fileURL.path, to: statement, at: 4)
            bind(segment.transcriptionState, to: statement, at: 5)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    func enqueueTranscriptionJob(id: String, parentSegmentID: String, start: Date, end: Date, fileURL: URL) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                let parent = try prepare("INSERT OR IGNORE INTO segments(id, start_time, end_time, path, transcription_state, created_at) VALUES(?, ?, ?, ?, 'queued', ?);")
                bind(parentSegmentID, to: parent, at: 1)
                sqlite3_bind_double(parent, 2, start.timeIntervalSince1970)
                sqlite3_bind_double(parent, 3, start.timeIntervalSince1970)
                bind(fileURL.path, to: parent, at: 4)
                sqlite3_bind_double(parent, 5, Date().timeIntervalSince1970)
                try stepDone(parent)
                sqlite3_finalize(parent)
                let job = try prepare("INSERT OR IGNORE INTO transcription_jobs(id, segment_id, start_time, end_time, path, state, created_at) VALUES(?, ?, ?, ?, ?, 'queued', ?);")
                bind(id, to: job, at: 1)
                bind(parentSegmentID, to: job, at: 2)
                sqlite3_bind_double(job, 3, start.timeIntervalSince1970)
                sqlite3_bind_double(job, 4, end.timeIntervalSince1970)
                bind(fileURL.path, to: job, at: 5)
                sqlite3_bind_double(job, 6, Date().timeIntervalSince1970)
                try stepDone(job)
                sqlite3_finalize(job)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func pendingTranscriptionJobs() -> [TranscriptionJob] {
        queue.sync {
            try? execute("UPDATE transcription_jobs SET state = 'queued' WHERE state = 'processing';")
            guard let statement = try? prepare("SELECT id, segment_id, start_time, end_time, path, attempts FROM transcription_jobs WHERE state IN ('queued', 'failed') ORDER BY created_at ASC;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var jobs: [TranscriptionJob] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = sqlite3_column_text(statement, 0), let segmentID = sqlite3_column_text(statement, 1), let path = sqlite3_column_text(statement, 4) else { continue }
                jobs.append(TranscriptionJob(id: String(cString: id), segmentID: String(cString: segmentID), startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)), endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)), fileURL: URL(fileURLWithPath: String(cString: path)), attempts: Int(sqlite3_column_int(statement, 5))))
            }
            return jobs
        }
    }

    func updateTranscriptionJob(id: String, state: TranscriptionState) throws {
        try queue.sync {
            let statement = try prepare("UPDATE transcription_jobs SET state = ?, attempts = attempts + CASE WHEN ? = 'failed' THEN 1 ELSE 0 END WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            bind(state.rawValue, to: statement, at: 1)
            bind(state.rawValue, to: statement, at: 2)
            bind(id, to: statement, at: 3)
            try stepDone(statement)
        }
    }

    func appendTranscript(for job: TranscriptionJob, items: [(start: Date, end: Date, text: String)]) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                let deleteFTS = try prepare("DELETE FROM transcript_fts WHERE item_id IN (SELECT id FROM transcript_items WHERE segment_id = ? AND start_time >= ? AND start_time < ?);")
                bind(job.segmentID, to: deleteFTS, at: 1)
                sqlite3_bind_double(deleteFTS, 2, job.startTime.timeIntervalSince1970)
                sqlite3_bind_double(deleteFTS, 3, job.endTime.timeIntervalSince1970)
                try stepDone(deleteFTS)
                sqlite3_finalize(deleteFTS)
                let deleteItems = try prepare("DELETE FROM transcript_items WHERE segment_id = ? AND start_time >= ? AND start_time < ?;")
                bind(job.segmentID, to: deleteItems, at: 1)
                sqlite3_bind_double(deleteItems, 2, job.startTime.timeIntervalSince1970)
                sqlite3_bind_double(deleteItems, 3, job.endTime.timeIntervalSince1970)
                try stepDone(deleteItems)
                sqlite3_finalize(deleteItems)
                let insert = try prepare("INSERT INTO transcript_items(segment_id, start_time, end_time, text) VALUES(?, ?, ?, ?);")
                let fts = try prepare("INSERT INTO transcript_fts(item_id, text) VALUES(?, ?);")
                defer { sqlite3_finalize(insert); sqlite3_finalize(fts) }
                for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    bind(job.segmentID, to: insert, at: 1)
                    sqlite3_bind_double(insert, 2, item.start.timeIntervalSince1970)
                    sqlite3_bind_double(insert, 3, item.end.timeIntervalSince1970)
                    bind(item.text, to: insert, at: 4)
                    try stepDone(insert)
                    let itemID = sqlite3_last_insert_rowid(database)
                    sqlite3_reset(fts); sqlite3_clear_bindings(fts)
                    bind(String(itemID), to: fts, at: 1); bind(item.text, to: fts, at: 2)
                    try stepDone(fts)
                }
                let done = try prepare("UPDATE transcription_jobs SET state = 'complete' WHERE id = ?;")
                bind(job.id, to: done, at: 1); try stepDone(done); sqlite3_finalize(done)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func updateTranscriptionState(segmentID: String, state: TranscriptionState) throws {
        try queue.sync {
            let statement = try prepare("UPDATE segments SET transcription_state = ? WHERE id = ?;")
            defer { sqlite3_finalize(statement) }
            bind(state.rawValue, to: statement, at: 1)
            bind(segmentID, to: statement, at: 2)
            try stepDone(statement)
        }
    }

    func replaceTranscript(for segment: RecordingSegment, items: [(start: Date, end: Date, text: String)]) throws {
        try queue.sync {
            try execute("BEGIN IMMEDIATE;")
            do {
                let deleteFTS = try prepare("DELETE FROM transcript_fts WHERE item_id IN (SELECT id FROM transcript_items WHERE segment_id = ?);")
                bind(segment.id, to: deleteFTS, at: 1)
                try stepDone(deleteFTS)
                sqlite3_finalize(deleteFTS)

                let deleteItems = try prepare("DELETE FROM transcript_items WHERE segment_id = ?;")
                bind(segment.id, to: deleteItems, at: 1)
                try stepDone(deleteItems)
                sqlite3_finalize(deleteItems)

                let itemStatement = try prepare("INSERT INTO transcript_items(segment_id, start_time, end_time, text) VALUES(?, ?, ?, ?);")
                let ftsStatement = try prepare("INSERT INTO transcript_fts(item_id, text) VALUES(?, ?);")
                defer {
                    sqlite3_finalize(itemStatement)
                    sqlite3_finalize(ftsStatement)
                }
                for item in items where !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sqlite3_reset(itemStatement)
                    sqlite3_clear_bindings(itemStatement)
                    bind(segment.id, to: itemStatement, at: 1)
                    sqlite3_bind_double(itemStatement, 2, item.start.timeIntervalSince1970)
                    sqlite3_bind_double(itemStatement, 3, item.end.timeIntervalSince1970)
                    bind(item.text, to: itemStatement, at: 4)
                    try stepDone(itemStatement)
                    let itemID = sqlite3_last_insert_rowid(database)

                    sqlite3_reset(ftsStatement)
                    sqlite3_clear_bindings(ftsStatement)
                    bind(String(itemID), to: ftsStatement, at: 1)
                    bind(item.text, to: ftsStatement, at: 2)
                    try stepDone(ftsStatement)
                }
                try updateStateWithoutQueue(segmentID: segment.id, state: .complete)
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    func segments(on day: Date) -> [RecordingSegment] {
        segments(overlapping: DateTools.startOfDay(day), and: DateTools.endOfDay(day))
    }

    func segments(overlapping start: Date, and end: Date) -> [RecordingSegment] {
        queue.sync {
            let sql = """
                SELECT id, start_time, end_time, path, transcription_state FROM segments
                WHERE start_time < ? AND end_time > ? ORDER BY start_time ASC;
            """
            guard let statement = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
            return rows(from: statement)
        }
    }

    func transcriptItems(on day: Date) -> [TranscriptItem] {
        transcriptItems(between: DateTools.startOfDay(day), and: DateTools.endOfDay(day))
    }

    func transcriptItems(between start: Date, and end: Date) -> [TranscriptItem] {
        queue.sync {
            let sql = """
                SELECT id, segment_id, start_time, end_time, text FROM transcript_items
                WHERE start_time < ? AND end_time > ? ORDER BY start_time ASC;
            """
            guard let statement = try? prepare(sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, end.timeIntervalSince1970)
            sqlite3_bind_double(statement, 2, start.timeIntervalSince1970)
            return transcriptRows(from: statement)
        }
    }

    func searchTranscript(_ text: String, limit: Int = 100) -> [TranscriptItem] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return queue.sync {
            var output: [TranscriptItem] = []
            var seen = Set<Int64>()

            // FTS5 is effective for Latin words and phrases. Chinese retrieval falls back to LIKE below.
            let fts = query
                .split(whereSeparator: { $0.isWhitespace })
                .map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                .joined(separator: " AND ")
            if !fts.isEmpty, let statement = try? prepare("""
                SELECT t.id, t.segment_id, t.start_time, t.end_time, t.text
                FROM transcript_fts f JOIN transcript_items t ON f.item_id = CAST(t.id AS TEXT)
                WHERE transcript_fts MATCH ? ORDER BY t.start_time DESC LIMIT ?;
            """) {
                bind(fts, to: statement, at: 1)
                sqlite3_bind_int(statement, 2, Int32(limit))
                for row in transcriptRows(from: statement) where seen.insert(row.id).inserted {
                    output.append(row)
                }
                sqlite3_finalize(statement)
            }

            if output.count < limit, let statement = try? prepare("""
                SELECT id, segment_id, start_time, end_time, text FROM transcript_items
                WHERE text LIKE ? COLLATE NOCASE ORDER BY start_time DESC LIMIT ?;
            """) {
                bind("%\(query)%", to: statement, at: 1)
                sqlite3_bind_int(statement, 2, Int32(limit))
                for row in transcriptRows(from: statement) where seen.insert(row.id).inserted {
                    output.append(row)
                }
                sqlite3_finalize(statement)
            }
            return Array(output.prefix(limit)).sorted { $0.startTime > $1.startTime }
        }
    }

    func availableDays() -> [Date] {
        queue.sync {
            guard let statement = try? prepare("SELECT DISTINCT start_time FROM segments WHERE end_time > start_time ORDER BY start_time DESC;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var dates: [Date] = []
            var seen = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
                let day = DateTools.startOfDay(date)
                if seen.insert(DateTools.storageDate(day)).inserted { dates.append(day) }
            }
            return dates
        }
    }

    func setFavorite(_ transcriptID: Int64, enabled: Bool) throws {
        try queue.sync {
            let statement = try prepare(enabled
                ? "INSERT OR IGNORE INTO favorites(transcript_id, created_at) VALUES(?, ?);"
                : "DELETE FROM favorites WHERE transcript_id = ?;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, transcriptID)
            if enabled { sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970) }
            try stepDone(statement)
        }
    }

    func favoriteTranscriptIDs() -> [Int64] {
        queue.sync {
            guard let statement = try? prepare("SELECT transcript_id FROM favorites ORDER BY created_at DESC;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var ids: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW { ids.append(sqlite3_column_int64(statement, 0)) }
            return ids
        }
    }

    func favoriteTranscriptItems() -> [TranscriptItem] {
        queue.sync {
            guard let statement = try? prepare("SELECT t.id, t.segment_id, t.start_time, t.end_time, t.text FROM favorites f JOIN transcript_items t ON t.id = f.transcript_id ORDER BY f.created_at DESC;") else { return [] }
            defer { sqlite3_finalize(statement) }
            return transcriptRows(from: statement)
        }
    }

    func recordSearch(_ query: String) throws {
        try queue.sync {
            let statement = try prepare("INSERT INTO search_history(query, searched_at) VALUES(?, ?) ON CONFLICT(query) DO UPDATE SET searched_at=excluded.searched_at;")
            defer { sqlite3_finalize(statement) }
            bind(query, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            try stepDone(statement)
            try execute("DELETE FROM search_history WHERE query NOT IN (SELECT query FROM search_history ORDER BY searched_at DESC LIMIT 30);")
        }
    }

    func recentSearches() -> [String] {
        queue.sync {
            guard let statement = try? prepare("SELECT query FROM search_history ORDER BY searched_at DESC LIMIT 30;") else { return [] }
            defer { sqlite3_finalize(statement) }
            var searches: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let query = sqlite3_column_text(statement, 0) { searches.append(String(cString: query)) }
            }
            return searches
        }
    }

    func allSegments() -> [RecordingSegment] {
        queue.sync {
            guard let statement = try? prepare("SELECT id, start_time, end_time, path, transcription_state FROM segments WHERE end_time > start_time ORDER BY start_time ASC;") else { return [] }
            defer { sqlite3_finalize(statement) }
            return rows(from: statement)
        }
    }

    func deleteAllRecords() throws -> [URL] {
        try queue.sync {
            let paths = allSegmentPathsWithoutQueue()
            try execute("DELETE FROM transcript_fts;")
            try execute("DELETE FROM transcript_items;")
            try execute("DELETE FROM favorites;")
            try execute("DELETE FROM search_history;")
            try execute("DELETE FROM segments;")
            return paths
        }
    }

    private func updateStateWithoutQueue(segmentID: String, state: TranscriptionState) throws {
        let statement = try prepare("UPDATE segments SET transcription_state = ? WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(state.rawValue, to: statement, at: 1)
        bind(segmentID, to: statement, at: 2)
        try stepDone(statement)
    }

    private func allSegmentPathsWithoutQueue() -> [URL] {
        guard let statement = try? prepare("SELECT path FROM segments;") else { return [] }
        defer { sqlite3_finalize(statement) }
        var urls: [URL] = []
        while sqlite3_step(statement) == SQLITE_ROW, let cString = sqlite3_column_text(statement, 0) {
            urls.append(URL(fileURLWithPath: String(cString: cString)))
        }
        return urls
    }

    private func rows(from statement: OpaquePointer?) -> [RecordingSegment] {
        var records: [RecordingSegment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let idString = sqlite3_column_text(statement, 0),
                  let pathString = sqlite3_column_text(statement, 3),
                  let stateString = sqlite3_column_text(statement, 4) else { continue }
            records.append(RecordingSegment(
                id: String(cString: idString),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                fileURL: URL(fileURLWithPath: String(cString: pathString)),
                transcriptionState: String(cString: stateString)
            ))
        }
        return records
    }

    private func transcriptRows(from statement: OpaquePointer?) -> [TranscriptItem] {
        var records: [TranscriptItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let segmentID = sqlite3_column_text(statement, 1), let text = sqlite3_column_text(statement, 4) else { continue }
            records.append(TranscriptItem(
                id: sqlite3_column_int64(statement, 0),
                segmentID: String(cString: segmentID),
                startTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                endTime: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                text: String(cString: text)
            ))
        }
        return records
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw lastError()
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite 操作失败"
            sqlite3_free(errorMessage)
            throw DatabaseError.sqlite(message: message)
        }
    }

    private func lastError() -> DatabaseError {
        DatabaseError.sqlite(message: database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 不可用")
    }
}
