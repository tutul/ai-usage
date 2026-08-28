import Foundation

enum ISO8601 {
    /// Claude 回傳的 `resets_at` 帶 6 位小數秒與時區位移，需兩種設定都試。
    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

public enum CodexUsageParser {
    /// 逐一檢視所有窗物件，**依 `limit_window_seconds` 決定窗別**，不看它出現在哪個欄位。
    public static func parse(body: String, observedAt: Date) throws -> UsageSnapshot {
        guard let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw FetchFailure(kind: .parse, detail: "回應不是 JSON 物件") }

        guard let rateLimit = root["rate_limit"] as? [String: Any] else {
            throw FetchFailure(kind: .parse, detail: "缺少 rate_limit")
        }

        var candidates: [[String: Any]] = []
        for key in ["primary_window", "secondary_window"] {
            if let window = rateLimit[key] as? [String: Any] { candidates.append(window) }
        }
        for source in [rateLimit["additional_rate_limits"], root["additional_rate_limits"]] {
            if let extra = source as? [[String: Any]] { candidates.append(contentsOf: extra) }
        }

        var windows: [UsageWindow] = []
        for window in candidates {
            guard let kind = WindowKind.from(limitWindowSeconds: window["limit_window_seconds"] as? Int),
                  let percent = (window["used_percent"] as? NSNumber)?.doubleValue
            else { continue }
            let resetsAt = (window["reset_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            windows.append(UsageWindow(kind: kind, percent: percent, resetsAt: resetsAt))
        }

        return UsageSnapshot(
            service: .codex, observedAt: observedAt, windows: windows,
            rawBody: body, planType: root["plan_type"] as? String
        )
    }
}

public enum ClaudeUsageParser {
    /// Claude 以具名欄位回傳，但仍統一經由秒數對應到窗別，讓兩個 provider 的規則一致。
    static let windowSeconds: [String: Int] = [
        "seven_day": WindowKind.weeklySeconds,
        "five_hour": WindowKind.sessionSeconds
    ]

    public static func parse(body: String, observedAt: Date) throws -> UsageSnapshot {
        guard let data = body.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw FetchFailure(kind: .parse, detail: "回應不是 JSON 物件") }

        var windows: [UsageWindow] = []
        for (key, seconds) in windowSeconds {
            guard let window = root[key] as? [String: Any],
                  let kind = WindowKind.from(limitWindowSeconds: seconds),
                  let percent = (window["utilization"] as? NSNumber)?.doubleValue
            else { continue }
            let resetsAt = (window["resets_at"] as? String).flatMap(ISO8601.date(from:))
            windows.append(UsageWindow(kind: kind, percent: percent, resetsAt: resetsAt))
        }

        return UsageSnapshot(
            service: .claude, observedAt: observedAt, windows: windows, rawBody: body
        )
    }
}
