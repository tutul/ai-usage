import Testing
import Foundation
@testable import UsageCore

/// 數字取自 2026-09-09～14 的實測：208 筆網路逾時，對照 `pmset -g log` 幾乎全是
/// 睡眠中的短暫喚醒發起、請求被睡眠凍結。見 D-017。
@Suite("睡眠中斷的分類")
struct SleepClassificationTests {
    @Test("網路失敗且請求期間睡過 -> slept，原始訊息保留")
    func networkWhileAsleep() {
        let failure = FetchFailure(kind: .network, detail: "The request timed out.")
            .accountingForSleep(asleepSeconds: 3035)
        #expect(failure.kind == .slept)
        #expect(failure.detail.contains("The request timed out."))
    }

    /// 實測 09-11 03:06:01 那次：請求期間只睡了約 2 秒，仍是睡眠造成的逾時。
    @Test("只睡了 2 秒也算")
    func shortSleep() {
        let failure = FetchFailure(kind: .network, detail: "timed out").accountingForSleep(asleepSeconds: 2)
        #expect(failure.kind == .slept)
    }

    /// 完整清醒時的真斷網必須照樣是失敗 —— 實測 7 天內有 1 筆。
    @Test("沒睡 -> 維持 network")
    func awake() {
        let failure = FetchFailure(kind: .network, detail: "timed out").accountingForSleep(asleepSeconds: 0.05)
        #expect(failure.kind == .network)
    }

    @Test("睡醒後拿到 401 仍是 auth")
    func authUnchanged() {
        let failure = FetchFailure(kind: .auth, httpStatus: 401, detail: "expired")
            .accountingForSleep(asleepSeconds: 3000)
        #expect(failure.kind == .auth)
    }
}

/// 實測 2026-09-15～10-10：Claude 的 568 筆 network 失敗有 540 筆落在 13 段連續失敗中，
/// 使用者確認那幾段時間機器醒著但沒有網路。其中 5 段（460 筆）的訊息是
/// `The request timed out.`，8 段（80 筆）是 `The Internet connection appears to be offline.` ——
/// 兩種都是離線。見 D-022。
@Suite("離線的分類")
struct OfflineClassificationTests {
    @Test("網路失敗且連不到網際網路 -> offline，原始訊息保留")
    func networkWhileOffline() {
        for message in ["The request timed out.", "The Internet connection appears to be offline."] {
            let failure = FetchFailure(kind: .network, detail: message).accountingForConnectivity(online: false)
            #expect(failure.kind == .offline)
            #expect(failure.detail.contains(message))
        }
    }

    /// 網路是通的卻連不上服務 —— 這才是該去查服務狀態的失敗，不能被歸成離線。
    @Test("連得到網際網路 -> 維持 network")
    func networkWhileOnline() {
        let failure = FetchFailure(kind: .network, detail: "The request timed out.")
            .accountingForConnectivity(online: true)
        #expect(failure.kind == .network)
    }

    /// 拿得到 HTTP 回應就代表網路是通的，不管事後的連線檢查怎麼說。
    @Test("有 HTTP 回應的失敗不受影響")
    func httpFailuresUnchanged() {
        let auth = FetchFailure(kind: .auth, httpStatus: 401, detail: "expired")
            .accountingForConnectivity(online: false)
        #expect(auth.kind == .auth)
        let limited = FetchFailure(kind: .rateLimited, httpStatus: 429, detail: "slow down")
            .accountingForConnectivity(online: false)
        #expect(limited.kind == .rateLimited)
    }

    /// 睡著時網路本來就不通。那是睡眠造成的，記成離線會讓人以為網路有問題。
    @Test("先判睡眠：睡過的不會再被歸成離線")
    func sleepTakesPrecedence() {
        let failure = FetchFailure(kind: .network, detail: "The request timed out.")
            .accountingForSleep(asleepSeconds: 3035)
            .accountingForConnectivity(online: false)
        #expect(failure.kind == .slept)
    }
}

@Suite("Claude client ID 覆寫")
struct ClaudeClientIDTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "aiusage-test-\(UUID().uuidString)")!
    }

    @Test("沒設定 -> 預設值")
    func unset() {
        #expect(ClaudeClientID.resolve(defaults: freshDefaults()) == ClaudeClientID.defaultValue)
    }

    @Test("合法覆寫 -> 去空白、轉小寫後使用")
    func override() {
        let defaults = freshDefaults()
        defaults.set("  11111111-2222-4333-8444-55555555AAAA \n", forKey: ClaudeClientID.defaultsKey)
        #expect(ClaudeClientID.resolve(defaults: defaults) == "11111111-2222-4333-8444-55555555aaaa")
    }

    @Test("格式不對 -> 退回預設，不拿壞值去打端點")
    func invalid() {
        let defaults = freshDefaults()
        defaults.set("9d1c250a-e61b-44d9-88ed", forKey: ClaudeClientID.defaultsKey)
        #expect(ClaudeClientID.resolve(defaults: defaults) == ClaudeClientID.defaultValue)
    }
}
