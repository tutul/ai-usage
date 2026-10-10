import Foundation
import Observation
import UsageCore
import UsageStore

@MainActor
@Observable
public final class UsageViewModel {
    public var readings: [CurrentReading] = []
    public var health: [Health] = []
    public var buckets: [Service: [UsageBucket]] = [:]
    /// 顯示範圍內各服務的額度窗起點。用來說明「這一格裡面有幾個窗」。
    public var windowSpans: [Service: [UsageDatabase.WindowSpan]] = [:]
    public var recentFetches: [RecentFetch] = []
    /// 日誌還有更多可載入。多要一筆來判斷，避免另外查一次 COUNT。
    public private(set) var hasMoreFetches = false
    /// 使用者**選的**粒度。畫圖要用 `shownGranularity` —— 查詢在背景跑，
    /// 選了「日」之後有一小段時間畫面上還是「小時」的分桶。
    public var granularity: Granularity = .hour
    /// 目前 `buckets` 是用哪個粒度查出來的。與 `buckets` 一起更新，
    /// 所以拿它來解讀分桶永遠對得上（拿 `granularity` 會把小時桶當成日桶畫）。
    public private(set) var shownGranularity: Granularity = .hour
    /// 最近一次對話紀錄匯入的結果，供 UI 顯示「匯入了幾筆」。
    public var cacheImport: UsageDatabase.ImportResult?
    public var cacheRows: [UsageDatabase.CacheDailyRow] = []
    /// 快取分頁看哪一家。兩家的快取機制不同，摘要數字不可混算。
    public var cacheService: Service = .claude
    public private(set) var isImporting = false

    /// 顯示範圍（含頭含尾，以當地日為單位）。放在 model 而非 view 的 @State，
    /// 這樣關掉視窗再開還在。
    public var rangeStart: Date = UsageViewModel.defaultRangeStart
    public var rangeEnd: Date = Calendar.current.startOfDay(for: .now)
    /// 最早的樣本，供「全部」與日期選擇器的下界用。
    public private(set) var earliestSample: Date?

    static var defaultRangeStart: Date {
        let today = Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(byAdding: .day, value: -6, to: today) ?? today
    }
    public var failures: [Service: (kind: String, detail: String)] = [:]
    public var loadError: String?  // 排程器也會寫入寫庫失敗訊息

    let database: UsageDatabase
    /// 取樣間隔（秒）。逾此值的兩倍未成功取樣即視為停擺。
    public var samplingInterval: TimeInterval = 300

    public static let fetchPageSize = 50
    /// 日誌目前載入的筆數。只增不減 —— 使用者按了「更多」之後，
    /// 背景取樣觸發的重讀不該把他捲到的位置吃掉。
    private var fetchLimit = UsageViewModel.fetchPageSize

    /// 每次重讀遞增。結果回來時用它判斷是不是已經被更新的請求取代。
    private var reloadGeneration = 0
    private var appliedGeneration = 0

    public init(database: UsageDatabase) {
        self.database = database
    }

    /// 多取一筆判斷還有沒有下一頁，顯示時再丟掉。
    ///
    /// 這一個刻意留在主執行緒同步跑：按「更多」要立刻看到結果，而它走索引、
    /// 與資料量無關（實測 1 ms）。其餘的查詢都在 `reload()` 的背景任務裡。
    private func loadFetchPage() {
        guard let page = try? database.recentFetches(limit: fetchLimit + 1) else { return }
        hasMoreFetches = page.count > fetchLimit
        recentFetches = Array(page.prefix(fetchLimit))
    }

    /// 涵蓋全部資料。沒有樣本時維持原範圍，不要跳到 1970。
    public func showAllRange() {
        if let earliest = earliestSample {
            rangeStart = Calendar.current.startOfDay(for: earliest)
        }
        rangeEnd = Calendar.current.startOfDay(for: .now)
        reload()
    }

    /// 手動匯入對話紀錄。掃的是使用者全部的 JSONL，會做檔案 I/O，
    /// 所以丟到背景執行，不要卡住 UI。
    public func importTranscripts() async {
        guard !isImporting else { return }
        isImporting = true
        let db = database
        cacheImport = await Task.detached(priority: .userInitiated) {
            try? db.importTranscripts()
        }.value
        isImporting = false
        reload()
    }

