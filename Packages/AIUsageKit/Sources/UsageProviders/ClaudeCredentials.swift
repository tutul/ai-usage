import Foundation
import Security
import UsageCore

/// Claude 憑證來源。
///
/// **讀 Claude Code 自己的憑證，而非 `claude setup-token` 產生的 token。**
/// 實測發現 setup-token 的 token 缺少 `user:profile` scope，打 `/api/oauth/usage`
/// 會得到 `permission_error: OAuth token does not meet scope requirement user:profile`。
/// Claude Code 登入後的 token 則含該 scope。
///
/// 「keychain 跨 app 綁 Team ID」的限制只適用於**沙盒** app；本 app 非沙盒，
/// 首次讀取時 macOS 會跳一次授權對話框，按「一律允許」即可。
///
/// **唯讀** —— 續期交給 Claude Code，本 app 絕不寫回，避免與其續期邏輯衝突。
public struct ClaudeCredentialSource: CredentialSource {
    public let fileURL: URL
    public let keychainService: String

    public init(
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/.credentials.json"),
        keychainService: String = "Claude Code-credentials"
    ) {
        self.fileURL = fileURL
        self.keychainService = keychainService
    }

    struct Payload: Decodable {
        struct OAuth: Decodable {
            let accessToken: String
            let expiresAt: Double?
            let scopes: [String]?
        }
        let claudeAiOauth: OAuth
    }

    public func accessToken() throws -> String {
        let data = try rawCredentials()
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw FetchFailure(kind: .auth, detail: "Claude 憑證格式非預期：\(error)")
        }

        if let expiresAt = payload.claudeAiOauth.expiresAt {
            // 毫秒或秒都可能，用量級判斷
            let seconds = expiresAt > 1e11 ? expiresAt / 1000 : expiresAt
            if Date(timeIntervalSince1970: seconds) < Date() {
                throw FetchFailure(
                    kind: .auth,
                    detail: "Claude token 已過期。開一次 Claude Code 讓它續期即可 —— 本 app 唯讀，不會自行續期。"
                )
            }
        }
        if let scopes = payload.claudeAiOauth.scopes, !scopes.contains("user:profile") {
            throw FetchFailure(
                kind: .auth,
                detail: "Claude token 缺少 user:profile scope（目前：\(scopes.joined(separator: ", "))）。"
            )
        }
        return payload.claudeAiOauth.accessToken
    }

    /// 先找檔案，再找 Keychain。
    func rawCredentials() throws -> Data {
        if let data = try? Data(contentsOf: fileURL) { return data }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw FetchFailure(
                kind: .auth,
                detail: status == errSecUserCanceled
                    ? "你拒絕了 Keychain 存取。需允許本 app 讀取「Claude Code-credentials」。"
                    : "找不到 Claude Code 憑證（OSStatus \(status)）。請確認已安裝 Claude Code 並登入。"
            )
        }
        return data
    }
}
