import Foundation
import Security
import UsageCore

public protocol CredentialSource: Sendable {
    func accessToken() throws -> String
}

/// Codex：**唯讀** `~/.codex/auth.json`，續期交給 ChatGPT.app。
/// 絕不寫回 —— 與其續期邏輯打架會弄壞它的登入狀態。
public struct CodexCredentialSource: CredentialSource {
    public let path: URL

    public init(path: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/auth.json")) {
        self.path = path
    }

    struct Payload: Decodable {
        struct Tokens: Decodable {
            let access_token: String
            let account_id: String?
        }
        let tokens: Tokens
    }

    func payload() throws -> Payload {
        guard let data = try? Data(contentsOf: path) else {
            throw FetchFailure(kind: .auth, detail: "讀不到 \(path.path) —— ChatGPT.app 是否已登入？")
        }
        do {
            return try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FetchFailure(kind: .auth, detail: "auth.json 格式非預期：\(error)")
        }
    }

    public func accessToken() throws -> String { try payload().tokens.access_token }
    public func accountID() throws -> String? { try payload().tokens.account_id }
}
