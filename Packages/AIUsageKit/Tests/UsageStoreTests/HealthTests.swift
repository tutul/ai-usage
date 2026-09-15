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
