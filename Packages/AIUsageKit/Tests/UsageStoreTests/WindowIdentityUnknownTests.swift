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

private func record(
    _ db: UsageDatabase, kind: WindowKind = .weekly, percent: Double, resets: Int?, at: Date
) throws {
    try db.record(UsageSnapshot(
        service: .claude, observedAt: at,
        windows: [.init(kind: kind, percent: percent,
                        resetsAt: resets.map { Date(timeIntervalSince1970: TimeInterval($0)) })],
        rawBody: "{}"
    ))
}

private func deltaTotal(_ db: UsageDatabase) throws -> Double {
    try db.pool.read {
        try Double.fetchOne($0, sql: "SELECT COALESCE(SUM(delta_percent), 0) FROM v_sample_delta WHERE kind <> 'first'") ?? -1
    }
}

private func windowCount(_ db: UsageDatabase) throws -> Int {
    try db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM v_window_summary") ?? -1 }
}

/// 2026-09-16 08:59:59 實測：**重置那一秒**端點回的是
/// `"seven_day": {"utilization": 38.0, "resets_at": null}` —— 百分比還是舊窗的，身分卻是 null。
/// 舊規則（004）把「有 resets_at ↔ 沒有」當成窗界線，判成重置後 delta 直接給當下的百分比，
/// 那一天憑空多出 38%（45% vs 真實約 7%）。
@Suite("窗身分未知（真實資料回歸）")
struct UnknownWindowIdentityTests {
    @Test("重置那一秒 resets_at 為 NULL -> 不算換窗，不生出用量")
    func nullAtResetDoesNotInflate() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_789_500_000)
        let oldResets = 1_789_520_400, newResets = 1_790_125_200
        try record(db, percent: 38, resets: oldResets, at: base)
        try record(db, percent: 38, resets: oldResets, at: base.addingTimeInterval(300))
        try record(db, percent: 38, resets: nil, at: base.addingTimeInterval(600))
        try record(db, percent: 0, resets: newResets, at: base.addingTimeInterval(900))

        #expect(try deltaTotal(db) == 0, "整段沒有新增用量，加總必須是 0")
        #expect(try windowCount(db) == 2, "只有一次真正的重置")
    }

    /// session 窗常態性地偶爾少給 resets_at（實測 09-08 一天被灌 68%）。
    @Test("窗中間偶發 NULL -> 仍是同一個窗，用量照常累加")
    func nullMidWindowKeepsWindow() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_789_500_000)
        let resets = 1_789_520_400
        try record(db, percent: 20, resets: resets, at: base)
        try record(db, percent: 20, resets: nil, at: base.addingTimeInterval(300))
        try record(db, percent: 25, resets: resets, at: base.addingTimeInterval(600))

        #expect(try deltaTotal(db) == 5, "20 -> 25，只能是 5")
        #expect(try windowCount(db) == 1, "身分未知不是換窗")
    }

    /// 保護 004 的行為不被這次改動弄壞：未開始的窗，resets_at 是**佔位值**
    /// （≈ 觀測時間 + 窗長，隨每次取樣前移），轉為已開始時才是真正的界線。
    @Test("未開始的佔位值仍然分窗")
    func placeholderStillSplitsWindows() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_789_500_000)
        let epoch = Int(base.timeIntervalSince1970)
        try record(db, percent: 0, resets: epoch + 604_800, at: base)
        try record(db, percent: 0, resets: epoch + 300 + 604_800, at: base.addingTimeInterval(300))
        // 開始使用：resets_at 不再隨觀測前移
        try record(db, percent: 3, resets: epoch + 604_800, at: base.addingTimeInterval(600))

        #expect(try windowCount(db) == 2, "未開始 -> 已開始是真正的窗界線")
        let started = try db.pool.read {
            try Int.fetchOne($0, sql: "SELECT window_started FROM v_window_summary ORDER BY window_seq DESC LIMIT 1")
        }
        #expect(started == 1)
        #expect(try deltaTotal(db) == 3, "新窗的第一筆用量記為 3")
    }
}

/// 曆週桶不等於額度窗：一個曆週可能含好幾個窗（Codex 實測 5 個週窗有 3 個提前重置），
/// 那一格的百分比是各窗加總，可能超過 100%。圖表得講得出「這一格裡面有幾個窗」。
@Suite("額度窗起點（供圖表說明）")
struct WindowSpanTests {
    /// 兩個窗：第一個在排定重置前就換窗（提前重置），第二個仍在進行中。
    private func twoWindows() throws -> (UsageDatabase, Date) {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_789_500_000)
        let epoch = Int(base.timeIntervalSince1970)
        try record(db, percent: 3, resets: epoch + 200_000, at: base)
        try record(db, percent: 5, resets: epoch + 200_000, at: base.addingTimeInterval(600))
        try record(db, percent: 0, resets: epoch + 400_000, at: base.addingTimeInterval(1200))
        try record(db, percent: 2, resets: epoch + 400_000, at: base.addingTimeInterval(1800))
        return (db, base)
    }

    @Test("範圍內的窗起點、用量與提前重置標記")
    func spansWithinRange() throws {
        let (db, base) = try twoWindows()
        let spans = try db.windowSpans(service: .claude, from: base.addingTimeInterval(-60),
                                       to: base.addingTimeInterval(3600))
        #expect(spans.count == 2)
        #expect(spans.first?.endedEarly == true, "排定重置前就換窗 = 提前重置")
        #expect(spans.first?.usedPercent == 5, "窗的用量是最後觀測值，不經 delta")
        #expect(spans.last?.endedEarly == false, "仍在進行中不算提前結束")
    }

    /// 只取**起點**落在範圍內的 —— 跨進來的前一個窗，消耗本來就算在更早的桶。
    @Test("只算起點落在範圍內的窗")
    func onlyStartsInsideRange() throws {
        let (db, base) = try twoWindows()
        let spans = try db.windowSpans(service: .claude, from: base.addingTimeInterval(700),
                                       to: base.addingTimeInterval(3600))
        #expect(spans.count == 1)
        #expect(spans.first?.usedPercent == 2)
    }
}
