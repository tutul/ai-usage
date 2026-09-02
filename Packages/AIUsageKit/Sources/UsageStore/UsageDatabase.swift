import Foundation
import GRDB
import UsageCore

public struct CurrentReading: Sendable, Hashable {
    public let service: Service
    public let windowKind: String
    public let observedAt: Date
    public let percent: Double
    public let resetsAt: Date?
    /// 窗是否已開始計時。未開始時 resets_at 是「現在 + 窗長」的佔位值，
    /// 倒數永遠不會減少，不該顯示。
    public let windowStarted: Bool
    public let windowSeconds: Int?
}

public enum Granularity: String, Sendable, CaseIterable, Hashable {
    case hour
    case day

    var view: String { self == .hour ? "v_hourly" : "v_daily" }
    var keyColumn: String { self == .hour ? "hour_local" : "day_local" }
    var epochColumn: String { self == .hour ? "hour_start_epoch" : "day_start_epoch" }
    public var displayName: String { self == .hour ? "小時" : "日" }
}

/// 分桶消耗。小時與日共用同一型別 —— 兩者的欄位語意完全相同，
/// 分成兩種型別只會讓圖表程式碼寫兩份。
public struct UsageBucket: Sendable, Hashable {
    public let key: String
    public let start: Date
    public let usedPercent: Double?
    public let unknownPercent: Double?
    /// 這個桶由幾組相鄰樣本推導而來。數字太小代表取樣稀疏，數值可信度較低。
    public let pairCount: Int
    public let unattributedPairs: Int
}

/// 單次取樣嘗試的結果，供視窗上的日誌顯示。
public struct RecentFetch: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let service: Service
    public let completedAt: Date
    public let ok: Bool
    public let httpStatus: Int?
    public let errorKind: String?
    public let errorDetail: String?
    /// 該次取樣得到的週用量。失敗時為 nil。
    public let weeklyPercent: Double?
}

public struct Health: Sendable, Hashable {
    public let service: Service
    public let lastSuccessAt: Date?
    public let lastAttemptAt: Date?
    public let lastWeeklyAt: Date?
    public let failuresTotal: Int
}

public final class UsageDatabase: Sendable {
    let pool: DatabasePool

    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appending(path: "AIUsage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "usage.sqlite")
    }

    public init(url: URL) throws {
        var config = Configuration()
        // 多行程共享：app 是唯一 writer，外部分析工具為唯讀 reader。
        // DatabasePool 自動採用 WAL；busy timeout 讓寫入等待而非拋 SQLITE_BUSY。
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        // 早期版本以 "v1" 註冊初始 migration；改為編號檔名後需認得舊紀錄，
        // 否則既有資料庫會重跑 001 而撞上已存在的表。
        try pool.write { db in
            if try db.tableExists("grdb_migrations") {
                try db.execute(sql: "UPDATE grdb_migrations SET identifier = '001_initial' WHERE identifier = 'v1'")
            }
        }
        try Self.migrator.migrate(pool)
    }

