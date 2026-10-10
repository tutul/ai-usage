import Testing
import Foundation
import UsageCore
@testable import UsageStore
import GRDB

private func tempURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aiusage-test-\(UUID().uuidString).sqlite")
}

/// Codex 的週窗讀數，附帶當時觀測到的重置額度數。
private func record(
    _ db: UsageDatabase, service: Service = .codex,
    percent: Double, resets: Int, credits: Int?, at: Date
) throws {
    try db.record(UsageSnapshot(
        service: service, observedAt: at,
        windows: [.init(kind: .weekly, percent: percent,
                        resetsAt: Date(timeIntervalSince1970: TimeInterval(resets)))],
        rawBody: "{}", resetCredits: credits
    ))
}

private func spans(_ db: UsageDatabase, service: Service = .codex, around base: Date) throws -> [UsageDatabase.WindowSpan] {
    try db.windowSpans(service: service, from: base.addingTimeInterval(-3600),
                       to: base.addingTimeInterval(86_400))
}

/// 提前重置有兩種：使用者自己兌換重置額度，或服務端主動清空。
/// 兩者在 `ended_early` 上長得一樣，靠換窗前後的額度數分辨。以下時序皆照實測資料。
@Suite("提前重置是誰做的（真實資料回歸）")
struct ResetCauseTests {
    private let base = Date(timeIntervalSince1970: 1_789_500_000)
    private var epoch: Int { Int(base.timeIntervalSince1970) }

    /// 2026-09-15 實測：17:56 週用量 15%、額度 3 → 18:01 歸零且額度**仍是 3** →
    /// 18:06 才變 2。額度數的更新比換窗晚一輪取樣，只看換窗後第一筆會漏掉。
    @Test("額度數晚一輪才減少 -> 仍判為使用者兌換")
    func redeemedWithOneSampleLag() throws {
        let db = try UsageDatabase(url: tempURL())
        let oldResets = epoch + 591_840
        try record(db, percent: 13, resets: oldResets, credits: 3, at: base)
        try record(db, percent: 15, resets: oldResets, credits: 3, at: base.addingTimeInterval(300))
        // 剛重置：resets_at = 現在 + 窗長，額度數還沒更新
        try record(db, percent: 0, resets: epoch + 600 + 604_800, credits: 3, at: base.addingTimeInterval(600))
        try record(db, percent: 6, resets: epoch + 600 + 604_800, credits: 2, at: base.addingTimeInterval(900))
        try record(db, percent: 7, resets: epoch + 600 + 604_800, credits: 2, at: base.addingTimeInterval(1200))

        let result = try spans(db, around: base)
        #expect(result.first?.endedEarly == true)
        #expect(result.first?.resetCause == .redeemed)
        #expect(result.last?.resetCause == nil, "仍在進行中的窗沒有重置原因")
    }

    /// 2026-08-31 實測：10:04 → 10:27 換窗，前後額度數都是 1。
    /// 當時 OpenAI 對全體付費用戶提前清空額度。
    @Test("換窗前後額度數沒變 -> 服務端主動重置")
    func externalWhenCountUnchanged() throws {
        let db = try UsageDatabase(url: tempURL())
        try record(db, percent: 1, resets: epoch + 500_000, credits: 1, at: base)
        try record(db, percent: 0, resets: epoch + 1380 + 604_800, credits: 1, at: base.addingTimeInterval(1380))
        try record(db, percent: 1, resets: epoch + 1380 + 604_800, credits: 1, at: base.addingTimeInterval(1680))

        let result = try spans(db, around: base)
        #expect(result.first?.endedEarly == true)
        #expect(result.first?.resetCause == .external)
    }

    /// 2026-08-30 實測：舊窗最後一次觀測在 05:16，下一筆在 06:31（隔 75 分鐘）。
    /// 額度會到期也會新發，隔得越久，數字的變化越可能與這次重置無關 ——
    /// 超出範圍就是不知道，不猜。
    @Test("換窗後太久才有觀測 -> 不知道")
    func unknownWhenObservedTooLate() throws {
        let db = try UsageDatabase(url: tempURL())
        try record(db, percent: 3, resets: epoch + 500_000, credits: 1, at: base)
        try record(db, percent: 0, resets: epoch + 4500 + 604_800, credits: 1, at: base.addingTimeInterval(4500))
        try record(db, percent: 1, resets: epoch + 4500 + 604_800, credits: 1, at: base.addingTimeInterval(4800))

        let result = try spans(db, around: base)
        #expect(result.first?.endedEarly == true)
        #expect(result.first?.resetCause == nil)
    }

    /// Claude 的回應沒有重置額度數。提前重置照常標記，但不能歸給任何一方 ——
    /// 尤其不能因為「沒看到額度減少」就說是服務端做的。
    @Test("沒有額度觀測 -> 不知道，不是服務端")
    func unknownWithoutObservations() throws {
        let db = try UsageDatabase(url: tempURL())
        try record(db, service: .claude, percent: 5, resets: epoch + 200_000, credits: nil, at: base)
        try record(db, service: .claude, percent: 0, resets: epoch + 400_000, credits: nil, at: base.addingTimeInterval(600))

        let result = try spans(db, service: .claude, around: base)
        #expect(result.first?.endedEarly == true)
        #expect(result.first?.resetCause == nil)
        let rows = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reset_credit") }
        #expect(rows == 0, "沒觀測到就不寫列 —— 不等於 0 個")
    }

