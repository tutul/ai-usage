import Foundation
import Observation
import UsageCore

/// 選單「進階」裡的 Claude client ID 覆寫。
///
/// 和 `TrackingSettings` 一樣存在 `UserDefaults`：它不影響任何推導，只影響續期時送什麼。
/// 續期端讀的是同一個 key（`ClaudeClientID.resolve()`），所以改了下一次續期就生效。
@MainActor
@Observable
public final class ClaudeClientIDSettings {
    /// 目前生效的覆寫值。nil = 使用預設。
    public private(set) var override: String?

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        override = defaults.string(forKey: ClaudeClientID.defaultsKey).flatMap(ClaudeClientID.normalized)
    }

    /// 回傳 false 代表格式不對、**沒有套用** —— 不存壞值，免得下一次續期拿它去打端點。
    /// 空字串或與預設相同，等同還原預設。
    public func apply(_ raw: String) -> Bool {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reset()
            return true
        }
        guard let value = ClaudeClientID.normalized(raw) else { return false }
        if value == ClaudeClientID.defaultValue {
            reset()
        } else {
            defaults.set(value, forKey: ClaudeClientID.defaultsKey)
            override = value
        }
        return true
    }

    public func reset() {
        defaults.removeObject(forKey: ClaudeClientID.defaultsKey)
        override = nil
    }
}
