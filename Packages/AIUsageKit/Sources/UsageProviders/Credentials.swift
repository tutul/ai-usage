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

/// Claude：讀本 app **自己的** Keychain 項目，由使用者跑 `claude setup-token` 後存入。
/// 不讀 Claude Code 的項目 —— keychain 跨 app 分享綁 Team ID，非同隊不可行。
public struct ClaudeCredentialSource: CredentialSource {
    public let keychainService: String

    public init(keychainService: String = "ai-usage.claude-oauth") {
        self.keychainService = keychainService
    }

    public func accessToken() throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &query) {
            SecItemCopyMatching($0.pointee as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else {
            throw FetchFailure(
                kind: .auth,
                detail: "Keychain 中沒有 \(keychainService)。請執行 `claude setup-token` 後將 token 存入。"
            )
        }
        return token
    }

    public func store(token: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = Data(token.utf8)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FetchFailure(kind: .auth, detail: "寫入 Keychain 失敗（OSStatus \(status)）")
        }
    }
}
