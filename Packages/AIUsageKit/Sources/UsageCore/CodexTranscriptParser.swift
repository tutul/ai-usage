import Foundation

/// Codex 對話紀錄（`~/.codex/sessions` 與 `archived_sessions` 的 `rollout-*.jsonl`）。
///
/// 與 Claude 的差異，每一項都影響實作：
///
/// | | Claude | Codex |
/// |---|---|---|
/// | 去重鍵 | `requestId` | 沒有；用 **session + `ordinal` + `timestamp`** |
/// | 專案路徑 | 每行都有 `cwd` | **只在第一行的 `session_meta`**，要往下帶 |
/// | 每輪用量 | 每行一份 | `payload.info.last_token_usage` |
/// | 快取 TTL | 有 5m／1h 分解 | **沒有，且無從觀測** |
///
/// `ordinal` 在檔內會重複（實測 16 個檔裡有 6 個），但**重複的那些帶的是不同的
/// 數字**（0 組相同），所以是真的不同記錄、可以加總 —— 與 Claude 那個「多行共用
/// 同一份 usage」的灌水陷阱不同。加上 `timestamp` 之後完全唯一。
///
/// `last_token_usage` 是**每一輪**的量，不是累計：實測某檔 32 筆相加為 6,708,532，
/// 與最後一筆 `total_token_usage` 的 6,708,532 完全相同。
public enum CodexTranscriptParser {
    /// 解析整個 session 檔。**不能逐行獨立解析** —— `cwd` 只出現在第一行。
    public static func parse(lines: [String], sessionID: String) -> [CacheRequest] {
        var cwd: String?
        var result: [CacheRequest] = []

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let payload = object["payload"] as? [String: Any]
            if cwd == nil, let candidate = payload?["cwd"] as? String { cwd = candidate }

            guard let usage = (payload?["info"] as? [String: Any])?["last_token_usage"] as? [String: Any],
                  let timestamp = object["timestamp"] as? String,
                  let observedAt = ISO8601.date(from: timestamp)
            else { continue }

            let ordinal = (object["ordinal"] as? Int).map(String.init) ?? "?"
            result.append(CacheRequest(
                requestKey: "codex:\(sessionID):\(ordinal):\(timestamp)",
                service: .codex,
                sessionID: sessionID,
                cwd: cwd,
                gitBranch: nil,
                observedAt: observedAt,
                inputTokens: int(usage["input_tokens"]),
                // Codex 的欄位名不同：cached_input_tokens = 從快取讀，
                // cache_write_input_tokens = 寫進快取。
                cacheCreationTokens: int(usage["cache_write_input_tokens"]),
                cacheReadTokens: int(usage["cached_input_tokens"]),
                // reasoning 也是輸出，計費上算在 output —— 併進 output 才與 Claude 可比。
                outputTokens: int(usage["output_tokens"]) + int(usage["reasoning_output_tokens"]),
                // Codex 的紀錄沒有 TTL 分解，留 0。不要拿 Claude 的門檻來套。
                ttl5mTokens: 0,
                ttl1hTokens: 0
            ))
        }
        return result
    }

    /// 從檔名取 session id：`rollout-<時間>-<uuid>.jsonl`。
    public static func sessionID(fromFileName name: String) -> String {
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        // uuid 是最後五段（8-4-4-4-12），用它比整個檔名穩定。
        let parts = stem.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }

    private static func int(_ value: Any?) -> Int {
        (value as? Int) ?? (value as? NSNumber)?.intValue ?? 0
    }
}
