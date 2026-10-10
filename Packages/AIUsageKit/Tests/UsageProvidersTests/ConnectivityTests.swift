import Testing
import Foundation
@testable import UsageProviders

@Suite("連線檢查")
struct ConnectivityProbeTests {
    /// 2026-10-10 實測 `https://captive.apple.com/hotspot-detect.html` 的回應。
    @Test("Apple 的連線檢查頁 -> 有網路")
    func appleSuccessPage() {
        let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>\n"
        #expect(ConnectivityProbe.isSuccess(status: 200, body: body))
    }

    /// 需要登入的 Wi-Fi 會攔下請求、回自己的登入頁 —— 狀態碼一樣是 200。
    /// 只看狀態碼會把「連著 Wi-Fi 但還沒登入」當成有網路。
    @Test("200 但內容不是檢查頁 -> 沒有網路")
    func captivePortalPage() {
        let body = "<html><head><title>Wi-Fi Login</title></head><body>Please sign in</body></html>"
        #expect(!ConnectivityProbe.isSuccess(status: 200, body: body))
    }

    @Test("非 200 -> 沒有網路")
    func nonSuccessStatus() {
        let body = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
        #expect(!ConnectivityProbe.isSuccess(status: 302, body: body))
        #expect(!ConnectivityProbe.isSuccess(status: 503, body: ""))
    }

    /// 連不上不可以丟錯或卡住 —— 這個檢查本身就是在網路有問題時才跑的。
    @Test("連不上 -> false，不丟錯")
    func unreachableIsOffline() async {
        let probe = ConnectivityProbe(endpoint: URL(string: "https://127.0.0.1:1/")!)
        #expect(await probe.isOnline() == false)
    }
}
