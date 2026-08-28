import Testing
import Foundation
import UsageCore
@testable import UsageStore
import GRDB

private func tempDB() throws -> UsageDatabase {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aiusage-test-\(UUID().uuidString).sqlite")
    return try UsageDatabase(url: url)
}

private func snapshot(
    _ service: Service = .codex, percent: Double, resetsAt: Int, at: Date, raw: String? = nil
) -> UsageSnapshot {
    UsageSnapshot(
        service: service, observedAt: at,
        windows: [.init(kind: .weekly, percent: percent,
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(resetsAt)))],
        rawBody: raw ?? #"{"rate_limit":{"primary_window":{"used_percent":\#(Int(percent)),"limit_window_seconds":604800}}}"#
    )
}

@Suite("寫入與留存")
struct RecordTests {
    @Test("每次取樣都寫 sample，即使數值未變")
    func samplesAlwaysWritten() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_787_000_000)
        for i in 0..<3 {
            try db.record(snapshot(percent: 5, resetsAt: 1_787_500_000, at: base.addingTimeInterval(Double(i) * 300)))
        }
        let readings = try db.current()
        #expect(readings.count == 1)
        let count = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sample") }
        #expect(count == 3, "值沒變也必須留下樣本，否則無法區分『沒用』與『沒觀測』")
    }

    @Test("raw_payload 只在值變或結構變時留存")
    func rawDeduped() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_787_000_000)
        // 三筆相同值、但 body 中的易變欄位不同
        for i in 0..<3 {
            let raw = #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_after_seconds":\#(9000 - i)}}}"#
            try db.record(snapshot(percent: 5, resetsAt: 1_787_500_000,
                                   at: base.addingTimeInterval(Double(i) * 300), raw: raw))
        }
        var rawCount = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM raw_payload") }
        #expect(rawCount == 1, "易變欄位變動不應觸發留存，否則儲存量回到 200MB/年")

        // 值改變 -> 留存
        try db.record(snapshot(percent: 6, resetsAt: 1_787_500_000, at: base.addingTimeInterval(900)))
        rawCount = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM raw_payload") }
        #expect(rawCount == 2)
    }

    @Test("HTTP 成功但缺週窗 -> 標記 missing_window，且 last_weekly_at 不前進")
    func missingWeekly() throws {
        let db = try tempDB()
        let t0 = Date(timeIntervalSince1970: 1_787_000_000)
        try db.record(snapshot(percent: 5, resetsAt: 1_787_500_000, at: t0))

        // 只有 5 小時窗、沒有週窗
        try db.record(UsageSnapshot(
            service: .codex, observedAt: t0.addingTimeInterval(300),
            windows: [.init(kind: .session, percent: 40, resetsAt: nil)],
            rawBody: #"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000}}}"#
        ))

        let health = try db.health().first { $0.service == .codex }
        #expect(health?.lastWeeklyAt == t0, "週資料的新鮮度必須停在最後一次真的拿到週窗的時刻")
        #expect(health?.lastSuccessAt == t0.addingTimeInterval(300), "HTTP 層仍算成功")
        let kind = try db.pool.read {
            try String.fetchOne($0, sql: "SELECT error_kind FROM fetch ORDER BY id DESC LIMIT 1")
        }
        #expect(kind == "missing_window")
    }

    @Test("失敗留痕，且 auth 與 blocked 分開")
    func failuresRecorded() throws {
        let db = try tempDB()
        let t = Date(timeIntervalSince1970: 1_787_000_000)
        try db.record(failure: .init(kind: .blocked, httpStatus: 403, detail: "cloudflare"),
                      service: .codex, startedAt: t, completedAt: t)
        try db.record(failure: .init(kind: .auth, httpStatus: 401, detail: "expired"),
                      service: .codex, startedAt: t, completedAt: t)
        let kinds = try db.pool.read {
            try String.fetchAll($0, sql: "SELECT error_kind FROM fetch ORDER BY id")
        }
        #expect(kinds == ["blocked", "auth"])
        #expect(try db.health().first?.failuresTotal == 2)
    }
}

@Suite("View 行為")
struct ViewTests {
    /// 對應 design-data-model.md 的核心判準：
    /// 同一段長 gap，在小時層級不可歸屬、在日層級可歸屬。
    @Test("長 gap 在小時層級進 unknown，在日層級進 used")
    func gapAttributionVariesByGranularity() throws {
        let db = try tempDB()
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 24
        components.hour = 9; components.minute = 0
        let start = Calendar.current.date(from: components)!

        try db.record(snapshot(percent: 33, resetsAt: 1_788_000_000, at: start))
        // 同一天內、6 小時後
        try db.record(snapshot(percent: 48, resetsAt: 1_788_000_000, at: start.addingTimeInterval(6 * 3600)))

        let hourly = try db.pool.read {
            try Row.fetchAll($0, sql: """
                SELECT used_percent, unknown_percent FROM v_hourly
                 WHERE service='codex' AND window_kind='weekly' AND unknown_percent IS NOT NULL
            """)
        }
        #expect(hourly.count == 1)
        #expect((hourly.first?["unknown_percent"] as Double?) == 15.0)

        let daily = try db.pool.read {
            try Row.fetchOne($0, sql: "SELECT used_percent, unknown_percent FROM v_daily WHERE service='codex'")
        }
        #expect((daily?["used_percent"] as Double?) == 15.0, "整段落在同一天內，日層級應可歸屬")
        #expect((daily?["unknown_percent"] as Double?) == nil)
    }

    @Test("窗重置以 resets_at 判定，不以百分比下降推測")
    func resetDetection() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_787_000_000)
        try db.record(snapshot(percent: 49, resetsAt: 1_787_500_000, at: base))
        try db.record(snapshot(percent: 0.5, resetsAt: 1_788_104_800, at: base.addingTimeInterval(300)))
        let row = try db.pool.read {
            try Row.fetchOne($0, sql: "SELECT kind, delta_percent FROM v_sample_delta ORDER BY observed_at DESC LIMIT 1")
        }
        #expect((row?["kind"] as String?) == "reset")
        #expect((row?["delta_percent"] as Double?) == 0.5, "重置後 delta 應為新窗自 0 起算的累積量")
    }
}
