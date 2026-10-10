import Testing
import Foundation
import UsageCore
import UsageStore
@testable import UsageUI

private func tempDB() throws -> UsageDatabase {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aiusage-test-\(UUID().uuidString).sqlite")
    return try UsageDatabase(url: url)
}

/// 今天的三筆讀數：3 -> 5 -> 8。
private func seed(_ db: UsageDatabase, fetches: Int = 3) throws {
    let start = Calendar.current.startOfDay(for: .now).addingTimeInterval(3600)
    let resets = start.addingTimeInterval(400_000)
    for step in 0..<fetches {
        try db.record(UsageSnapshot(
            service: .claude, observedAt: start.addingTimeInterval(Double(step) * 300),
            windows: [.init(kind: .weekly, percent: [3.0, 5.0, 8.0][min(step, 2)], resetsAt: resets)],
            rawBody: "{}"
        ))
    }
}

@MainActor
private func request(_ granularity: Granularity = .hour, fetchLimit: Int = UsageViewModel.fetchPageSize)
    -> UsageViewModel.ReloadRequest {
    .init(granularity: granularity, since: .distantPast, until: nil, cacheService: .claude,
          cacheFrom: "2026-01-01", cacheTo: "2026-12-31", fetchLimit: fetchLimit)
}

/// 重讀原本同步跑在主執行緒上（實測六週資料約 0.4 秒，隨資料量成長）。
/// 搬到背景之後多出兩種同步時不存在的錯法：結果亂序到達、
/// 以及「選單已經切了、資料還沒到」的那一小段時間。
@MainActor
@Suite("背景重讀")
struct BackgroundReloadTests {
    @Test("重讀完成後畫面資料到位")
    func reloadPopulates() async throws {
        let db = try tempDB()
        try seed(db)
        let model = UsageViewModel(database: db)
        #expect(model.readings.isEmpty, "重讀不再同步完成 —— 呼叫前後都不該卡住主執行緒")

        await model.reload().value

        #expect(model.weekly(for: .claude)?.percent == 8)
        #expect(model.buckets[.claude]?.isEmpty == false)
        #expect(model.recentFetches.count == 3)
        #expect(model.loadError == nil)
    }

    /// 切到「日」之後、資料回來之前，畫面上還是小時的分桶。
    /// 這時拿「日」去解讀它們，會把每個小時畫成一整天寬。
    @Test("切換粒度：資料到之前，畫圖用的粒度維持與分桶一致")
    func shownGranularityFollowsData() async throws {
        let db = try tempDB()
        try seed(db)
        let model = UsageViewModel(database: db)
        await model.reload().value
        let hourKeys = model.buckets[.claude]?.map(\.key)

        model.granularity = .day
        let pending = model.reload()
        #expect(model.shownGranularity == .hour, "資料還沒到，分桶仍是小時的")
        #expect(model.buckets[.claude]?.map(\.key) == hourKeys)

        await pending.value
        #expect(model.shownGranularity == .day)
        #expect(model.buckets[.claude]?.map(\.key) != hourKeys, "分桶與粒度一起換")
    }

    /// 連點兩次：先送出的查詢比較晚回來。照到達順序套用，畫面會停在已經離開的選項上。
    @Test("較舊的結果晚到 -> 丟掉，不蓋掉較新的")
    func staleResultIgnored() throws {
        let model = UsageViewModel(database: try tempDB())
        var newer = UsageViewModel.Loaded()
        newer.earliestSample = Date(timeIntervalSince1970: 2000)
        var older = UsageViewModel.Loaded()
        older.earliestSample = Date(timeIntervalSince1970: 1000)

        model.apply(.success(newer), request: request(.day), generation: 2)
        model.apply(.success(older), request: request(.hour), generation: 1)

        #expect(model.earliestSample == Date(timeIntervalSince1970: 2000))
        #expect(model.shownGranularity == .day)
    }

    @Test("查詢失敗 -> 顯示錯誤，保留畫面上原有的資料")
    func failureKeepsData() async throws {
        let db = try tempDB()
        try seed(db)
        let model = UsageViewModel(database: db)
        await model.reload().value

        struct Boom: Error {}
        model.apply(.failure(Boom()), request: request(), generation: 99)

        #expect(model.loadError != nil)
        #expect(model.weekly(for: .claude)?.percent == 8, "失敗不該把畫面清空")
    }

