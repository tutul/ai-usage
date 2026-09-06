import Foundation
import Observation
import UsageCore

/// 要追蹤哪些服務。有人只有 Claude、有人只有 Codex，
/// 沒訂閱的那家會一直產生 auth 失敗，看起來像壞掉。
///
/// **存在 `UserDefaults`，不是 DB 的 `setting` 表。** 那張表放的是**推導參數**
/// （`delta_max_gap_seconds`、`reset_tolerance_seconds`），外部分析工具必須套用
/// 同一份規則才算得出一樣的結果。「要不要追蹤」不影響任何推導，
/// 只影響這個 app 抓不抓、畫不畫 —— 混進去只會讓那張表的意義變模糊。
///
/// **關閉不會刪除歷史。** 已經記錄的樣本留著，重新開啟就看得到。
@MainActor
@Observable
public final class TrackingSettings {
    public private(set) var enabled: Set<Service>

    @ObservationIgnored private let defaults: UserDefaults

    private static func key(_ service: Service) -> String {
        "tracking.\(service.rawValue).enabled"
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // 沒設定過就是開啟 —— 新使用者兩家都追蹤，再自行關掉不需要的那家。
        var initial: Set<Service> = []
        for service in Service.allCases
        where (defaults.object(forKey: Self.key(service)) as? Bool) ?? true {
            initial.insert(service)
        }
        self.enabled = initial
    }

    public func isEnabled(_ service: Service) -> Bool { enabled.contains(service) }

    public func setEnabled(_ service: Service, _ value: Bool) {
        if value { enabled.insert(service) } else { enabled.remove(service) }
        defaults.set(value, forKey: Self.key(service))
    }

    /// 依 `Service.allCases` 的順序回傳已啟用者，讓 UI 的排列穩定。
    public var enabledServices: [Service] {
        Service.allCases.filter(enabled.contains)
    }
}
