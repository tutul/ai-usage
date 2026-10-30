import Testing
import Foundation
import UsageStore
@testable import UsageUI

/// 選單上的重置倒數。原本只精確到小時 —— 對週窗夠用，
/// 但 5 小時窗剩 40 分鐘時會顯示「0 小時後重置」。
@Suite("重置倒數")
struct CountdownTests {
    @Test("一天以上：天 + 小時")
    func days() {
        #expect(CurrentReading.countdown(seconds: 3 * 86_400 + 22 * 3600 + 1800) == "3 天 22 小時後重置")
    }

    /// 2026-10-29 實測 Codex 的 5 小時窗：88%，約 1 小時 32 分後重置。
    @Test("一天以內：小時 + 分")
    func hoursAndMinutes() {
        #expect(CurrentReading.countdown(seconds: 3600 + 32 * 60) == "1 小時 32 分後重置")
        #expect(CurrentReading.countdown(seconds: 4 * 3600) == "4 小時後重置")
    }

    @Test("不到一小時：只顯示分，不會出現「0 小時」")
    func underAnHour() {
        #expect(CurrentReading.countdown(seconds: 40 * 60) == "40 分後重置")
    }

    @Test("分鐘無條件進位：剩 30 秒說「1 分後」，59 分 30 秒說「1 小時後」")
    func roundsUp() {
        #expect(CurrentReading.countdown(seconds: 30) == "1 分後重置")
        #expect(CurrentReading.countdown(seconds: 59 * 60 + 30) == "1 小時後重置")
    }

    @Test("已過重置時間 -> 即將重置")
    func past() {
        #expect(CurrentReading.countdown(seconds: 0) == "即將重置")
        #expect(CurrentReading.countdown(seconds: -120) == "即將重置")
    }
}

/// 2026-10-30 實測：端點 `used_percent: 56`，Codex 官方顯示 `44% left`。
/// 只寫 `56%` 會被讀成剩餘，看起來像兩邊對不上。
@Suite("已用與剩餘")
struct UsedAndRemainingTests {
    @Test("兩個數字都寫出來，相加是 100")
    func bothShown() {
        #expect(CurrentReading.usedAndRemaining(percent: 56) == "已用 56% · 剩 44%")
    }

    @Test("用滿時剩 0，不會出現負數")
    func neverNegative() {
        #expect(CurrentReading.usedAndRemaining(percent: 100) == "已用 100% · 剩 0%")
        #expect(CurrentReading.usedAndRemaining(percent: 101) == "已用 101% · 剩 0%")
    }
}
