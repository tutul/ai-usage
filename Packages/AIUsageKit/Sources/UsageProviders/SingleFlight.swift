import Foundation

/// 併發合流：同一時間只讓一個工作真的執行，其餘呼叫等同一個結果。
///
/// `actor` 只保證不同時執行，**不保證跨 `await` 的原子性**。一個會 `await` 的
/// 方法在等待期間會讓出 actor，後到的呼叫就進得來、看到尚未更新的狀態、
/// 再做一次同樣的事。對「用一次就失效」的資源（例如會輪替的 refresh token）
/// 這是會造成永久損壞的競態，不只是浪費。
///
/// 關鍵在 `run` 裡的檢查與指派之間**沒有 `await`** —— 那段是同步的，
/// actor 保證不被插隊，所以後到的呼叫必然看得到進行中的工作。
actor SingleFlight<Value: Sendable> {
    private var inFlight: Task<Value, Error>?

    func run(_ work: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight { return try await existing.value }
        let task = Task { try await work() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}
