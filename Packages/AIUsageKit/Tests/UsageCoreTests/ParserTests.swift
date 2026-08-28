import Testing
import Foundation
@testable import UsageCore

// 以下 fixture 皆為對真實端點探測所得的實際回應（已刪去識別欄位）。

/// 暫停期形狀：primary = 週窗，secondary = null
let codexWeeklyAsPrimary = """
{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
"primary_window":{"used_percent":2,"limit_window_seconds":604800,
"reset_after_seconds":138763,"reset_at":1787443161},
"secondary_window":null},"credits":{"has_credits":false,"balance":"0"}}
"""

/// 5 小時回歸後的預期形狀：primary = 5 小時，secondary = 週窗（欄位換位）
let codexSessionAsPrimary = """
{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
"primary_window":{"used_percent":63,"limit_window_seconds":18000,
"reset_after_seconds":9000,"reset_at":1787460000},
"secondary_window":{"used_percent":2,"limit_window_seconds":604800,
"reset_after_seconds":138763,"reset_at":1787443161}},
"credits":{"has_credits":false,"balance":"0"}}
"""

let claudeUsage = """
{"five_hour":{"utilization":45.0,"resets_at":"2026-08-21T13:49:59.858588+00:00","limit_dollars":null},
"seven_day":{"utilization":30.0,"resets_at":"2026-08-26T00:59:59.858620+00:00","limit_dollars":null},
"seven_day_opus":null,"extra_usage":{"is_enabled":true,"monthly_limit":2000},
"limits":[{"kind":"session","percent":45,"severity":"normal"},
{"kind":"weekly_all","percent":30,"severity":"normal"}]}
"""

@Suite("窗別判定")
struct WindowKindTests {
    @Test("依秒數對應，未知秒數保留原值")
    func mapping() {
        #expect(WindowKind.from(limitWindowSeconds: 604_800) == .weekly)
        #expect(WindowKind.from(limitWindowSeconds: 18_000) == .session)
        #expect(WindowKind.from(limitWindowSeconds: 3_600) == .other(seconds: 3_600))
        #expect(WindowKind.from(limitWindowSeconds: nil) == nil)
    }
}

@Suite("Codex 解析")
struct CodexParserTests {
    @Test("暫停期形狀：primary 是週窗")
    func weeklyAsPrimary() throws {
        let s = try CodexUsageParser.parse(body: codexWeeklyAsPrimary, observedAt: .now)
        #expect(s.weekly?.percent == 2)
        #expect(s.session == nil)
        #expect(s.planType == "plus")
    }

    /// 回歸測試：這是整個專案最危險的靜默失敗。
    /// 若依欄位位置對應，5 小時的 63% 會被寫進 weekly 序列而不報任何錯。
    @Test("欄位換位後仍正確：5 小時在 primary、週窗在 secondary")
    func sessionAsPrimaryDoesNotCorruptWeekly() throws {
        let s = try CodexUsageParser.parse(body: codexSessionAsPrimary, observedAt: .now)
        #expect(s.weekly?.percent == 2, "週窗必須仍是 2%，不可被 primary 的 5 小時值污染")
        #expect(s.session?.percent == 63)
        #expect(s.weekly?.resetsAt == Date(timeIntervalSince1970: 1_787_443_161))
    }

    @Test("兩種形狀解析出的週窗完全一致")
    func weeklyIdenticalAcrossShapes() throws {
        let a = try CodexUsageParser.parse(body: codexWeeklyAsPrimary, observedAt: .now).weekly
        let b = try CodexUsageParser.parse(body: codexSessionAsPrimary, observedAt: .now).weekly
        #expect(a == b)
    }

    @Test("缺少 rate_limit 時歸類為 parse 錯誤")
    func malformed() {
        #expect(throws: FetchFailure.self) {
            try CodexUsageParser.parse(body: #"{"plan_type":"plus"}"#, observedAt: .now)
        }
    }
}

@Suite("Claude 解析")
struct ClaudeParserTests {
    @Test("取出週窗與 5 小時窗，含 6 位小數秒的時間戳")
    func parse() throws {
        let s = try ClaudeUsageParser.parse(body: claudeUsage, observedAt: .now)
        #expect(s.weekly?.percent == 30.0)
        #expect(s.session?.percent == 45.0)
        let expected = ISO8601.date(from: "2026-08-26T00:59:59.858620+00:00")
        #expect(s.weekly?.resetsAt == expected)
    }

    @Test("null 分桶（seven_day_opus 等）不產生窗")
    func nullBucketsIgnored() throws {
        let s = try ClaudeUsageParser.parse(body: claudeUsage, observedAt: .now)
        #expect(s.windows.count == 2)
    }
}

@Suite("結構指紋")
struct JSONShapeTests {
    /// 這是 raw_payload 去重能成立的前提：值變、結構不變 → 指紋不變。
    @Test("易變值（reset_after_seconds/百分比）不改變指紋")
    func stableAcrossVolatileValues() {
        let later = codexWeeklyAsPrimary
            .replacingOccurrences(of: "138763", with: "138463")
            .replacingOccurrences(of: "\"used_percent\":2", with: "\"used_percent\":7")
        #expect(JSONShape.fingerprint(body: codexWeeklyAsPrimary) == JSONShape.fingerprint(body: later))
    }

    @Test("結構改變（窗換位使 secondary 由 null 變物件）會改變指紋")
    func changesWhenShapeChanges() {
        #expect(JSONShape.fingerprint(body: codexWeeklyAsPrimary)
                != JSONShape.fingerprint(body: codexSessionAsPrimary))
    }

    @Test("陣列元素個數不影響指紋")
    func arrayLengthIrrelevant() {
        let one = #"{"limits":[{"kind":"a","percent":1}]}"#
        let two = #"{"limits":[{"kind":"a","percent":1},{"kind":"b","percent":2}]}"#
        #expect(JSONShape.fingerprint(body: one) == JSONShape.fingerprint(body: two))
    }
}
