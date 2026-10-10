import Testing
import Foundation
import Network
@testable import UsageProviders

@Suite("網路路徑")
struct NetworkPathTests {
    @Test("沒有任何可用路徑才算沒有網路")
    func onlyUnsatisfiedIsOffline() {
        #expect(NetworkPathWatcher.isUsable(.satisfied))
        #expect(!NetworkPathWatcher.isUsable(.unsatisfied))
    }

    /// 隨選 VPN 尚未撥上時是 `.requiresConnection`：一連線就會有路。
    /// 這時抓取失敗說不準是誰的問題，不能歸成離線把它藏起來。
    @Test("需要先建立連線 -> 不算離線")
    func requiresConnectionIsNotOffline() {
        #expect(NetworkPathWatcher.isUsable(.requiresConnection))
    }

    /// 系統還沒回報之前就被問到（app 剛啟動）：當作有網路。
    /// 寧可把離線記成失敗，不可把失敗記成離線。
    @Test("還沒收到第一次回報 -> 當作有網路")
    func defaultsToOnline() {
        #expect(NetworkPathWatcher().hasRoute)
    }
}