    public func loadMoreFetches() {
        fetchLimit += Self.fetchPageSize
        loadFetchPage()
    }

    /// 一次重讀要查什麼。在主執行緒上取好快照再交給背景 ——
    /// 背景不可以回頭讀 model 的屬性。
    struct ReloadRequest: Sendable {
        let granularity: Granularity
        let since: Date
        let until: Date?
        let cacheService: Service
        let cacheFrom: String
        let cacheTo: String
        let fetchLimit: Int
    }

    struct Loaded: Sendable {
        var readings: [CurrentReading] = []
        var health: [Health] = []
        var recentFetches: [RecentFetch] = []
        var hasMoreFetches = false
        var earliestSample: Date?
        var buckets: [Service: [UsageBucket]] = [:]
        var windowSpans: [Service: [UsageDatabase.WindowSpan]] = [:]
        var cacheRows: [UsageDatabase.CacheDailyRow] = []
        var failures: [Service: (kind: String, detail: String)] = [:]
    }

    private func makeRequest() -> ReloadRequest {
        let calendar = Calendar.current
        let day = DateFormatter()
        day.calendar = calendar
        day.dateFormat = "yyyy-MM-dd"
        return ReloadRequest(
            granularity: granularity,
            since: calendar.startOfDay(for: rangeStart),
            // 迄日要含整天 —— 選 9/2 卻只到 9/2 00:00 會讓當天完全看不到。
            until: calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: rangeEnd))?
                .addingTimeInterval(-1),
            cacheService: cacheService,
            cacheFrom: day.string(from: rangeStart), cacheTo: day.string(from: rangeEnd),
            fetchLimit: fetchLimit
        )
    }

    /// 重讀全部顯示用的資料。**查詢在背景跑**，結果回主執行緒才指派。
    ///
    /// 這些查詢每次都把全部樣本推導一遍（view 用視窗函式，時間條件推不進去），
    /// 成本隨資料量成長 —— 實測六週的資料約 0.4 秒。同步跑的話，每 5 分鐘取樣後、
    /// 視窗取得焦點、切粒度或日期時，畫面都會卡這麼久（見 D-023）。
    ///
    /// 回傳的 Task 在結果套用後結束，需要「等資料到了再繼續」的呼叫端可以 await。
    @discardableResult
    public func reload() -> Task<Void, Never> {
        reloadGeneration += 1
        let generation = reloadGeneration
        let request = makeRequest()
        let database = database
        return Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try Self.load(database, request) }
            }.value
            self?.apply(result, request: request, generation: generation)
        }
    }

    nonisolated static func load(_ database: UsageDatabase, _ request: ReloadRequest) throws -> Loaded {
        var loaded = Loaded()
        loaded.readings = try database.current()
        loaded.health = try database.health()
        // 多取一筆判斷還有沒有下一頁，顯示時再丟掉。
        let page = try database.recentFetches(limit: request.fetchLimit + 1)
        loaded.hasMoreFetches = page.count > request.fetchLimit
        loaded.recentFetches = Array(page.prefix(request.fetchLimit))
        loaded.earliestSample = try database.earliestSample()
        // 兩家一次查完 —— 分開查不會比較快，只是把全部樣本多算一遍。
        loaded.buckets = try database.buckets(
            granularity: request.granularity, since: request.since, until: request.until
        )
        loaded.windowSpans = try database.windowSpans(from: request.since, to: request.until ?? .now)
        loaded.cacheRows = (try? database.cacheDaily(
            service: request.cacheService, from: request.cacheFrom, to: request.cacheTo
        )) ?? []
        for service in Service.allCases {
            if let failure = try database.currentFailure(service: service) {
                loaded.failures[service] = failure
            }
        }
        return loaded
    }

    /// **較舊的結果晚到就丟掉。** 連點兩次粒度時，先送出的查詢可能比較晚回來，
    /// 照到達順序套用會讓畫面停在使用者已經離開的那個選項上。
    func apply(_ result: Result<Loaded, any Error>, request: ReloadRequest, generation: Int) {
        guard generation > appliedGeneration else { return }
        appliedGeneration = generation
        switch result {
        case .success(let loaded):
            readings = loaded.readings
            health = loaded.health
            // 查詢在跑的時候使用者可能按了「更多」。那一頁已經同步載入、筆數比較多，
            // 不要拿這份比較短的蓋回去。
            if request.fetchLimit == fetchLimit {
                recentFetches = loaded.recentFetches
                hasMoreFetches = loaded.hasMoreFetches
            }
            earliestSample = loaded.earliestSample
            buckets = loaded.buckets
            shownGranularity = request.granularity
            windowSpans = loaded.windowSpans
            cacheRows = loaded.cacheRows
            failures = loaded.failures
            loadError = nil
        case .failure(let error):
            loadError = String(describing: error)
        }
    }

    public func weekly(for service: Service) -> CurrentReading? {
        readings.first { $0.service == service && $0.windowKind == "weekly" }
    }

    public func health(for service: Service) -> Health? {
        health.first { $0.service == service }
    }

    /// 週資料是否過期。量的是 `last_weekly_at` 而非 HTTP 成功時間 ——
    /// 端點可能回 200 卻不含週窗，那時 UI 不該假裝一切正常。
    public func isStale(_ service: Service, now: Date = .now) -> Bool {
        guard let last = health(for: service)?.lastWeeklyAt else { return true }
        return now.timeIntervalSince(last) > samplingInterval * 2
    }

    /// 憑證過期是**良性**停擺：開一次對應的 app 就好，不是壞掉。
    /// 不該和「取樣真的失敗」用同一種警示強度 —— 狼來了喊多了就沒人看。
    public func isBenignStale(_ service: Service) -> Bool {
        guard let kind = failures[service]?.kind else { return false }
        // 離線同理：網路回來就會自己好，而且使用者多半早就知道自己沒網路。
        return kind == "auth" || kind == "rate_limited" || kind == FetchErrorKind.offline.rawValue
    }

    /// 需要你注意的停擺（排除良性者）。
    public func needsAttention(_ service: Service, now: Date = .now) -> Bool {
        isStale(service, now: now) && !isBenignStale(service)
    }

    /// 這個服務是不是「要人重新登入」才會好。UI 據此顯示修復按鈕。
    public func needsLogin(_ service: Service) -> Bool {
        failures[service]?.kind == FetchErrorKind.loginExpired.rawValue
    }

    /// 停擺原因，已是可行動的句子。
    public func failureHint(_ service: Service) -> String? {
        guard let failure = failures[service] else { return nil }
        return failure.detail.isEmpty ? failure.kind : failure.detail
    }

    public func staleness(_ service: Service, now: Date = .now) -> String {
        guard let last = health(for: service)?.lastWeeklyAt else { return "尚無資料" }
        let seconds = Int(now.timeIntervalSince(last))
        switch seconds {
        case ..<90: return "剛剛更新"
        case ..<3600: return "\(seconds / 60) 分鐘前"
        case ..<86_400: return "\(seconds / 3600) 小時前"
        default: return "\(seconds / 86_400) 天前"
        }
    }
}

public extension Service {
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
    /// menu bar 空間有限，用單字母
    var shortName: String {
        switch self {
        case .claude: return "C"
        case .codex: return "X"
        }
    }
}

public extension CurrentReading {
    /// 窗以「首次使用」為錨點。尚未開始時伺服器回報 resets_at = 現在 + 窗長，
    /// 該值隨每次取樣前移，倒數永遠停在同一個數字 —— 顯示出來會讓人
    /// 誤以為額度一直在被重置。
    var resetCountdown: String? {
        guard windowStarted else {
            let length = windowSeconds.map { $0 >= 604_800 ? "7 天" : "5 小時" } ?? "整段"
            return "未開始計時（\(length)窗）"
        }
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "即將重置" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600
        return days > 0 ? "\(days) 天 \(hours) 小時後重置" : "\(hours) 小時後重置"
    }
}
