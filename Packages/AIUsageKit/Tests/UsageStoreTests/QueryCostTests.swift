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

/// 2026-10-10 實測：開圖表一次約 4.2 秒，其中 3 秒是取樣日誌。
/// 小資料量下怎麼寫都快，所以這裡不量時間，直接看查詢計畫 ——
/// 「掃整張表」在測試資料上不慢，在六週的真實資料上就是 3 秒。
@Suite("查詢成本（真實資料回歸）")
struct QueryCostTests {
    @Test("取樣日誌不掃整張 sample，也不為了排序掃整張 fetch")
    func recentFetchesUsesIndexes() throws {
        let db = try tempDB()
        let plan = try db.pool.read {
            try Row.fetchAll($0, sql: "EXPLAIN QUERY PLAN " + UsageDatabase.recentFetchesSQL, arguments: [51])
                .map { $0["detail"] as String }
        }
        #expect(plan.contains { $0.contains("idx_sample_fetch") }, "每一列的週用量要走索引：\(plan)")
        #expect(!plan.contains { $0.hasPrefix("SCAN s") }, "不可掃整張 sample：\(plan)")
        #expect(!plan.contains { $0.contains("TEMP B-TREE") }, "排序要走索引，否則 LIMIT 省不到東西：\(plan)")
    }

    /// 這些 view 的 `WHERE service = ?` 推不進視窗函式，逐個服務查等於把全部樣本多算一遍。
    @Test("一次查詢拿到所有服務的分桶與額度窗")
    func allServicesInOneQuery() throws {
        let db = try tempDB()
        let base = Date(timeIntervalSince1970: 1_789_500_000)
        let resets = Date(timeIntervalSince1970: 1_789_500_000 + 200_000)
        for (step, percent) in [3.0, 5.0, 8.0].enumerated() {
            for service in Service.allCases {
                try db.record(UsageSnapshot(
                    service: service, observedAt: base.addingTimeInterval(Double(step) * 300),
                    windows: [.init(kind: .weekly, percent: percent, resetsAt: resets)], rawBody: "{}"
                ))
            }
        }
        let from = base.addingTimeInterval(-86_400), to = base.addingTimeInterval(86_400)

        let buckets = try db.buckets(granularity: .day, since: from, until: to)
        #expect(Set(buckets.keys) == Set(Service.allCases))
        let spans = try db.windowSpans(from: from, to: to)
        #expect(Set(spans.keys) == Set(Service.allCases))

        // 與逐個服務查的結果一致
        for service in Service.allCases {
            #expect(try db.buckets(service: service, granularity: .day, since: from, until: to) == buckets[service])
            #expect(try db.windowSpans(service: service, from: from, to: to) == spans[service])
            #expect(buckets[service]?.first?.usedPercent == 5, "3 -> 5 -> 8，新增 5")
        }
    }
}