    /// 查詢在跑的時候按了「更多」：那一頁已經載入、筆數比較多。
    /// 背景的結果是用舊的筆數查的，蓋回去會把剛展開的那一頁收掉。
    @Test("重讀期間按了「更多」-> 不被較短的那一頁蓋掉")
    func loadMoreNotOverwritten() async throws {
        let db = try tempDB()
        try seed(db, fetches: UsageViewModel.fetchPageSize + 10)
        let model = UsageViewModel(database: db)
        await model.reload().value
        #expect(model.recentFetches.count == UsageViewModel.fetchPageSize)
        #expect(model.hasMoreFetches)

        let pending = model.reload()          // 用 50 筆的上限送出
        model.loadMoreFetches()               // 使用者展開到 100 筆
        #expect(model.recentFetches.count == UsageViewModel.fetchPageSize + 10)
        await pending.value

        #expect(model.recentFetches.count == UsageViewModel.fetchPageSize + 10)
        #expect(!model.hasMoreFetches)
    }
}

/// 寫入失敗原本與讀取失敗共用 `loadError`，而排程器在回報寫入失敗之後緊接著重讀 ——
/// 讀取照常成功，訊息當場被清掉。樣本既然沒寫進去，資料庫裡也不留痕跡，
/// 所以這種資料遺失從頭到尾沒有任何地方看得到。
@MainActor
@Suite("寫入失敗的訊息")
struct WriteFailureTests {
    private struct DiskFull: Error {}
    private let noon = Date(timeIntervalSince1970: 1_791_600_000)

    @Test("重讀成功不清掉寫入失敗")
    func survivesSuccessfulReload() async throws {
        let db = try tempDB()
        try seed(db)
        let model = UsageViewModel(database: db)

        model.noteWrite(.claude, error: DiskFull(), at: noon)
        await model.reload().value

        #expect(model.loadError == nil, "讀取本身沒有問題")
        #expect(model.writeError?.contains("Claude") == true)
        #expect(model.writeError?.contains("DiskFull") == true)
    }

    @Test("同一個服務之後寫成功 -> 清掉；另一個服務的不受影響")
    func clearedOnlyByOwnSuccess() throws {
        let model = UsageViewModel(database: try tempDB())
        model.noteWrite(.claude, error: DiskFull(), at: noon)
        model.noteWrite(.codex, error: DiskFull(), at: noon)

        model.noteWrite(.codex, error: nil)

        #expect(model.writeFailures[.codex] == nil)
        #expect(model.writeFailures[.claude] != nil, "Codex 寫成功不代表 Claude 的也寫進去了")
        #expect(model.writeError?.contains("Codex") == false)
    }

    /// 要知道的是「從什麼時候開始掉資料」。每次失敗都更新時間的話，
    /// 畫面上永遠是五分鐘前，看不出已經掉了多久。
    @Test("持續失敗 -> 保留第一次失敗的時間")
    func keepsFirstFailureTime() throws {
        let model = UsageViewModel(database: try tempDB())
        model.noteWrite(.claude, error: DiskFull(), at: noon)
        model.noteWrite(.claude, error: DiskFull(), at: noon.addingTimeInterval(300))
        model.noteWrite(.claude, error: DiskFull(), at: noon.addingTimeInterval(600))

        #expect(model.writeFailures[.claude]?.since == noon)
    }

    @Test("讀取失敗與寫入失敗互不覆蓋")
    func independentOfLoadError() async throws {
        let db = try tempDB()
        try seed(db)
        let model = UsageViewModel(database: db)
        model.noteWrite(.claude, error: DiskFull(), at: noon)

        model.apply(.failure(DiskFull()), request: request(), generation: 50)
        #expect(model.loadError != nil)
        #expect(model.writeError != nil)

        model.noteWrite(.claude, error: nil)
        #expect(model.loadError != nil, "寫成功不代表讀取恢復了")
        #expect(model.writeError == nil)
    }
}
