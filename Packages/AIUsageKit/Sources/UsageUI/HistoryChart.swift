import SwiftUI
import Charts
import UsageCore
import UsageStore

/// 歷史圖表 + 取樣日誌。
///
/// 四種視覺，意義完全不同，不可混淆：
/// - 藍色長條：該區間有用量
/// - 橘色長條：未知區間（消耗確實發生，但取樣中斷，無法歸屬）
/// - 灰色基線：有取樣，但用量無變化
/// - 完全空白：沒有取樣
public struct HistoryChartView: View {
    let model: UsageViewModel
    /// 重新取樣（而非只是重讀資料庫）—— 使用者按重新整理時想看的是「現在的用量」，
    /// 只重讀 DB 在沒有新樣本時什麼都不會變。
    let onRefresh: () async -> Void

    @State private var service: Service = .claude
    @State private var hoveredBucketStart: Date?
    @State private var isRefreshing = false
    @Environment(\.appearsActive) private var appearsActive

    public init(model: UsageViewModel, onRefresh: @escaping () async -> Void) {
        self.model = model
        self.onRefresh = onRefresh
    }

    private var granularity: Granularity { model.granularity }
    private var buckets: [UsageBucket] { model.buckets[service] ?? [] }
    private var bucketSeconds: TimeInterval { granularity == .hour ? 3600 : 86_400 }
    private var calendarUnit: Calendar.Component { granularity == .hour ? .hour : .day }
    private var chartUnit: Calendar.Component { granularity == .hour ? .hour : .day }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if buckets.isEmpty {
                ContentUnavailableView(
                    "尚無資料",
                    systemImage: "chart.bar",
                    description: Text("累積幾天後才會看得出模式。")
                )
                .frame(height: 240)
            } else {
                chart
            }

            Text("灰色基線 = 該區間有取樣但用量無變化；完全空白 = 沒有取樣。"
                 + "「未知區間」表示消耗確實發生，但因取樣中斷而無法歸屬，日與週的彙總仍會計入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            fetchLog
        }
        .padding(16)
        .onChange(of: appearsActive) { _, active in
            // 切回這個視窗時把資料庫最新狀態畫出來
            if active { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 620, minHeight: 560)
    }

    // MARK: - 標題列

    private var header: some View {
        HStack(spacing: 12) {
            Picker("服務", selection: $service) {
                ForEach(Service.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: service) { hoveredBucketStart = nil }

            Picker("粒度", selection: Binding(
                get: { model.granularity },
                set: { model.granularity = $0; hoveredBucketStart = nil; model.reload() }
            )) {
                ForEach(Granularity.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Spacer()

            Text(model.staleness(service))
                .font(.caption)
                .foregroundStyle(model.needsAttention(service) ? .orange : .secondary)

            Button {
                Task {
                    isRefreshing = true
                    await onRefresh()
                    isRefreshing = false
                }
            } label: {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(isRefreshing)
            .help("重新取樣並更新圖表")
        }
    }

    // MARK: - 圖表

    /// 依資料跨度決定 X 軸刻度密度，避免長條細又對不上時間。
    private var axisStride: (count: Int, unit: Calendar.Component) {
        guard let first = buckets.first?.start, let last = buckets.last?.start else {
            return (1, calendarUnit)
        }
        let span = last.timeIntervalSince(first)
        if granularity == .day {
            return (span / 86_400 < 15 ? 1 : (span / 86_400 < 60 ? 7 : 14), .day)
        }
        switch span / 3600 {
        case ..<13:  return (1, .hour)
        case ..<37:  return (3, .hour)
        case ..<97:  return (6, .hour)
        default:     return (12, .hour)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets, id: \.key) { bucket in
                if let used = bucket.usedPercent, used > 0 {
                    BarMark(x: .value("時間", bucket.start, unit: chartUnit),
                            y: .value("用量 %", used))
                        .foregroundStyle(by: .value("類別", "已歸屬"))
                }
                if let unknown = bucket.unknownPercent, unknown > 0 {
                    BarMark(x: .value("時間", bucket.start, unit: chartUnit),
                            y: .value("用量 %", unknown))
                        .foregroundStyle(by: .value("類別", "未知區間"))
                }
                // 有取樣但用量沒變 -> 零基線標記。
                // 否則「有抓但沒變」與「完全沒抓」在圖上都是空白。
                if (bucket.usedPercent ?? 0) == 0 && (bucket.unknownPercent ?? 0) == 0 {
                    RectangleMark(x: .value("時間", bucket.start, unit: chartUnit),
                                  y: .value("用量 %", 0),
                                  height: .fixed(3))
                        .foregroundStyle(by: .value("類別", "已取樣・無變化"))
                }
            }
        }
        .chartForegroundStyleScale([
            "已歸屬": Color.accentColor,
            "未知區間": Color.orange,
            "已取樣・無變化": Color.secondary
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: axisStride.unit, count: axisStride.count)) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        let isDayStart = granularity == .day
                            || Calendar.current.component(.hour, from: date) == 0
                        Text(date, format: isDayStart
                             ? .dateTime.month(.defaultDigits).day()
                             : .dateTime.hour())
                            .font(.caption2)
                            .fontWeight(isDayStart ? .semibold : .regular)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text("\(Int(v))%").font(.caption2) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    ZStack(alignment: .topLeading) {
                        if let start = hoveredBucketStart,
                           let x0 = proxy.position(forX: start),
                           let x1 = proxy.position(forX: start.addingTimeInterval(bucketSeconds)) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.18))
                                .frame(width: max(x1 - x0, 4), height: rect.height)
                                .position(x: rect.minX + (x0 + x1) / 2, y: rect.midY)
                                .allowsHitTesting(false)
                        }

                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard rect.contains(location),
                                          let date = proxy.value(atX: location.x - rect.minX, as: Date.self)
                                    else { hoveredBucketStart = nil; return }
                                    // 取游標所在的整格 —— 不用「最近的長條」，
                                    // 那會讓游標停在空白處時跳到遠處的長條
                                    hoveredBucketStart = Calendar.current
                                        .dateInterval(of: calendarUnit, for: date)?.start
                                case .ended:
                                    hoveredBucketStart = nil
                                }
                            }

