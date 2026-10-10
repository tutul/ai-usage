import Foundation
import AppKit
import UsageCore
import UsageProviders
import UsageStore
import UsageUI

/// 取樣排程。
///
/// 用 `NSBackgroundActivityScheduler` 而非 `Timer`：休眠期間不觸發、醒來也**不會**
/// 把錯過的次數補跑一輪 —— 正是所需行為（漏掉就漏掉，絕不回填過去的資料點）。
/// 代價是它有 tolerance，實際間隔會浮動，因此不保證每小時都有樣本。
@MainActor
final class Sampler {
    private let database: UsageDatabase
    private let providers: [any UsageProvider]
    private let model: UsageViewModel
    private let interval: TimeInterval
    private var scheduler: NSBackgroundActivityScheduler?
    private var wakeObserver: (any NSObjectProtocol)?
    let tracking: TrackingSettings
    /// 這台機器現在連得到網際網路嗎。只在抓取因網路失敗之後才問（見 D-022）。
    private let isOnline: @Sendable () async -> Bool

    init(
        database: UsageDatabase,
        providers: [any UsageProvider],
        model: UsageViewModel,
        tracking: TrackingSettings,
        interval: TimeInterval,
        isOnline: @escaping @Sendable () async -> Bool = { await ConnectivityProbe().isOnline() }
    ) {
        self.database = database
        self.providers = providers
        self.model = model
        self.tracking = tracking
        self.interval = interval
        self.isOnline = isOnline
    }

    func start() {
        let activity = NSBackgroundActivityScheduler(identifier: "com.tutu.aiusage.sampler")
        activity.repeats = true
        activity.interval = interval
        activity.tolerance = interval * 0.2
        activity.qualityOfService = .utility
        activity.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.sampleAll()
                // 必須呼叫，否則不會排下一次 —— 這個 API 最常見的踩雷點
                completion(.finished)
            }
        }
        scheduler = activity

        // 醒來立即補抓一次，讓 gap 一結束就有新讀數，不用乾等排程
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.sampleAll() }
        }

        Task { await sampleAll() }
    }

    func stop() {
        scheduler?.invalidate()
        scheduler = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    /// 一個 provider 失敗不影響另一個 —— Codex 掛掉不該讓 Claude 也停止記錄。
    ///
    /// 每次取樣都重新讀設定，所以使用者切換「追蹤的服務」立即生效，不必重啟。
    func sampleAll() async {
        // 這一輪有沒有人拿到過 HTTP 回應。有的話網路就是通的，後面的網路失敗不必再問。
        var reachedSomeone = false
        for provider in providers where tracking.isEnabled(provider.service) {
            let startedAt = Date()
            // 不計入睡眠的時鐘。與牆上時間的差距 = 請求期間睡了多久（見 D-017）
            let startedAwake = ProcessInfo.processInfo.systemUptime
            let snapshot: UsageSnapshot
            do {
                snapshot = try await provider.fetch()
            } catch {
                let completedAt = Date()
                let asleep = completedAt.timeIntervalSince(startedAt)
                    - (ProcessInfo.processInfo.systemUptime - startedAwake)
                var failure = ((error as? FetchFailure)
                    ?? FetchFailure(kind: .network, detail: String(describing: error)))
                    .accountingForSleep(asleepSeconds: asleep)
                if failure.httpStatus != nil { reachedSomeone = true }
                // 先判睡眠再判離線（順序見 `accountingForConnectivity`）。
                // completedAt 已經取好了 —— 多問的這一下不算進這次抓取的時間。
                if failure.kind == .network, !reachedSomeone {
                    failure = failure.accountingForConnectivity(online: await isOnline())
                }
                try? database.record(
                    failure: failure,
                    service: provider.service, startedAt: startedAt, completedAt: completedAt
                )
                continue
            }
            reachedSomeone = true
            // 寫入失敗是另一回事，不可標成取樣失敗 —— 而且此時也寫不進 DB，
            // 只能浮到 UI 上，否則會變成看不見的資料遺失。
            do {
                try database.record(snapshot)
            } catch {
                model.loadError = "寫入資料庫失敗（\(provider.service.rawValue)）：\(error)"
            }
        }
        // 等資料真的到畫面上才算完成 —— 「重新整理」按鈕的轉圈靠這個結束。
        await model.reload().value
    }
}
