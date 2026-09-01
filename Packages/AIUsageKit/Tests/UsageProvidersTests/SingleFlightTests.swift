import Testing
import Foundation
@testable import UsageProviders

/// 計數用。actor 保證計數本身不會漏算。
actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Suite("併發合流")
struct SingleFlightTests {
    /// 回歸測試：2026-09-01 20:16 啟動時兩次取樣同時觸發 Claude 續期，
    /// 伺服器讓先到的那次輪替 refresh token，後到的拿到 invalid_grant。
    /// 若伺服器對舊 token 有寬限期而兩次都成功，兩把新 token 會各自寫回，
    /// 其中一把是舊的 —— 下次續期就永久失敗，需要重新登入。
    @Test("多個併發呼叫只實際執行一次，且都拿到同一個結果")
    func coalesces() async throws {
        let flight = SingleFlight<String>()
        let counter = CallCounter()

        let results = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    try await flight.run {
                        await counter.bump()
                        try await Task.sleep(for: .milliseconds(50))  // 模擬網路往返時的讓出
                        return "renewed"
                    }
                }
            }
            var all: [String] = []
            for try await r in group { all.append(r) }
            return all
        }

        #expect(await counter.count == 1, "8 個併發呼叫只該真的執行一次")
        #expect(results.count == 8)
        #expect(results.allSatisfy { $0 == "renewed" })
    }

    @Test("前一次結束後，下一次會重新執行")
    func doesNotCacheAcrossCalls() async throws {
        let flight = SingleFlight<Int>()
        let counter = CallCounter()
        for _ in 0..<3 {
            _ = try await flight.run { await counter.bump(); return 1 }
        }
        #expect(await counter.count == 3, "合流只在進行中生效，不是快取")
    }

    @Test("失敗會傳給所有等待者，且不留下卡住的狀態")
    func failurePropagates() async throws {
        struct Boom: Error {}
        let flight = SingleFlight<Int>()
        await #expect(throws: Boom.self) { try await flight.run { throw Boom() } }
        let after = try await flight.run { 42 }
        #expect(after == 42, "失敗後仍能再次執行")
    }
}
