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

    /// 由 app 自己寫入 Keychain —— 成為該項目的擁有者，避免每次讀取都跳授權對話框。
    func saveClaudeToken(_ token: String) throws {
        try ClaudeCredentialSource().store(token: token)
        refreshNow()
    }
}

@main
struct AIUsageApp: App {
    @State private var state = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            if let model = state.model {
                MenuBarContent(
                    model: model,
                    onRefresh: { state.refreshNow() },
                    onOpenHistory: { openWindow(id: "history") },
                    onSaveClaudeToken: { try state.saveClaudeToken($0) }
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
                HistoryChartView(model: model)
                    .task { model.reload() }
            } else {
                Text(state.startupError ?? "尚未就緒").padding()
            }
        }
        .defaultSize(width: 640, height: 460)
    }
}
