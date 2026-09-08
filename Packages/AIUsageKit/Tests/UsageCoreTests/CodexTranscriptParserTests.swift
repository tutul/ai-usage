import Testing
import Foundation
@testable import UsageCore

/// fixture 照真實紀錄的形狀（已去除對話內容），數字取自實際觀測。
private let sessionMeta = """
{"timestamp":"2026-08-29T05:11:25.863Z","ordinal":0,"type":"session_meta",
"payload":{"cwd":"/Users/tutu/Documents/Codex/2026-08-29/jo4","type":"session_meta"}}
"""

private let turn1 = """
{"timestamp":"2026-08-29T05:11:33.736Z","ordinal":1,"type":"event_msg",
"payload":{"type":"token_count","info":{"last_token_usage":
{"input_tokens":24636,"cached_input_tokens":17152,"cache_write_input_tokens":512,
"output_tokens":181,"reasoning_output_tokens":27,"total_tokens":24817}}}}
"""

/// 實測 `ordinal` 在檔內會重複，但重複的那些帶的是**不同的數字**。
private let turn2SameOrdinal = """
{"timestamp":"2026-08-29T05:12:01.000Z","ordinal":1,"type":"event_msg",
"payload":{"type":"token_count","info":{"last_token_usage":
{"input_tokens":100,"cached_input_tokens":200,"cache_write_input_tokens":0,
"output_tokens":10,"reasoning_output_tokens":5,"total_tokens":315}}}}
"""

@Suite("Codex 對話紀錄解析")
struct CodexTranscriptParserTests {
    private func parse(_ lines: [String]) -> [CacheRequest] {
        CodexTranscriptParser.parse(lines: lines, sessionID: "01a04bed-d93c-7fe2-ac86-04bb15004331")
    }

    /// 欄位名與 Claude 不同，對錯了不會報錯，只會讓讀寫兩欄互換 ——
    /// 圖表照樣畫得出來，數字全錯。
    @Test("欄位對應：cached_input=讀取、cache_write=寫入、reasoning 併入 output")
    func fieldMapping() throws {
        let r = try #require(parse([sessionMeta, turn1]).first)
        #expect(r.service == .codex)
        #expect(r.cacheReadTokens == 17152, "cached_input_tokens 是從快取讀")
        #expect(r.cacheCreationTokens == 512, "cache_write_input_tokens 是寫入快取")
        #expect(r.inputTokens == 24636)
        #expect(r.outputTokens == 181 + 27, "reasoning 也是輸出，計費上算 output")
        #expect(r.ttl5mTokens == 0, "Codex 沒有 TTL 分解，不可臆造")
        #expect(r.ttl1hTokens == 0)
    }

    /// 回歸測試：`cwd` 只出現在第一行的 session_meta。
    /// 逐行獨立解析的話，所有記錄的專案都會是 nil，表格會全部擠進「(未知)」。
    @Test("cwd 從 session_meta 往下帶")
    func carriesCwdForward() throws {
        let rows = parse([sessionMeta, turn1, turn2SameOrdinal])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.cwd == "/Users/tutu/Documents/Codex/2026-08-29/jo4" })
    }

    /// 回歸測試：ordinal 在檔內會重複，但那是真的不同記錄。
    /// 只用 ordinal 當去重鍵會把後者丟掉、少算用量。
    @Test("重複的 ordinal 靠 timestamp 區分，兩筆都留下")
    func distinguishesDuplicateOrdinalsByTimestamp() throws {
        let rows = parse([sessionMeta, turn1, turn2SameOrdinal])
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.requestKey)).count == 2, "去重鍵必須含 timestamp")
        #expect(rows.map(\.cacheReadTokens) == [17152, 200])
    }

    @Test("沒有 last_token_usage 的行忽略")
    func skipsNonUsageLines() {
        #expect(parse([sessionMeta]).isEmpty)
        #expect(parse(["not json", ""]).isEmpty)
    }

    @Test("從檔名取 session id")
    func sessionIDFromFileName() {
        let name = "rollout-2026-08-29T13-11-13-01a04bed-d93c-7fe2-ac86-04bb15004331.jsonl"
        #expect(CodexTranscriptParser.sessionID(fromFileName: name)
                == "01a04bed-d93c-7fe2-ac86-04bb15004331")
    }
}
