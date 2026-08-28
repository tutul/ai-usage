import SwiftUI
import UsageCore
import UsageStore

public struct MenuBarContent: View {
    @Bindable var model: UsageViewModel
    let onRefresh: () -> Void
    let onOpenHistory: () -> Void

    public init(
        model: UsageViewModel,
        onRefresh: @escaping () -> Void,
        onOpenHistory: @escaping () -> Void
    ) {
        self.model = model
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
