import SwiftUI
import UsageCore
import UsageProviders
import UsageStore
import UsageUI

/// 應用層狀態。資料庫與排程器在此建立，失敗時把原因留在 `startupError`，
/// 讓選單顯示得出來 —— 靜默死掉正是這個 app 最該避免的失敗模式。
@MainActor
@Observable
final class AppState {
    private(set) var model: UsageViewModel?
    private(set) var sampler: Sampler?
    private(set) var startupError: String?

    static let samplingInterval: TimeInterval = 300

    init() {
        do {
            let database = try UsageDatabase(url: try UsageDatabase.defaultURL())
            let model = UsageViewModel(database: database)
            model.samplingInterval = Self.samplingInterval
            model.reload()

            let sampler = Sampler(
                database: database,
                providers: [ClaudeProvider(), CodexProvider()],
                model: model,
                interval: Self.samplingInterval
            )
            sampler.start()

            self.model = model
            self.sampler = sampler
        } catch {
            self.startupError = "無法開啟資料庫：\(error)"
        }
    }

    func refreshNow() {
        Task { await sampler?.sampleAll() }
    }

    /// 供 UI await 的版本，讓按鈕能正確顯示進行中狀態。
    func refresh() async {
        await sampler?.sampleAll()
    }
}

@main
struct AIUsageApp: App {
    @State private var state = AppState()
    @State private var launchAtLogin = LaunchAtLogin()
    @Environment(\.openWindow) private var openWindow

    /// LSUIElement app 的 activation policy 是 .accessory，
    /// 開視窗**不會**讓 app 變成前景 —— 視窗會開在其他 app 後面，使用者得自己去找。
    /// 因此必須明確要求 activation，並把視窗 order front。
    /// 視窗可能在這一輪 runloop 尚未建立，故延到下一輪再抓一次。
    @MainActor
    private func showHistory() {
        openWindow(id: "history")
        NSApp.activate()
        DispatchQueue.main.async {
            NSApp.activate()
            historyWindow()?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor
    private func historyWindow() -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue.contains("history") == true || window.title == "用量歷史"
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if let model = state.model {
                MenuBarContent(
                    model: model,
                    launchAtLogin: launchAtLogin,
                    onRefresh: { state.refreshNow() },
                    onOpenHistory: { showHistory() }
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.startupError ?? "啟動中…")
                        .font(.callout)
                        .foregroundStyle(.red)
                    Button("結束") { NSApplication.shared.terminate(nil) }
                }
                .padding(14)
                .frame(width: 280)
            }
        } label: {
            if let model = state.model {
                MenuBarLabel(model: model)
            } else {
                Text("AI —")
            }
        }
        .menuBarExtraStyle(.window)

        Window("用量歷史", id: "history") {
            if let model = state.model {
                HistoryChartView(model: model, onRefresh: { await state.refresh() })
                    .task { model.reload() }
            } else {
                Text(state.startupError ?? "尚未就緒").padding()
            }
        }
        .defaultSize(width: 700, height: 640)
    }
}
