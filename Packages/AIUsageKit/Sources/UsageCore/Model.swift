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
