import Foundation
import Network

/// 系統現在有沒有可用的網路路徑。
///
/// 抓取因網路失敗時用來分辨「連不上服務」與「這台機器沒有網路」（見 D-022）。
///
/// **只看得出「完全沒連線」，看不出「Wi-Fi 連著但不通」。** 後者有 IP、系統認為有路可走，
/// 請求會一路等到逾時 —— 實測 2026-09-15～10-10 的 13 段離線裡，這種佔 5 段、460 筆（85%），
/// 它們仍然會被記成 `network`。要分辨得真的送一個請求到第三方去問，
/// 而這個 app 不為此多連任何對象。這是知情的取捨，不是疏漏。
public final class NetworkPathWatcher: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    /// 還沒收到第一次回報時當作有網路 —— 寧可把離線記成失敗，不可把失敗記成離線。
    private var usable = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let usable = Self.isUsable(path.status)
            self.lock.withLock { self.usable = usable }
        }
        monitor.start(queue: DispatchQueue(label: "com.tutu.aiusage.network-path", qos: .utility))
    }

    deinit { monitor.cancel() }

    public var hasRoute: Bool { lock.withLock { usable } }

    /// 只有 `.unsatisfied` 算沒有網路。`.requiresConnection`（例如隨選 VPN 尚未撥上）
    /// 是「一連線就會有路」，這時的失敗說不準是誰的問題，維持記成 `network`。
    static func isUsable(_ status: NWPath.Status) -> Bool {
        status != .unsatisfied
    }
}