    /// Migration 以 `Resources/NNN_name.sql` 的檔名順序註冊。
    /// 已套用過的檔案**不得再修改** —— 既有資料庫不會重跑它。
    /// 要改 schema 或 view，新增下一個編號的檔案。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        let urls = (Bundle.module.urls(forResourcesWithExtension: "sql", subdirectory: "Resources") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(!urls.isEmpty, "找不到 migration SQL，Resources 未被打包進 bundle")
        for url in urls {
            let name = url.deletingPathExtension().lastPathComponent
            migrator.registerMigration(name) { db in
                try db.execute(sql: String(contentsOf: url, encoding: .utf8))
            }
        }
        return migrator
    }

    // MARK: - 寫入

    /// 記錄一次成功取樣。**每次都寫 `sample`（即使數值未變）** ——
    /// 「值沒變」本身就是資訊，少了它就無法區分「沒用」與「沒觀測」。
    /// `raw_payload` 則僅在解析值或 JSON 結構變化時才寫。
    @discardableResult
    public func record(_ snapshot: UsageSnapshot) throws -> Int64 {
        try pool.write { db in
            let service = snapshot.service.rawValue
            let observedAt = Int(snapshot.observedAt.timeIntervalSince1970)

            let shape = JSONShape.fingerprint(body: snapshot.rawBody)
            let reason = try Self.rawRetentionReason(db, snapshot: snapshot, shape: shape)
            var rawID: Int64?
            if let reason {
                try db.execute(
                    sql: """
                    INSERT INTO raw_payload(service, captured_at, body, shape_sha256, reason)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                    arguments: [service, observedAt, snapshot.rawBody, shape, reason]
                )
                rawID = db.lastInsertedRowID
            }

            // HTTP 成功但沒有週窗 —— 記為資訊性標記，不謊稱失敗，也不假裝完整。
            let missingWeekly = snapshot.weekly == nil
            try db.execute(
                sql: """
                INSERT INTO fetch(service, started_at, completed_at, ok, http_status, error_kind, raw_id)
                VALUES (?, ?, ?, 1, 200, ?, ?)
                """,
                arguments: [service, observedAt, observedAt,
                            missingWeekly ? FetchErrorKind.missingWindow.rawValue : nil, rawID]
            )
            let fetchID = db.lastInsertedRowID

            for window in snapshot.windows {
                try db.execute(
                    sql: """
                    INSERT INTO sample(fetch_id, service, window_kind, observed_at,
                                       percent, resets_at, window_seconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [fetchID, service, window.kind.storageKey, observedAt,
                                window.percent,
                                window.resetsAt.map { Int($0.timeIntervalSince1970) },
                                window.kind.seconds]
                )
            }
            return fetchID
        }
    }

    /// 記錄一次失敗嘗試。失敗也要留痕，否則「抓不到」看不出來。
    public func record(failure: FetchFailure, service: Service, startedAt: Date, completedAt: Date) throws {
        try pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO fetch(service, started_at, completed_at, ok, http_status, error_kind, error_detail)
                VALUES (?, ?, ?, 0, ?, ?, ?)
                """,
                arguments: [service.rawValue,
                            Int(startedAt.timeIntervalSince1970), Int(completedAt.timeIntervalSince1970),
                            failure.httpStatus, failure.kind.rawValue, failure.detail]
            )
        }
    }

    /// 決定是否留存原始回應：首次、結構改版、或解析值有變。
    /// 不比對整包 body —— Codex 的 `reset_after_seconds` 每次都不同。
    static func rawRetentionReason(_ db: Database, snapshot: UsageSnapshot, shape: String) throws -> String? {
        let service = snapshot.service.rawValue
        let lastShape = try String.fetchOne(
            db,
            sql: "SELECT shape_sha256 FROM raw_payload WHERE service = ? ORDER BY captured_at DESC, id DESC LIMIT 1",
            arguments: [service]
        )
        if lastShape == nil { return "first" }
        if lastShape != shape { return "shape_change" }

        for window in snapshot.windows {
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT percent, resets_at FROM sample
                 WHERE service = ? AND window_kind = ?
                 ORDER BY observed_at DESC, id DESC LIMIT 1
                """,
                arguments: [service, window.kind.storageKey]
            )
            guard let row else { return "value_change" }
            let previousPercent: Double = row["percent"]
            let previousResets: Int? = row["resets_at"]
            if previousPercent != window.percent { return "value_change" }
            if previousResets != window.resetsAt.map({ Int($0.timeIntervalSince1970) }) { return "value_change" }
        }
        return nil
    }

    // MARK: - 讀取（一律經由 view，與外部分析工具共用同一份規則）

    public func current() throws -> [CurrentReading] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v_current ORDER BY service, window_kind").compactMap { row in
                guard let service = Service(rawValue: row["service"]) else { return nil }
                let resets: Int? = row["resets_at"]
                return CurrentReading(
                    service: service,
                    windowKind: row["window_kind"],
                    observedAt: Date(timeIntervalSince1970: TimeInterval(row["observed_at"] as Int)),
                    percent: row["percent"],
                    resetsAt: resets.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    windowStarted: (row["window_started"] as Int? ?? 0) == 1,
                    windowSeconds: row["window_seconds"]
                )
            }
        }
    }

    public func buckets(
        service: Service,
        windowKind: String = "weekly",
        granularity: Granularity,
        since: Date,
        until: Date? = nil
    ) throws -> [UsageBucket] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT \(granularity.keyColumn) AS bucket_key,
                       \(granularity.epochColumn) AS bucket_start,
                       used_percent, unknown_percent, pair_count, unattributed_pairs
                  FROM \(granularity.view)
                 WHERE service = ? AND window_kind = ?
                   AND \(granularity.epochColumn) >= ?
                   AND (? IS NULL OR \(granularity.epochColumn) <= ?)
                 ORDER BY bucket_start
                """,
                arguments: [
                    service.rawValue, windowKind,
                    Int(since.timeIntervalSince1970),
                    until.map { Int($0.timeIntervalSince1970) },
                    until.map { Int($0.timeIntervalSince1970) }
                ]
            ).map { row in
                UsageBucket(
                    key: row["bucket_key"],
                    start: Date(timeIntervalSince1970: TimeInterval(row["bucket_start"] as Int)),
                    usedPercent: row["used_percent"],
                    unknownPercent: row["unknown_percent"],
                    pairCount: row["pair_count"] ?? 0,
                    unattributedPairs: row["unattributed_pairs"] ?? 0
                )
            }
        }
    }

    /// 最近的取樣嘗試，成功與失敗都包含 —— 日誌的價值就在於看得到失敗。
    /// 最早的樣本時間，供「全部」與日期選擇器的下界用。
    public func earliestSample() throws -> Date? {
        try pool.read { db in
            try Int.fetchOne(db, sql: "SELECT MIN(observed_at) FROM sample")
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        }
    }

    public func recentFetches(limit: Int = 10) throws -> [RecentFetch] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT f.id, f.service, f.completed_at, f.ok, f.http_status,
                       f.error_kind, f.error_detail,
                       (SELECT s.percent FROM sample s
                         WHERE s.fetch_id = f.id AND s.window_kind = 'weekly' LIMIT 1) AS weekly_percent
                  FROM fetch f
                 ORDER BY f.completed_at DESC, f.id DESC
                 LIMIT ?
                """,
                arguments: [limit]
            ).compactMap { row in
                guard let service = Service(rawValue: row["service"]) else { return nil }
                return RecentFetch(
                    id: row["id"],
                    service: service,
                    completedAt: Date(timeIntervalSince1970: TimeInterval(row["completed_at"] as Int)),
                    ok: (row["ok"] as Int) == 1,
                    httpStatus: row["http_status"],
                    errorKind: row["error_kind"],
                    errorDetail: row["error_detail"],
                    weeklyPercent: row["weekly_percent"]
                )
            }
        }
    }

    /// 目前是否處於失敗狀態，以及失敗原因。
    /// 只在「最後一次嘗試失敗」時回傳 —— 已經恢復的舊失敗不該再影響 UI。
    public func currentFailure(service: Service) throws -> (kind: String, detail: String)? {
        try pool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT ok, error_kind, error_detail FROM fetch
                 WHERE service = ? ORDER BY completed_at DESC, id DESC LIMIT 1
                """,
                arguments: [service.rawValue]
            ) else { return nil }
            guard (row["ok"] as Int) == 0 else { return nil }
            return (row["error_kind"] ?? "unknown", row["error_detail"] ?? "")
        }
    }

    public func health() throws -> [Health] {
        try pool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM v_health").compactMap { row in
                guard let service = Service(rawValue: row["service"]) else { return nil }
                func date(_ column: String) -> Date? {
                    (row[column] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                }
                return Health(
                    service: service,
                    lastSuccessAt: date("last_success_at"),
                    lastAttemptAt: date("last_attempt_at"),
                    lastWeeklyAt: date("last_weekly_at"),
                    failuresTotal: row["failures_total"] ?? 0
                )
            }
        }
    }
}
