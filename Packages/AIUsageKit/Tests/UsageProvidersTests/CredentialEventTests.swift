import Testing
import Foundation
import UsageCore
@testable import UsageProviders

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CredentialEvent] = []
    func append(_ event: CredentialEvent) { lock.lock(); items.append(event); lock.unlock() }
    var events: [CredentialEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

/// 憑證放在暫存檔；兩個 Keychain service 名稱是隨機的、必定不存在，
/// 所以讀取順序會落到檔案，不會碰到真正的 Keychain 項目、也不會跳授權提示。
private func makeSource(box: EventBox, expiresIn: TimeInterval = 3600) throws -> ClaudeCredentialSource {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "aiusage-cred-\(UUID().uuidString).json")
    let expiresAt = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
    let json: [String: Any] = ["claudeAiOauth": [
        "accessToken": "access-test", "refreshToken": "refresh-test",
        "expiresAt": expiresAt, "scopes": ["user:profile"]
    ]]
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let unique = UUID().uuidString
    return ClaudeCredentialSource(
        fileURL: url,
        keychainService: "AIUsage-test-seed-\(unique)",
        privateKeychainService: "AIUsage-test-own-\(unique)",
        eventSink: { box.append($0) }
    )
}

@Suite("憑證事件")
struct CredentialEventTests {
    /// 每 5 分鐘讀一次，每次都記會把真正的變化淹沒。
    @Test("啟動後第一次讀到記一筆來源，來源沒變就不再記")
    func sourceRecordedOnlyOnChange() async throws {
        let box = EventBox()
        let source = try makeSource(box: box)
        _ = try await source.accessToken()
        _ = try await source.accessToken()
        #expect(box.events.count == 1)
        #expect(box.events.first?.kind == .sourceChanged)
        #expect(box.events.first?.source == "file")
    }

    /// 09-13 缺的就是這個：被拒時 token 到底過期了沒有。
    @Test("用量端點拒絕時，記下來源與剩餘效期")
    func rejectionRecordsRemainingLifetime() async throws {
        let box = EventBox()
        let source = try makeSource(box: box, expiresIn: 1800)
        await source.noteRejected(FetchFailure(kind: .auth, httpStatus: 401, detail: "token 失效或已過期"))
        let event = try #require(box.events.last)
        #expect(event.kind == .rejected)
        #expect(event.source == "file")
        #expect(event.detail.contains("分鐘"))
        #expect(!event.detail.contains("未知"))
        #expect(!event.detail.contains("access-test"), "事件絕不含 token")
    }
}

@Suite("client ID 與自癒")
struct ClientIDRenewalTests {
    @Test("續期請求帶的是注入的 client ID")
    func requestUsesInjectedClientID() throws {
        let request = try ClaudeCredentialSource.renewalRequest(
            refreshToken: "r", clientID: "11111111-2222-4333-8444-555555555555", userAgent: .claude
        )
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        #expect(json["client_id"] == "11111111-2222-4333-8444-555555555555")
    }

    @Test("invalid_client 轉成可行動的訊息，而且不是 auth")
    func invalidClientExplained() {
        let raw = FetchFailure(kind: .auth, httpStatus: 401, detail: #"token 失效或已過期：{"error":"invalid_client"}"#)
        let explained = ClaudeCredentialSource.explained(raw)
        #expect(explained.kind == .invalidClient)
        #expect(explained.detail.contains("進階"))
    }

    /// client ID 錯了不代表 refresh token 壞了。丟掉它等於親手弄斷一條還能用的鏈。
    @Test("invalid_client 不丟憑證；invalid_grant 與 auth 會丟；網路錯誤不丟")
    func discardDecision() {
        #expect(!ClaudeCredentialSource.shouldDiscard(after: .init(kind: .invalidClient, detail: "")))
        #expect(ClaudeCredentialSource.shouldDiscard(after: .init(kind: .http, httpStatus: 400, detail: #"{"error":"invalid_grant"}"#)))
        #expect(ClaudeCredentialSource.shouldDiscard(after: .init(kind: .auth, httpStatus: 401, detail: "")))
        #expect(!ClaudeCredentialSource.shouldDiscard(after: .init(kind: .network, detail: "timed out")))
    }
}