    /// 另一家的額度數不能拿來判斷這一家的重置。
    @Test("只看同一個服務的額度觀測")
    func otherServiceCreditsIgnored() throws {
        let db = try UsageDatabase(url: tempURL())
        try record(db, service: .claude, percent: 5, resets: epoch + 200_000, credits: nil, at: base)
        try record(db, service: .codex, percent: 1, resets: epoch + 500_000, credits: 3, at: base)
        try record(db, service: .claude, percent: 0, resets: epoch + 400_000, credits: nil, at: base.addingTimeInterval(600))
        try record(db, service: .codex, percent: 1, resets: epoch + 500_000, credits: 2, at: base.addingTimeInterval(600))

        #expect(try spans(db, service: .claude, around: base).first?.resetCause == nil)
    }
}

@Suite("重置額度的留存")
struct ResetCreditStorageTests {
    private let base = Date(timeIntervalSince1970: 1_789_500_000)

    @Test("每次抓取都寫一列，值沒變也寫")
    func everyObservationStored() throws {
        let db = try UsageDatabase(url: tempURL())
        let resets = Int(base.timeIntervalSince1970) + 500_000
        for step in 0..<3 {
            try record(db, percent: 4, resets: resets, credits: 3, at: base.addingTimeInterval(Double(step) * 300))
        }
        let rows = try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM reset_credit") }
        #expect(rows == 3)
    }

    /// 2026-10-05 實測：額度到期少了一個（3 -> 2），百分比與 resets_at 都沒變。
    /// 那筆原始回應是唯一的證據，不能因為「窗的數值沒變」就不留。
    @Test("只有額度數改變時也留存原始回應")
    func creditChangeRetainsRawPayload() throws {
        let db = try UsageDatabase(url: tempURL())
        let resets = Int(base.timeIntervalSince1970) + 500_000
        try record(db, percent: 4, resets: resets, credits: 3, at: base)
        try record(db, percent: 4, resets: resets, credits: 3, at: base.addingTimeInterval(300))
        try record(db, percent: 4, resets: resets, credits: 2, at: base.addingTimeInterval(600))

        let reasons = try db.pool.read {
            try String.fetchAll($0, sql: "SELECT reason FROM raw_payload ORDER BY id")
        }
        #expect(reasons == ["first", "value_change"], "中間那筆什麼都沒變，不留")
    }
}

/// 012 會從既有的 raw_payload 補上過去的觀測。那不是合成資料 ——
/// 每一列都是端點當時真的回過的數字。這裡確認它只補得出來的那些，其餘不碰也不出錯。
@Suite("012 從原始回應補上過去的額度觀測")
struct ResetCreditBackfillTests {
    @Test("有數字的補、null 與非 JSON 的略過")
    func backfillFromRawPayload() throws {
        let url = tempURL()
        do {
            let pool = try DatabasePool(path: url.path)
            try UsageDatabase.migrator.migrate(pool, upTo: "011_unknown_window_identity")
            try pool.write { db in
                func insert(service: String, at: Int, body: String?) throws {
                    var rawID: Int64?
                    if let body {
                        try db.execute(
                            sql: "INSERT INTO raw_payload(service, captured_at, body, shape_sha256, reason) VALUES (?, ?, ?, 'x', 'value_change')",
                            arguments: [service, at, body]
                        )
                        rawID = db.lastInsertedRowID
                    }
                    try db.execute(
                        sql: "INSERT INTO fetch(service, started_at, completed_at, ok, http_status, raw_id) VALUES (?, ?, ?, 1, 200, ?)",
                        arguments: [service, at, at, rawID]
                    )
                }
                // 實測回應的相關片段
                try insert(service: "codex", at: 1000, body: #"{"plan_type":"plus","rate_limit_reset_credits":{"available_count":3,"applicable_available_count":0}}"#)
                // 2026-09-04 09:47 實測：整個欄位短暫是 null
                try insert(service: "codex", at: 1300, body: #"{"plan_type":"plus","rate_limit_reset_credits":null}"#)
                try insert(service: "codex", at: 1600, body: "<html>not json</html>")
                try insert(service: "claude", at: 1000, body: #"{"seven_day":{"utilization":6.0}}"#)
                // 值沒變的抓取沒有留存原始回應
                try insert(service: "codex", at: 1900, body: nil)
            }
        }

        let db = try UsageDatabase(url: url)
        let rows = try db.pool.read {
            try Row.fetchAll($0, sql: "SELECT service, observed_at, available_count FROM reset_credit")
        }
        #expect(rows.count == 1)
        #expect(rows.first?["service"] == "codex")
        #expect(rows.first?["observed_at"] == 1000)
        #expect(rows.first?["available_count"] == 3)
    }
}
