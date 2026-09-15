import Foundation

/// Claude OAuth 續期用的 client ID。
///
/// 這是 Claude Code 的 OAuth public client，**非機密**，從 `claude` 執行檔取得
/// （字串 `CLIENT_ID:"…"`；同一處還有 `DESIGN_CLIENT_ID`，不是它）。
/// 寫死是單點故障 —— 官方一換，所有人的續期同時永久失敗。所以允許使用者覆寫，
/// 不必等新版本。
///
/// 放在 UsageCore：續期（UsageProviders）要讀它、設定 UI（UsageUI）要寫它，
/// 而那兩者互不依賴。
public enum ClaudeClientID {
    public static let defaultValue = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let defaultsKey = "claude.oauthClientID"

    /// 去空白、轉小寫。不是 UUID 格式就回 nil。
    public static func normalized(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard UUID(uuidString: value) != nil else { return nil }
        return value
    }

    /// 有合法的覆寫值就用它，否則用預設。
    /// **格式不對時退回預設，不拿壞值去打端點** —— 一個打錯的字元不該讓續期失敗。
    public static func resolve(defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: defaultsKey).flatMap(normalized) ?? defaultValue
    }
}
