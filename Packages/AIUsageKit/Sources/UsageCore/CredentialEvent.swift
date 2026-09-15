import Foundation

/// 憑證生命週期中的一件事。**絕不含 token 本身。**
///
/// 憑證是這個 app 最脆弱的地方，而系統日誌保存期很短 ——
/// 2026-09-13 22:28 起連續三次 auth 失敗、15 分鐘後自行恢復，事後已經查不到原因。
/// 所以寫進資料庫，和取樣紀錄放在一起（見 D-017）。
public struct CredentialEvent: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// 讀取來源改變（含啟動後第一次讀到）。種子、自癒、使用者重新登入都會表現成來源變化。
        case sourceChanged = "source_changed"
        case renewed
        case renewalFailed = "renewal_failed"
        /// 自癒：丟掉本 app 自己的憑證，下次取樣重新種子。
        case discarded
        /// 用量端點拒絕了 token。附上當時的來源與剩餘效期 ——
        /// 「還沒到期就被拒」和「過期了」是完全不同的問題。
        case rejected
    }

    public let service: Service
    public let occurredAt: Date
    public let kind: Kind
    /// `own` / `file` / `claude_code`
    public let source: String?
    public let detail: String

    public init(service: Service, occurredAt: Date, kind: Kind, source: String?, detail: String) {
        self.service = service
        self.occurredAt = occurredAt
        self.kind = kind
        self.source = source
        self.detail = detail
    }
}

/// 同步呼叫，由實作自行決定寫到哪裡。憑證來源不依賴資料庫模組。
public typealias CredentialEventSink = @Sendable (CredentialEvent) -> Void