                        if let start = hoveredBucketStart, let x0 = proxy.position(forX: start) {
                            let x = rect.minX + x0
                            tooltip(start, bucket: bucket(at: start))
                                .frame(width: tooltipWidth)
                                .position(
                                    x: min(max(x, rect.minX + tooltipWidth / 2),
                                           rect.maxX - tooltipWidth / 2),
                                    y: rect.minY + 48
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(height: 240)
    }

    private var tooltipWidth: CGFloat { 190 }

    /// 該格是否有樣本。沒有就是沒有 —— 不去找「最近的」湊數。
    private func bucket(at start: Date) -> UsageBucket? {
        buckets.first { abs($0.start.timeIntervalSince(start)) < 60 }
    }

    @ViewBuilder
    private func tooltip(_ start: Date, bucket: UsageBucket?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(start, format: granularity == .hour
                 ? .dateTime.month().day().hour()
                 : .dateTime.year().month().day())
                .font(.caption.weight(.semibold))
            if let bucket {
                if let used = bucket.usedPercent, used > 0 {
                    row("已歸屬", value: used, color: .accentColor)
                }
                if let unknown = bucket.unknownPercent, unknown > 0 {
                    row("未知區間", value: unknown, color: .orange)
                    Text("取樣中斷，無法歸屬到特定\(granularity.displayName)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if (bucket.usedPercent ?? 0) == 0 && (bucket.unknownPercent ?? 0) == 0 {
                    Text("有取樣，用量無變化").font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(bucket.pairCount) 筆取樣")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                // 無資料 ≠ 0，必須講清楚是哪一種
                Text("此\(granularity.displayName)無取樣")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2)
    }

    private func row(_ label: String, value: Double, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2)
            Spacer(minLength: 8)
            Text(String(format: "%.2f%%", value))
                .font(.caption.monospacedDigit().weight(.medium))
        }
    }

    // MARK: - 取樣日誌

    private var fetchLog: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("最近取樣").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.recentFetches.isEmpty {
                Text("尚無紀錄").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ForEach(model.recentFetches) { fetch in
                    logRow(fetch)
                }
            }
        }
    }

    @ViewBuilder
    private func logRow(_ fetch: RecentFetch) -> some View {
        HStack(spacing: 8) {
            Text(fetch.completedAt, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Text(fetch.service.displayName)
                .font(.caption2)
                .frame(width: 48, alignment: .leading)

            Image(systemName: fetch.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(fetch.ok ? .green : .orange)

            if fetch.ok {
                Text(fetch.weeklyPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
                // 成功但缺週窗 —— 端點回 200 不代表拿到週用量
                if fetch.errorKind == "missing_window" {
                    Text("缺週窗").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(fetch.errorKind ?? "失敗")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .frame(width: 90, alignment: .leading)
                Text(fetch.errorDetail ?? "")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
    }
}
