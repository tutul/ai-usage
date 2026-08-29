import Testing
import Foundation
@testable import UsageProviders

@Suite("Claude 憑證續期判定")
struct RenewalTests {
    let source = ClaudeCredentialSource()

    func oauth(expiresAt: Any?) -> [String: Any] {
        expiresAt.map { ["expiresAt": $0] } ?? [:]
    }

    @Test("已過期 -> 需要續期")
    func expired() async {
        let past = Int(Date().addingTimeInterval(-3600).timeIntervalSince1970 * 1000)
        #expect(await source.needsRenewal(oauth(expiresAt: past)))
    }

    @Test("還有 30 分鐘 -> 不需續期")
    func stillValid() async {
        let future = Int(Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000)
        #expect(await source.needsRenewal(oauth(expiresAt: future)) == false)
    }

    /// 提前緩衝：避免剛好在請求途中過期。
    @Test("落在 5 分鐘緩衝內 -> 需要續期")
    func withinMargin() async {
        let soon = Int(Date().addingTimeInterval(120).timeIntervalSince1970 * 1000)
        #expect(await source.needsRenewal(oauth(expiresAt: soon)))
    }

    /// expiresAt 可能是毫秒或秒，用量級判斷。搞錯會讓「秒」被當成 1970 年而永遠續期，
    /// 或讓「毫秒」被當成西元 58000 年而永不續期。
    @Test("秒與毫秒兩種單位都判定正確")
    func handlesBothEpochUnits() async {
        let futureSeconds = Int(Date().addingTimeInterval(1800).timeIntervalSince1970)
        #expect(await source.needsRenewal(oauth(expiresAt: futureSeconds)) == false)
        let pastSeconds = Int(Date().addingTimeInterval(-1800).timeIntervalSince1970)
        #expect(await source.needsRenewal(oauth(expiresAt: pastSeconds)))
    }

    @Test("沒有 expiresAt -> 不主動續期")
    func missingExpiry() async {
        #expect(await source.needsRenewal(oauth(expiresAt: nil)) == false)
    }
}
