import SwiftUI
import UsageCore
import UsageStore

public struct MenuBarContent: View {
    @Bindable var model: UsageViewModel
    let onRefresh: () -> Void
    let onOpenHistory: () -> Void

    let launchAtLogin: LaunchAtLogin
    let tracking: TrackingSettings
    let clientID: ClaudeClientIDSettings

    @State private var showAdvanced = false
    @State private var clientIDDraft = ""
    @State private var clientIDInvalid = false

    public init(
        model: UsageViewModel,
        launchAtLogin: LaunchAtLogin,
        tracking: TrackingSettings,
        clientID: ClaudeClientIDSettings,
        onRefresh: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.tracking = tracking
        self.clientID = clientID
        self.onRefresh = onRefresh
        self.onOpenHistory = onOpenHistory
    }

    private func applyClientID() {
        clientIDInvalid = !clientID.apply(clientIDDraft)
        if !clientIDInvalid { clientIDDraft = clientID.override ?? "" }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本週用量").font(.headline)

            if tracking.enabledServices.isEmpty {
                Text("尚未啟用任何服務。在下方勾選要追蹤的項目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tracking.enabledServices, id: \.self) { service in
                    ServiceRow(service: service, model: model)
                }
            }

            if let error = model.loadError {
                Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
            }

            Divider()

            VStack(alignment: .leading, spacing: 3) {
                Text("追蹤的服務").font(.caption).foregroundStyle(.secondary)
                ForEach(Service.allCases, id: \.self) { service in
                    Toggle(service.displayName, isOn: Binding(
                        get: { tracking.isEnabled(service) },
                        set: { tracking.setEnabled(service, $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.callout)
                }
                Text("關掉只是不再抓取，已記錄的歷史不會刪除。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

            // 平常用不到，收起來。只有官方更換 client ID、續期持續失敗時才需要打開。
            DisclosureGroup("進階", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Claude OAuth client ID").foregroundStyle(.secondary)
                        Spacer()
                        Text(clientID.override == nil ? "使用預設" : "使用自訂")
                            .foregroundStyle(clientID.override == nil ? Color.secondary : Color.orange)
                    }
                    .font(.caption)

                    TextField(ClaudeClientID.defaultValue, text: $clientIDDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption2.monospaced())
                        .onSubmit(applyClientID)

                    HStack {
                        Button("套用", action: applyClientID)
                        Button("還原預設") {
                            clientID.reset()
                            clientIDDraft = ""
                            clientIDInvalid = false
                        }
                        .disabled(clientID.override == nil)
                    }
                    .controlSize(.small)

                    if clientIDInvalid {
                        Text("格式不對，應為 UUID（8-4-4-4-12），未套用。")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    Text("只有續期持續失敗、且確認官方更換了 client ID 時才需要改。查法見 README。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
            .font(.callout)
            .onAppear { clientIDDraft = clientID.override ?? "" }

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
