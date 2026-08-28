import Foundation
import UsageCore

public protocol UsageProvider: Sendable {
    var service: Service { get }
    /// 時間戳由實作在 **HTTP 回應成功之後**自行標記，不由呼叫端傳入 ——
    /// 「樣本時間 = 讀數取得的真實時刻」是規格，交給程式碼保證而非呼叫端自律。
    func fetch() async throws -> UsageSnapshot
}

/// User-Agent 在兩個端點都是**承載性**的，並非禮貌性標頭（皆已實測）：
/// - Claude：缺少 `claude-code/<ver>` 會落入嚴格限流桶，持續 429
/// - Codex：缺少擬真的 `codex_cli_rs/<ver> (...)` 會被 Cloudflare 擋下，回 403 HTML 挑戰頁
public struct UserAgent: Sendable, Hashable {
    public let value: String
    public init(_ value: String) { self.value = value }

    public static let claude = UserAgent("claude-code/2.0.0")
    public static let codex = UserAgent("codex_cli_rs/0.149.0 (Mac OS 26.6.2; arm64) Apple_Terminal")
}

enum HTTP {
    /// 403 與 401 必須分開：401 的補救是重新授權，403 是 UA／風控問題。
    /// 逾時要有界：實測 Codex 首次請求花了 21 秒（TLS 冷啟動 + Cloudflare）。
    /// URLSession 預設 60 秒對 5 分鐘一次的取樣過寬，寧可這輪放棄、下輪再來。
    static let timeout: TimeInterval = 30

    static func perform(_ original: URLRequest) async throws -> String {
        var request = original
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw FetchFailure(kind: .network, detail: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FetchFailure(kind: .network, detail: "非 HTTP 回應")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        switch http.statusCode {
        case 200..<300:
            return body
        case 401:
            throw FetchFailure(kind: .auth, httpStatus: 401, detail: "token 失效或已過期")
        case 403:
            // 兩種完全不同的 403：API 層的權限錯誤（JSON），與 Cloudflare 的風控頁（HTML）。
            // 補救方式不同，訊息必須分開，否則會叫人去查錯方向。
            if let data = body.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw FetchFailure(
                    kind: .auth, httpStatus: 403,
                    detail: "權限不足：\(message)"
                )
            }
            throw FetchFailure(
                kind: .blocked, httpStatus: 403,
                detail: "被風控擋下（多為 User-Agent 問題，非認證）：\(body.prefix(120))"
            )
        default:
            throw FetchFailure(
                kind: .http, httpStatus: http.statusCode, detail: String(body.prefix(200))
            )
        }
    }
}
