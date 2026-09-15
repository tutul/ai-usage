import Foundation
import Security
import os
import UsageCore

/// Claude 憑證來源，**含自動續期，且續期後寫入本 app 自己的 Keychain 項目**。
///
/// ## 為什麼不寫回 Claude Code 的項目
///
/// 原本是讀寫同一個項目（`Claude Code-credentials`）。實測（D-015、D-016）發現
/// **對該項目呼叫 `SecItemUpdate` 會把它的「分區清單」換成呼叫者的身分**，
/// 把 Claude Code 自己用的 `apple-tool:` 踢掉 —— 於是使用者每天被 macOS 要求輸入
/// 兩三次鑰匙圈密碼。前後對照（2026-09-05 10:40，同一分鐘內）：
///
///     寫入前: apple-tool:  apple:  teamid:2PUS5K7TA4
///     寫入後: teamid:2PUS5K7TA4
///
/// **讀取不會造成這件事，只有寫入會**（15 小時唯讀期間清單完全沒動）。
/// 所以改成：**讀 Claude Code 的項目，只寫自己的**。
///
/// ## 代價
///
/// refresh token 是單次有效的（2026-09-01 的競態中，第二個請求拿到 `invalid_grant`）。
/// 我們續期後 Claude Code 手上那份就作廢了，`claude` CLI 會被登出；
/// 重新登入後自癒又會從它那裡重新種子，所以常用 CLI 的人會一再被登出。
/// 這是知情的取捨：使用者不用 CLI，而每天兩三次密碼提示是持續的成本。
///
/// 為此保留自癒：續期若因憑證失效而失敗，就刪掉我們自己的項目，
/// 下次取樣會重新從 Claude Code 的項目取得憑證。所以使用者哪天重新登入，
/// 我們會自己接上，不需要任何手動處理。
///
/// ## 事件
///
/// 來源改變、續期成敗、自癒、被用量端點拒絕，都送一筆 `CredentialEvent`（見 D-017）。
///
public actor ClaudeCredentialSource: CredentialSource {
    public static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// 提前續期的緩衝，避免剛好在請求途中過期。
    public static let defaultRenewalMargin: TimeInterval = 300

    static let log = Logger(subsystem: "com.tutu.aiusage", category: "credentials")
    /// 被限流後的冷卻期。取樣每 5 分鐘一次，若不退避就等於持續敲一個認證端點。
    static let renewalCooldown: TimeInterval = 900

    /// 憑證從哪裡讀到的。來源一變就記一筆事件。
    enum Origin: String, Sendable {
        case own
        case file
        case claudeCode = "claude_code"
    }

    /// 續期失敗後的封鎖截止時間。actor 隔離，不需額外鎖。
    private var renewalBlockedUntil: Date?

    /// 續期的併發合流。見 `SingleFlight` 與 `renewCoalesced`。
    private let renewalFlight = SingleFlight<String>()

    private var lastOrigin: Origin?

    let fileURL: URL
    /// Claude Code 的項目。**唯讀** —— 寫它會重設它的分區清單。
    let keychainService: String
    /// 本 app 自己的項目，續期後寫這裡。
    let privateKeychainService: String
    let userAgent: UserAgent
    let renewalMargin: TimeInterval
    let renewalEnabled: Bool
    /// **每次續期時才呼叫**，所以使用者在選單改了 client ID，下一次續期就生效，不必重啟。
    let clientID: @Sendable () -> String
    let eventSink: CredentialEventSink?

    public init(
        fileURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".claude/.credentials.json"),
        keychainService: String = "Claude Code-credentials",
        privateKeychainService: String = "AIUsage-claude-credentials",
        userAgent: UserAgent = .claude,
        renewalMargin: TimeInterval = ClaudeCredentialSource.defaultRenewalMargin,
        renewalEnabled: Bool = true,
        clientID: @escaping @Sendable () -> String = { ClaudeClientID.defaultValue },
        eventSink: CredentialEventSink? = nil
    ) {
        self.fileURL = fileURL
        self.keychainService = keychainService
        self.privateKeychainService = privateKeychainService
        self.userAgent = userAgent
        self.renewalMargin = renewalMargin
        self.renewalEnabled = renewalEnabled
        self.clientID = clientID
        self.eventSink = eventSink
    }

    public func accessToken() async throws -> String {
        let credentials = try loadCredentials()
        guard let oauth = credentials["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { throw FetchFailure(kind: .auth, detail: "Claude 憑證格式非預期：缺少 claudeAiOauth.accessToken") }

        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") {
            throw FetchFailure(
                kind: .auth,
                detail: "Claude token 缺少 user:profile scope（目前：\(scopes.joined(separator: ", "))）。"
            )
        }

        guard needsRenewal(oauth) else {
            if !renewalEnabled && isExpired(oauth) {
                throw FetchFailure(
                    kind: .auth,
                    detail: "Claude token 已過期，本 app 目前不自行續期"
                          + "（避免寫回 Keychain 時重設分區清單）。開一次 Claude Code 讓它續期即可。"
                )
            }
            return token
        }

        guard let refreshToken = oauth["refreshToken"] as? String else {
            throw FetchFailure(kind: .auth, detail: "Claude token 已過期且無 refreshToken，請執行 `claude auth login`。")
        }
        if let blockedUntil = renewalBlockedUntil, blockedUntil > Date() {
            let minutes = max(1, Int(blockedUntil.timeIntervalSinceNow / 60))
            throw FetchFailure(
                kind: .rateLimited,
                detail: "續期端點限流中，約 \(minutes) 分鐘後重試（期間 Claude 用量暫停記錄）。"
            )
        }

        return try await renewCoalesced(refreshToken: refreshToken)
    }

    /// 用量端點拒絕 token 時由 provider 呼叫。**只記錄，不改變行為** ——
    /// 還沒有資料證明該怎麼反應（見 D-017）。
    public func noteRejected(_ failure: FetchFailure) {
        let oauth = (try? loadCredentials())?["claudeAiOauth"] as? [String: Any]
        let remaining = oauth.flatMap(Self.expiryDate)
            .map { "\(Int($0.timeIntervalSinceNow / 60)) 分鐘" } ?? "未知"
        emit(.rejected, "HTTP \(failure.httpStatus.map(String.init) ?? "?")，token 剩餘效期 \(remaining)：\(failure.detail)")
    }

    /// 續期走 `SingleFlight`：進行中時，後到的呼叫等同一個結果，不各自送一次請求。
    ///
    /// 實測（2026-09-01 20:16）啟動時兩次取樣同時觸發續期，伺服器讓先到的那次輪替，
    /// 後到的拿到 `invalid_grant`。那次只是取樣失敗，但**若伺服器對舊 token 有寬限期而
    /// 兩次都成功，就會有兩把新 token 各自寫回、其中一把是舊的 —— 下次續期永久失敗**。
    func renewCoalesced(refreshToken: String) async throws -> String {
        try await renewalFlight.run { try await self.performRenewal(refreshToken: refreshToken) }
    }

    /// 續期後**重新載入憑證再寫回**，而不是沿用呼叫端的快照 ——
    /// 網路往返期間別的欄位可能已經變了，用舊快照寫回會把它們蓋掉。
    func performRenewal(refreshToken: String) async throws -> String {
        let renewed: Renewal
        do {
            renewed = try await requestRenewal(refreshToken: refreshToken)
        } catch let raw as FetchFailure {
            let failure = Self.explained(raw)
            emit(.renewalFailed, "\(failure.kind.rawValue)：\(failure.detail)")
            if failure.kind == .rateLimited {
                renewalBlockedUntil = Date().addingTimeInterval(Self.renewalCooldown)
            } else if Self.shouldDiscard(after: failure) {
                // 續期鏈斷了 —— 多半是使用者重新登入、把 refresh token 換掉了。
                // 丟掉自己那份，下次取樣就會回頭從 Claude Code 的項目重新種子。
                discardPrivateCredentials()
            }
            throw failure
        }
        renewalBlockedUntil = nil

        let returned = renewed.refreshToken != nil
        let rotated = renewed.refreshToken.map { $0 != refreshToken } ?? false
        Self.log.notice(
            "renewal ok — response_has_refresh_token=\(returned, privacy: .public) rotated=\(rotated, privacy: .public)"
        )
        emit(.renewed, "rotated=\(rotated) expires_in=\(renewed.expiresIn.map { "\(Int($0))s" } ?? "?")")

        var credentials = try loadCredentials()
        guard var oauth = credentials["claudeAiOauth"] as? [String: Any] else {
            throw FetchFailure(kind: .auth, detail: "續期成功但憑證格式非預期：缺少 claudeAiOauth")
        }
        oauth["accessToken"] = renewed.accessToken
        oauth["refreshToken"] = renewed.refreshToken ?? refreshToken
        if let expiresIn = renewed.expiresIn {
            oauth["expiresAt"] = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
        }
        if let scope = renewed.scope {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        credentials["claudeAiOauth"] = oauth

        // 若 refresh token 有輪替，寫回失敗等於作廢舊的 —— 必須讓錯誤浮出來，不可吞掉。
        try persist(credentials)
        return renewed.accessToken
    }

    /// OAuth 規格（RFC 6749 §5.2）以 `invalid_client` 表示 client 認證失敗。
    /// **尚未實際觀測過 Anthropic 回這個值** —— 依規格比對字串而非狀態碼（規格允許 400 或 401）。
    static func explained(_ failure: FetchFailure) -> FetchFailure {
        guard failure.detail.contains("invalid_client") else { return failure }
        return FetchFailure(
            kind: .invalidClient, httpStatus: failure.httpStatus,
            detail: "續期被拒：client ID 無效（invalid_client）。官方可能已更換 —— "
                  + "可在選單「進階」填入新的 client ID，查法見 README。"
        )
    }

    /// 只有續期鏈本身失效才丟掉自己的憑證。
    ///
    /// **`invalid_client` 不丟** —— 那是 client ID 錯了，refresh token 本身可能還是好的。
    /// 丟掉等於親手弄斷一條還能用的鏈，而重新種子拿到的 Claude Code 那份多半早已作廢。
    static func shouldDiscard(after failure: FetchFailure) -> Bool {
        switch failure.kind {
        case .invalidClient: return false
        case .auth: return true
        default: return failure.detail.contains("invalid_grant")
        }
    }

    func needsRenewal(_ oauth: [String: Any]) -> Bool {
        guard renewalEnabled else { return false }
        guard let expiry = Self.expiryDate(oauth) else {
            return false  // 沒有到期資訊就不主動續期
        }
        return expiry.timeIntervalSinceNow < renewalMargin
    }

    /// token 已過期。續期關閉時用來給出可行動的訊息，而不是讓伺服器回一個沒頭沒尾的 401。
    func isExpired(_ oauth: [String: Any]) -> Bool {
        guard let expiry = Self.expiryDate(oauth) else { return false }
        return expiry < Date()
    }

    /// `expiresAt` 可能是毫秒或秒，用量級判斷。
    static func expiryDate(_ oauth: [String: Any]) -> Date? {
        guard let raw = oauth["expiresAt"] as? Double ?? (oauth["expiresAt"] as? Int).map(Double.init) else {
            return nil
        }
        return Date(timeIntervalSince1970: raw > 1e11 ? raw / 1000 : raw)
    }

    struct Renewal {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval?
        let scope: String?
    }

    func requestRenewal(refreshToken: String) async throws -> Renewal {
        let request = try Self.renewalRequest(refreshToken: refreshToken, clientID: clientID(), userAgent: userAgent)
        let body = try await HTTP.perform(request)
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else { throw FetchFailure(kind: .parse, detail: "續期回應缺少 access_token") }

        return Renewal(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresIn: (json["expires_in"] as? NSNumber)?.doubleValue,
            scope: json["scope"] as? String
        )
    }

    static func renewalRequest(refreshToken: String, clientID: String, userAgent: UserAgent) throws -> URLRequest {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent.value, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        return request
    }

    // MARK: - Keychain / 檔案

    func loadCredentials() throws -> [String: Any] {
        let data = try rawCredentials()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchFailure(kind: .auth, detail: "Claude 憑證不是 JSON 物件")
        }
        return json
    }

    /// 讀取順序：**本 app 自己的項目 → 檔案 → Claude Code 的項目**。
    /// 最後那個是種子來源，只在我們還沒有自己的憑證時才會用到。
    func rawCredentials() throws -> Data {
        if let mine = readKeychain(service: privateKeychainService) { return noting(.own, mine) }
        if let data = try? Data(contentsOf: fileURL) { return noting(.file, data) }
        guard let seed = readKeychain(service: keychainService) else {
            throw FetchFailure(
                kind: .auth,
                detail: "找不到 Claude 憑證。請確認已安裝 Claude Code 並執行 `claude auth login`。"
            )
        }
        return noting(.claudeCode, seed)
    }

    /// 只在來源**改變**時記錄 —— 每 5 分鐘讀一次，每次都記只會把真正的變化淹沒。
    private func noting(_ origin: Origin, _ data: Data) -> Data {
        if origin != lastOrigin {
            let previous = lastOrigin?.rawValue ?? "（啟動）"
            lastOrigin = origin
            emit(.sourceChanged, "\(previous) → \(origin.rawValue)")
        }
        return data
    }

    private func emit(_ kind: CredentialEvent.Kind, _ detail: String) {
        eventSink?(CredentialEvent(
            service: .claude, occurredAt: Date(), kind: kind, source: lastOrigin?.rawValue, detail: detail
        ))
    }

    func readKeychain(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// **只寫本 app 自己的項目。** 絕不寫 Claude Code 的 —— 那會重設它的分區清單。
    func persist(_ credentials: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: credentials)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: privateKeychainService
        ]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw FetchFailure(
                kind: .auth,
                detail: "續期成功但寫入本 app 的 Keychain 項目失敗（OSStatus \(status)）。"
            )
        }
    }

    /// 自癒：我們的續期鏈斷了（多半是使用者重新登入、把 refresh token 換掉了）。
    /// 刪掉自己的項目，下次取樣就會回頭從 Claude Code 的項目重新取得憑證。
    func discardPrivateCredentials() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: privateKeychainService
        ] as CFDictionary)
        Self.log.notice("憑證鏈失效，已清除本 app 的 Keychain 項目，下次取樣重新種子")
        emit(.discarded, "續期鏈失效，已清除本 app 的項目，下次取樣重新種子")
    }
}
