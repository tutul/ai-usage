import Foundation

/// 這台機器現在連得到網際網路嗎。
///
/// **只在抓取因網路失敗之後才問**，用來分辨「服務連不上」與「這台機器沒有網路」。
/// 兩者在 `URLSession` 看來常常一模一樣：實測 2026-09-15～10-10 的 13 段離線裡，
/// 有 5 段（460 筆，含一段 28 小時）回的是 `The request timed out.` ——
/// Wi-Fi 連著、有 IP、但封包出不去。**看網路介面的狀態分不出這種**
/// （`NWPathMonitor` 會說有路可走），只有真的送一個請求出去才知道。
///
/// 問的對象是 Apple 的連線檢查頁，也就是 macOS 自己判斷「這個 Wi-Fi 有沒有網路」
/// 用的那一個，由 Apple 營運、與兩家用量端點無關。
/// 不拿另一家的端點當對照：兩家若剛好共用同一個 CDN，CDN 出事時兩邊一起失敗，
/// 服務故障就會被誤判成離線 —— 那是把真的失敗藏起來，方向錯得最嚴重。
public struct ConnectivityProbe: Sendable {
    public static let endpoint = URL(string: "https://captive.apple.com/hotspot-detect.html")!
    /// 實測連得上時約 0.05 秒。離線時每一輪取樣最多要多等兩倍這麼久，所以訂得短。
    public static let timeout: TimeInterval = 5

    let endpoint: URL

    public init(endpoint: URL = ConnectivityProbe.endpoint) {
        self.endpoint = endpoint
    }

    /// 連續兩次都不通才算離線。
    ///
    /// 這個檢查錯在「有網路卻說沒有」的代價最高 —— 真的服務故障會被記成離線而藏起來。
    /// 開發時就遇過一次：明明有網路，單次檢查卻等滿 5 秒逾時（原因沒查到，
    /// 之後連續 40 次都在 0.15 秒內成功）。多問一次的成本只在真的離線時才付。
    public func isOnline() async -> Bool {
        for _ in 0..<Self.attempts where await attempt() { return true }
        return false
    }

    static let attempts = 2

    private func attempt() async -> Bool {
        let request = URLRequest(
            url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Self.timeout
        )
        // 不帶 cookie、不留快取 —— 這個請求只需要知道「通不通」
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else { return false }
        return Self.isSuccess(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
    }

    /// 要看內容，不能只看 200：需要登入的 Wi-Fi 會攔下請求、回自己的登入頁，狀態碼也是 200。
    static func isSuccess(status: Int, body: String) -> Bool {
        status == 200 && body.contains("<TITLE>Success</TITLE>")
    }
}
