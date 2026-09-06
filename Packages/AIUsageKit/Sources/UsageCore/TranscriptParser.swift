import Foundation

/// Claude Code 對話紀錄（JSONL）中，一次 API 請求的 token 分解。
public struct CacheRequest: Sendable, Hashable {
    /// 去重鍵。見 `TranscriptParser.parse` 的說明。
    public let requestKey: String
    public let sessionID: String?
    public let cwd: String?
    public let gitBranch: String?
    public let observedAt: Date
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    public let ttl5mTokens: Int
    public let ttl1hTokens: Int

    public init(
        requestKey: String, sessionID: String?, cwd: String?, gitBranch: String?,
        observedAt: Date, inputTokens: Int, cacheCreationTokens: Int,
        cacheReadTokens: Int, outputTokens: Int, ttl5mTokens: Int, ttl1hTokens: Int
    ) {
        self.requestKey = requestKey
        self.sessionID = sessionID
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.observedAt = observedAt
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.ttl5mTokens = ttl5mTokens
        self.ttl1hTokens = ttl1hTokens
    }
}

public enum TranscriptParser {
    /// 解析 JSONL 的一行。沒有 `usage` 的行（使用者訊息、工具結果等）回傳 nil。
    ///
    /// **去重鍵用 `requestId`，不是 `uuid`。** 一次 API 請求會產生多行 ——
    /// 每個內容區塊（文字、工具呼叫…）各一行，而**每一行都帶著同一份 `usage`**。
    /// 實測 16,911 行只對應 9,746 次請求，逐行加總會灌水約 1.74 倍，
    /// 而且不均勻：內容區塊愈多的請求被放大愈多。
    ///
    /// 少數行沒有 `requestId`（實測 16,911 行中有 13 行），退回用 `uuid`。
    public static func parse(line: String) -> CacheRequest? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let key = (object["requestId"] as? String) ?? (object["uuid"] as? String),
              let timestamp = object["timestamp"] as? String,
              let observedAt = ISO8601.date(from: timestamp)
        else { return nil }

        let creation = usage["cache_creation"] as? [String: Any]
        return CacheRequest(
            requestKey: key,
            sessionID: object["sessionId"] as? String,
            cwd: object["cwd"] as? String,
            gitBranch: object["gitBranch"] as? String,
            observedAt: observedAt,
            inputTokens: int(usage["input_tokens"]),
            cacheCreationTokens: int(usage["cache_creation_input_tokens"]),
            cacheReadTokens: int(usage["cache_read_input_tokens"]),
            outputTokens: int(usage["output_tokens"]),
            ttl5mTokens: int(creation?["ephemeral_5m_input_tokens"]),
            ttl1hTokens: int(creation?["ephemeral_1h_input_tokens"])
        )
    }

    /// 缺欄位一律視為 0 —— 這裡的 0 是真的「沒有用到這種 token」，
    /// 與 sample 那條管線的「無資料 ≠ 0」不同：紀錄是完整的，不會漏。
    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
    }
}
