import Foundation
import Observation
import UsageCore
import UsageStore

@MainActor
@Observable
public final class UsageViewModel {
    public var readings: [CurrentReading] = []
    public var health: [Health] = []
    public var hourly: [Service: [HourlyBucket]] = [:]
    public var failures: [Service: (kind: String, detail: String)] = [:]
    public var loadError: String?  // 排程器也會寫入寫庫失敗訊息

    let database: UsageDatabase
    /// 取樣間隔（秒）。逾此值的兩倍未成功取樣即視為停擺。
    public var samplingInterval: TimeInterval = 300

    public init(database: UsageDatabase) {
        self.database = database
    }

    public func reload(historyDays: Int = 7) {
        do {
            readings = try database.current()
            health = try database.health()
            let since = Date().addingTimeInterval(-Double(historyDays) * 86_400)
            var buckets: [Service: [HourlyBucket]] = [:]
            for service in Service.allCases {
                buckets[service] = try database.hourly(service: service, since: since)
            }
            hourly = buckets
            var currentFailures: [Service: (kind: String, detail: String)] = [:]
            for service in Service.allCases {
                if let failure = try database.currentFailure(service: service) {
                    currentFailures[service] = failure
                }
            }
            failures = currentFailures
            loadError = nil
        } catch {
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
        failures[service]?.kind == "auth"
    }

    /// 需要你注意的停擺（排除良性者）。
    public func needsAttention(_ service: Service, now: Date = .now) -> Bool {
        isStale(service, now: now) && !isBenignStale(service)
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
    var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let seconds = Int(resetsAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "即將重置" }
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600
        return days > 0 ? "\(days) 天 \(hours) 小時後重置" : "\(hours) 小時後重置"
    }
}
