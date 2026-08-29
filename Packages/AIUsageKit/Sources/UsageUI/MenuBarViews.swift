import SwiftUI
import UsageCore
import UsageStore

public struct MenuBarContent: View {
    @Bindable var model: UsageViewModel
    let onRefresh: () -> Void
    let onOpenHistory: () -> Void

    let launchAtLogin: LaunchAtLogin

    public init(
        model: UsageViewModel,
        launchAtLogin: LaunchAtLogin,
        onRefresh: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.onRefresh = onRefresh
        self.onOpenHistory = onOpenHistory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本週用量").font(.headline)

            ForEach(Service.allCases, id: \.self) { service in
                ServiceRow(service: service, model: model)
            }

            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Toggle("開機時自動啟動", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)
                .onAppear { launchAtLogin.refresh() }

                // app 沒在跑就完全沒資料 —— 這是比休眠更大的缺口來源
                if launchAtLogin.needsApproval {
                    Text("需在「系統設定 → 一般 → 登入項目」中允許")
                        .font(.caption2).foregroundStyle(.orange)
                } else if launchAtLogin.isEnabled && !launchAtLogin.isInApplicationsFolder {
                    Text("建議把 app 搬到 /Applications，否則建置目錄一清就失效")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
                }
            }

            Divider()
            HStack {
                Button("立即更新", action: onRefresh)
                Button("歷史圖表", action: onOpenHistory)
                Spacer()
                Button("結束") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 280)

    }
}

struct ServiceRow: View {
    let service: Service
    let model: UsageViewModel

    var body: some View {
        let reading = model.weekly(for: service)
        let stale = model.isStale(service)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(service.displayName).font(.subheadline.weight(.medium))
                Spacer()
                Text(reading.map { "\(Int($0.percent.rounded()))%" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(stale ? .secondary : .primary)
            }
            ProgressView(value: min((reading?.percent ?? 0) / 100, 1))
                .tint(stale ? .gray : tint(for: reading?.percent ?? 0))
            HStack {
                // 停擺時把「上次更新」擺在最顯眼處。良性（憑證過期）用次要色，
                // 只有真的壞掉才用警示色。
                Text(model.staleness(service))
                    .foregroundStyle(model.needsAttention(service) ? .orange : .secondary)
                Spacer()
                if let countdown = reading?.resetCountdown {
                    Text(countdown).foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if stale, let hint = model.failureHint(service) {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(model.needsAttention(service) ? .orange : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func tint(for percent: Double) -> Color {
        switch percent {
        case ..<70: return .accentColor
        case ..<90: return .orange
        default: return .red
        }
    }
}
