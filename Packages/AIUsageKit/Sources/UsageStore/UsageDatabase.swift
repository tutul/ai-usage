import Foundation
import GRDB
import UsageCore

public struct CurrentReading: Sendable, Hashable {
    public let service: Service
    public let windowKind: String
    public let observedAt: Date
    public let percent: Double
    public let resetsAt: Date?
}

public struct HourlyBucket: Sendable, Hashable {
    public let hourLocal: String
    public let hourStart: Date
    public let usedPercent: Double?
    public let unknownPercent: Double?
    public let unattributedPairs: Int
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
        try Self.migrator.migrate(pool)
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            guard let url = Bundle.module.url(forResource: "schema", withExtension: "sql") else {
                fatalError("schema.sql 未包含在 bundle 中")
            }
            try db.execute(sql: String(contentsOf: url, encoding: .utf8))
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
                    resetsAt: resets.map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }
    }

    public func hourly(service: Service, windowKind: String = "weekly", since: Date) throws -> [HourlyBucket] {
        try pool.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT hour_local, hour_start_epoch, used_percent, unknown_percent, unattributed_pairs
                  FROM v_hourly
                 WHERE service = ? AND window_kind = ? AND hour_start_epoch >= ?
                 ORDER BY hour_start_epoch
                """,
                arguments: [service.rawValue, windowKind, Int(since.timeIntervalSince1970)]
            ).map { row in
                HourlyBucket(
                    hourLocal: row["hour_local"],
                    hourStart: Date(timeIntervalSince1970: TimeInterval(row["hour_start_epoch"] as Int)),
                    usedPercent: row["used_percent"],
                    unknownPercent: row["unknown_percent"],
                    unattributedPairs: row["unattributed_pairs"] ?? 0
                )
            }
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
