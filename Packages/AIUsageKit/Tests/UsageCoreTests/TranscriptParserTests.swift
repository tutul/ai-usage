import Testing
import Foundation
@testable import UsageCore

/// 以下 fixture 照真實紀錄的形狀撰寫（已去除對話內容），數字取自實際觀測。
///
/// 一次 API 請求會產生多行，每個內容區塊一行 —— `uuid` 不同、`requestId` 相同，
/// **而且每一行都帶著同一份 usage**。
private let blockA = """
{"type":"assistant","uuid":"db1d2263-0000-0000-0000-000000000001","requestId":"req_abc",
"sessionId":"sess_1","cwd":"/Users/tutu/program/tools/ai-usage","gitBranch":"main",
"timestamp":"2026-09-05T02:40:00.000Z",
"message":{"usage":{"input_tokens":12,"cache_creation_input_tokens":3220,
"cache_read_input_tokens":87389,"output_tokens":1478,
"cache_creation":{"ephemeral_1h_input_tokens":3220,"ephemeral_5m_input_tokens":0}}}}
"""

private let blockB = """
{"type":"assistant","uuid":"935850f7-0000-0000-0000-000000000002","requestId":"req_abc",
"sessionId":"sess_1","cwd":"/Users/tutu/program/tools/ai-usage","gitBranch":"main",
"timestamp":"2026-09-05T02:40:00.000Z",
"message":{"usage":{"input_tokens":12,"cache_creation_input_tokens":3220,
"cache_read_input_tokens":87389,"output_tokens":1478,
"cache_creation":{"ephemeral_1h_input_tokens":3220,"ephemeral_5m_input_tokens":0}}}}
"""

private let userLine = """
{"type":"user","uuid":"aaaa","sessionId":"sess_1","timestamp":"2026-09-05T02:39:00.000Z",
"message":{"role":"user","content":"hi"}}
"""

@Suite("對話紀錄解析")
struct TranscriptParserTests {
    /// 回歸測試：本專案最容易犯的灌水錯誤。
    /// 實測 16,911 行只對應 9,746 次請求；若以 uuid 去重，token 會被放大約 1.74 倍，
    /// 而且不均勻 —— 內容區塊愈多的請求被放大愈多，看起來完全合理但整份數據是錯的。
    @Test("同一次請求的多行共用 requestId，去重後只算一次")
    func deduplicatesByRequestId() throws {
        let a = try #require(TranscriptParser.parse(line: blockA))
        let b = try #require(TranscriptParser.parse(line: blockB))
        #expect(a.requestKey == b.requestKey, "去重鍵必須是 requestId，不能是 uuid")
        #expect(a.requestKey == "req_abc")
        #expect(a.cacheReadTokens == b.cacheReadTokens, "兩行帶的是同一份 usage")
    }

    @Test("欄位對應正確，含 TTL 分解")
    func fields() throws {
        let r = try #require(TranscriptParser.parse(line: blockA))
        #expect(r.inputTokens == 12)
        #expect(r.cacheCreationTokens == 3220)
        #expect(r.cacheReadTokens == 87389)
        #expect(r.outputTokens == 1478)
        #expect(r.ttl1hTokens == 3220)
        #expect(r.ttl5mTokens == 0)
        #expect(r.sessionID == "sess_1")
        #expect(r.gitBranch == "main")
    }

    @Test("沒有 usage 的行忽略")
    func skipsNonUsageLines() {
        #expect(TranscriptParser.parse(line: userLine) == nil)
        #expect(TranscriptParser.parse(line: "not json") == nil)
        #expect(TranscriptParser.parse(line: "") == nil)
    }

    /// 少數行沒有 requestId（實測 16,911 行中有 13 行），不能整行丟掉。
    @Test("缺 requestId 時退回用 uuid")
    func fallsBackToUuid() throws {
        let line = blockA.replacingOccurrences(of: "\"requestId\":\"req_abc\",", with: "")
        let r = try #require(TranscriptParser.parse(line: line))
        #expect(r.requestKey == "db1d2263-0000-0000-0000-000000000001")
    }
}
