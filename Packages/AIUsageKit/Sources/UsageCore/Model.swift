import Foundation

public enum Service: String, Sendable, Codable, CaseIterable {
    case claude
    case codex
}

/// 限額窗的種類。
///
/// **窗別一律由 `limit_window_seconds` 判定，絕不由回應中的欄位位置判定。**
/// Codex 的窗會換位：2026-07 前為 primary=5h / secondary=週，暫停期間為 primary=週 / secondary=null，
/// 5 小時限額於 2026-08-25 對 Plus 恢復後預期換回 primary=5h / secondary=週。
/// 若以欄位位置對應，換位當下會默默把 5 小時百分比寫進 weekly 序列 —— 不報錯，只是資料錯了。
public enum WindowKind: Sendable, Hashable, Codable {
    case weekly
    case session
    case other(seconds: Int)

    public static let weeklySeconds = 604_800
    public static let sessionSeconds = 18_000

    public static func from(limitWindowSeconds: Int?) -> WindowKind? {
        guard let seconds = limitWindowSeconds else { return nil }
        switch seconds {
        case weeklySeconds: return .weekly
        case sessionSeconds: return .session
        default: return .other(seconds: seconds)
        }
    }

    /// 寫入 `sample.window_kind` 的值。精確秒數另存於 `sample.window_seconds`。
    public var storageKey: String {
        switch self {
        case .weekly: return "weekly"
        case .session: return "session"
        case .other: return "other"
        }
    }

    public var seconds: Int? {
        switch self {
        case .weekly: return Self.weeklySeconds
        case .session: return Self.sessionSeconds
        case .other(let s): return s
        }
    }
}

public struct UsageWindow: Sendable, Hashable {
    public let kind: WindowKind
    public let percent: Double
    public let resetsAt: Date?

    public init(kind: WindowKind, percent: Double, resetsAt: Date?) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct UsageSnapshot: Sendable {
    public let service: Service
    public let observedAt: Date
    public let windows: [UsageWindow]
    public let rawBody: String
    public let planType: String?

    public init(service: Service, observedAt: Date, windows: [UsageWindow], rawBody: String, planType: String? = nil) {
        self.service = service
        self.observedAt = observedAt
        self.windows = windows
        self.rawBody = rawBody
        self.planType = planType
    }

    public var weekly: UsageWindow? { windows.first { $0.kind == .weekly } }
    public var session: UsageWindow? { windows.first { $0.kind == .session } }
}

/// `auth` 與 `blocked` 必須分開 —— 401 的補救是重新授權，403 是 UA／風控問題，
/// 兩者混為一談會讓人跑去重新登入而白忙。
public enum FetchErrorKind: String, Sendable {
    case auth
    case blocked
    /// 端點限流（含 OAuth 續期端點）。暫時性，下輪會自動重試。
    case rateLimited = "rate_limited"
    case network
    case http
    case parse
    case missingWindow = "missing_window"
    /// 請求期間系統睡著了 —— **這次沒有觀測，不是服務故障**。見 D-017。
    /// 睡眠中的短暫喚醒會照常觸發取樣，系統接著回去睡、請求被凍結，醒來時早已逾時。
    /// 記成 `network` 會讓健康度與取樣日誌塞滿假失敗（實測 7 天 208 筆）。
    case slept
    /// 續期端點不認這個 client ID。補救是換 client ID，**不是**重新登入 ——
    /// 所以不能併入 `auth`，否則使用者會去重新登入而白忙，自癒也會誤丟還能用的憑證。
    case invalidClient = "invalid_client"
}

public struct FetchFailure: Error, Sendable {
    public let kind: FetchErrorKind
    public let httpStatus: Int?
    public let detail: String

    public init(kind: FetchErrorKind, httpStatus: Int? = nil, detail: String) {
        self.kind = kind
        self.httpStatus = httpStatus
        self.detail = detail
    }
}

public extension FetchFailure {
    /// 牆上時間比清醒時間多出這麼多秒，就視為請求期間系統睡過。
    /// 清醒時兩者幾乎同步；`ProcessInfo.systemUptime` 不計入睡眠，只有牆上時間會前進。
    /// 門檻訂得低：實測有一次請求期間只睡了約 2 秒，仍然是睡眠造成的逾時。
    static let sleepThresholdSeconds: TimeInterval = 1

    /// **只重新分類 `network`。** 睡醒後拿到的 401 仍是真的 401。
    /// 清醒時的真斷網維持 `network` —— 實測 7 天內有 1 筆，那是真的失敗。
    func accountingForSleep(asleepSeconds: TimeInterval) -> FetchFailure {
        guard kind == .network, asleepSeconds > Self.sleepThresholdSeconds else { return self }
        return FetchFailure(
            kind: .slept, httpStatus: httpStatus,
            detail: "請求期間系統睡眠約 \(Int(asleepSeconds.rounded())) 秒，本次未觀測（非服務故障）：\(detail)"
        )
    }
}
