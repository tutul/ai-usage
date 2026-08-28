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

    init(database: UsageDatabase, providers: [any UsageProvider], model: UsageViewModel, interval: TimeInterval) {
        self.database = database
        self.providers = providers
        self.model = model
        self.interval = interval
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
    func sampleAll() async {
        for provider in providers {
            let startedAt = Date()
            let snapshot: UsageSnapshot
            do {
                snapshot = try await provider.fetch()
            } catch let failure as FetchFailure {
                try? database.record(failure: failure, service: provider.service,
                                     startedAt: startedAt, completedAt: Date())
                continue
            } catch {
                try? database.record(
                    failure: FetchFailure(kind: .network, detail: String(describing: error)),
                    service: provider.service, startedAt: startedAt, completedAt: Date()
                )
                continue
            }
            // 寫入失敗是另一回事，不可標成取樣失敗 —— 而且此時也寫不進 DB，
            // 只能浮到 UI 上，否則會變成看不見的資料遺失。
            do {
                try database.record(snapshot)
            } catch {
                model.loadError = "寫入資料庫失敗（\(provider.service.rawValue)）：\(error)"
            }
        }
        model.reload()
    }
}
