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

@Suite("睡眠中斷與健康度")
struct SleptHealthTests {
    @Test("slept 不計入失敗次數，也不算目前失敗")
    func sleptIsNotAFailure() throws {
        let db = try tempDB()
        let now = Date()
        try db.record(failure: .init(kind: .slept, detail: "asleep"), service: .claude,
                      startedAt: now.addingTimeInterval(-3000), completedAt: now)
        let health = try db.health().first { $0.service == .claude }
        #expect(health?.failuresTotal == 0)
        #expect(health?.failures24h == 0)
        #expect(try db.currentFailure(service: .claude) == nil)
    }

    /// 睡一覺起來，最後一筆是睡眠中斷 —— 不能因此把之前那筆真正的失敗藏起來。
    @Test("最後一筆是 slept -> 回報再之前那次的真實結果")
    func sleptDoesNotMaskRealFailure() throws {
        let db = try tempDB()
        let now = Date()
        try db.record(failure: .init(kind: .auth, httpStatus: 401, detail: "expired"), service: .claude,
                      startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-600))
        try db.record(failure: .init(kind: .slept, detail: "asleep"), service: .claude,
                      startedAt: now.addingTimeInterval(-300), completedAt: now)
        #expect(try db.currentFailure(service: .claude)?.kind == "auth")
    }

    @Test("failures_24h 只算最近 24 小時，failures_total 是全部")
    func recentWindow() throws {
        let db = try tempDB()
        let now = Date()
        let old = now.addingTimeInterval(-2 * 86_400)
        try db.record(failure: .init(kind: .network, detail: "old"), service: .codex, startedAt: old, completedAt: old)
        let recent = now.addingTimeInterval(-3600)
        try db.record(failure: .init(kind: .auth, detail: "recent"), service: .codex, startedAt: recent, completedAt: recent)
        let health = try db.health().first { $0.service == .codex }
        #expect(health?.failuresTotal == 2)
        #expect(health?.failures24h == 1)
    }
}

@Suite("離線與健康度")
struct OfflineHealthTests {
    private func offline() -> FetchFailure { .init(kind: .offline, detail: "這台 Mac 沒有網路連線") }

    @Test("offline 不計入失敗次數，另外計數")
    func offlineIsNotAFailure() throws {
        let db = try tempDB()
        let now = Date()
        for step in 0..<3 {
            let at = now.addingTimeInterval(Double(step - 3) * 300)
            try db.record(failure: offline(), service: .codex, startedAt: at, completedAt: at)
        }
        try db.record(failure: .init(kind: .network, detail: "timed out"), service: .codex,
                      startedAt: now, completedAt: now)
        let health = try db.health().first { $0.service == .codex }
        #expect(health?.failuresTotal == 1, "網路通卻連不上服務的那一筆仍是失敗")
        #expect(health?.failures24h == 1)
        let total = try db.pool.read {
            try Int.fetchOne($0, sql: "SELECT offline_total FROM v_health WHERE service = 'codex'")
        }
        #expect(total == 3)
    }

    /// 離線可以持續很久（實測有一段 28 小時）。不說原因，畫面上只會是沒有解釋的「資料停了」。
    @Test("服務本來正常、現在離線 -> 回報離線")
    func offlineExplainsStaleness() throws {
        let db = try tempDB()
        let now = Date()
        try db.record(UsageSnapshot(
            service: .claude, observedAt: now.addingTimeInterval(-600),
            windows: [.init(kind: .weekly, percent: 5, resetsAt: now.addingTimeInterval(86_400))], rawBody: "{}"
        ))
        try db.record(failure: offline(), service: .claude, startedAt: now, completedAt: now)
        #expect(try db.currentFailure(service: .claude)?.kind == "offline")
    }

    /// 登入過期之後斷網：網路回來也不會自己好，要處理的仍然是登入。
    @Test("離線不蓋掉之前那筆真正的失敗")
    func offlineDoesNotMaskRealFailure() throws {
        let db = try tempDB()
        let now = Date()
        try db.record(failure: .init(kind: .loginExpired, detail: "請重新登入"), service: .claude,
                      startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-600))
        try db.record(failure: offline(), service: .claude, startedAt: now, completedAt: now)
        #expect(try db.currentFailure(service: .claude)?.kind == "login_expired")
    }

    @Test("網路回來、抓取成功 -> 不再回報離線")
    func recoversWhenOnline() throws {
        let db = try tempDB()
        let now = Date()
        try db.record(failure: offline(), service: .claude,
                      startedAt: now.addingTimeInterval(-600), completedAt: now.addingTimeInterval(-600))
        try db.record(UsageSnapshot(
            service: .claude, observedAt: now,
            windows: [.init(kind: .weekly, percent: 5, resetsAt: now.addingTimeInterval(86_400))], rawBody: "{}"
        ))
        #expect(try db.currentFailure(service: .claude) == nil)
    }
}

@Suite("憑證事件")
struct CredentialEventStoreTests {
    @Test("寫入後可從 credential_event 查到，欄位完整")
    func recorded() throws {
        let db = try tempDB()
        try db.record(CredentialEvent(
            service: .claude, occurredAt: Date(timeIntervalSince1970: 1_787_000_000),
            kind: .discarded, source: "own", detail: "續期鏈失效"
        ))
        let row = try db.pool.read {
            try Row.fetchOne($0, sql: "SELECT service, occurred_at, event, source, detail FROM credential_event")
        }
        let event: String? = row?["event"]
        let source: String? = row?["source"]
        let occurredAt: Int? = row?["occurred_at"]
        #expect(event == "discarded")
        #expect(source == "own")
        #expect(occurredAt == 1_787_000_000)
    }
}
