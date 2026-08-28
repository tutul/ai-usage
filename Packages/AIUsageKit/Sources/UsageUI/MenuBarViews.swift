import SwiftUI
import UsageCore
import UsageStore

/// menu bar 上的文字。停擺時顯示 `—` 而非留著舊數字 ——
/// 抓不到必須看得出來，這是本專案最重要的 UI 要求。
public struct MenuBarLabel: View {
    let model: UsageViewModel
    public init(model: UsageViewModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 6) {
            ForEach(Service.allCases, id: \.self) { service in
                let stale = model.isStale(service)
                Text("\(service.shortName) \(stale ? "—" : percentText(service))")
                    .foregroundStyle(stale ? .secondary : .primary)
                    .monospacedDigit()
            }
        }
    }

    func percentText(_ service: Service) -> String {
        guard let reading = model.weekly(for: service) else { return "—" }
        return "\(Int(reading.percent.rounded()))%"
    }
}

public struct MenuBarContent: View {
    @Bindable var model: UsageViewModel
    let onRefresh: () -> Void
    let onOpenHistory: () -> Void
    let onSaveClaudeToken: (String) throws -> Void
    @State private var showingTokenSetup = false

    public init(
        model: UsageViewModel,
        onRefresh: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void,
        onSaveClaudeToken: @escaping (String) throws -> Void
    ) {
        self.model = model
        self.onRefresh = onRefresh
        self.onOpenHistory = onOpenHistory
        self.onSaveClaudeToken = onSaveClaudeToken
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
            HStack {
                Button("立即更新", action: onRefresh)
                Button("歷史圖表", action: onOpenHistory)
                Button("設定") { showingTokenSetup = true }
                Spacer()
                Button("結束") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.callout)
        }
        .padding(14)
        .frame(width: 280)
        .popover(isPresented: $showingTokenSetup) {
            TokenSetupView(onSave: onSaveClaudeToken)
        }
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
                // 停擺時把「上次更新」擺在最顯眼處，並改用警示色
                Text(model.staleness(service))
                    .foregroundStyle(stale ? .orange : .secondary)
                Spacer()
                if let countdown = reading?.resetCountdown {
                    Text(countdown).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
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
