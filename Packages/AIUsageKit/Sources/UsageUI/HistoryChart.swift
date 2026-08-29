import SwiftUI
import Charts
import UsageCore
import UsageStore

/// 歷史圖表。
///
/// 兩個不可妥協的呈現規則：
/// 1. 沒有樣本的小時**不產生任何長條** —— 無資料 ≠ 0，不可補 0
/// 2. `unknown_percent`（知道發生了、不知落在哪一格）必須與 `used_percent`
///    視覺上可區分，不可混為同一種量
public struct HistoryChartView: View {
    let model: UsageViewModel
    /// 重新取樣（而非只是重讀資料庫）—— 使用者按重新整理時想看的是「現在的用量」，
    /// 只重讀 DB 在沒有新樣本時什麼都不會變。
    let onRefresh: () async -> Void

    @State private var service: Service = .claude
    @State private var hoveredHour: Date?
    @State private var isRefreshing = false
    @Environment(\.appearsActive) private var appearsActive

    public init(model: UsageViewModel, onRefresh: @escaping () async -> Void) {
        self.model = model
        self.onRefresh = onRefresh
    }

    var buckets: [HourlyBucket] { model.hourly[service] ?? [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if buckets.isEmpty {
                ContentUnavailableView(
                    "尚無資料",
                    systemImage: "chart.bar",
                    description: Text("累積幾天後才會看得出模式。")
                )
                .frame(height: 260)
            } else {
                chart
            }

            Text("灰色基線 = 該小時有取樣但用量無變化；完全空白 = 該小時沒有取樣。"
                 + "「未知區間」表示消耗確實發生，但因取樣中斷而無法歸屬到特定小時，"
                 + "日與週的彙總仍會計入。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .onChange(of: appearsActive) { _, active in
            // 切回這個視窗時把資料庫最新狀態畫出來 —— 背景取樣期間視窗可能一直開著
            if active { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 560, minHeight: 400)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("服務", selection: $service) {
                ForEach(Service.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: service) { hoveredHour = nil }

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

    /// 依資料跨度決定 X 軸刻度密度。原本固定 6 小時一格，長條細又對不上時間。
    private var axisStrideHours: Int {
        guard let first = buckets.first?.hourStart, let last = buckets.last?.hourStart else { return 6 }
        let hours = last.timeIntervalSince(first) / 3600
        switch hours {
        case ..<13:  return 1
        case ..<37:  return 3
        case ..<97:  return 6
        default:     return 12
        }
    }

    private var chart: some View {
        Chart {
            ForEach(buckets, id: \.hourLocal) { bucket in
                if let used = bucket.usedPercent, used > 0 {
                    BarMark(
                        x: .value("時間", bucket.hourStart, unit: .hour),
                        y: .value("用量 %", used)
                    )
                    .foregroundStyle(by: .value("類別", "已歸屬"))
                }
                if let unknown = bucket.unknownPercent, unknown > 0 {
                    BarMark(
                        x: .value("時間", bucket.hourStart, unit: .hour),
                        y: .value("用量 %", unknown)
                    )
                    .foregroundStyle(by: .value("類別", "未知區間"))
                }
                // 有取樣但用量沒變 -> 畫一條零基線標記。
                // 否則「有抓但沒變」與「完全沒抓」在圖上都是空白，
                // 使用者得逐格 hover 才分得出來 —— 那正是本專案最該避免的混淆。
                if (bucket.usedPercent ?? 0) == 0 && (bucket.unknownPercent ?? 0) == 0 {
                    RectangleMark(
                        x: .value("時間", bucket.hourStart, unit: .hour),
                        y: .value("用量 %", 0),
                        height: .fixed(3)
                    )
                    .foregroundStyle(by: .value("類別", "已取樣・無變化"))
                }
            }
        }
        // 不再加 opacity —— 先前 0.45 讓橘色在深色背景上變成褐色，與圖例對不起來
        .chartForegroundStyleScale([
            "已歸屬": Color.accentColor,
            "未知區間": Color.orange,
            "已取樣・無變化": Color.secondary
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: axisStrideHours)) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        // 午夜額外標日期，否則跨日時分不清哪一天
                        let isMidnight = Calendar.current.component(.hour, from: date) == 0
                        Text(date, format: isMidnight
                             ? .dateTime.month(.defaultDigits).day()
                             : .dateTime.hour())
                            .font(.caption2)
                            .fontWeight(isMidnight ? .semibold : .regular)
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
                        // 先畫高亮帶，讓「現在選到哪一小時」一眼可見
                        if let hour = hoveredHour,
                           let x0 = proxy.position(forX: hour),
                           let x1 = proxy.position(forX: hour.addingTimeInterval(3600)) {
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
                                    else { hoveredHour = nil; return }
                                    // 直接取游標所在的整點 —— 不用「最近的長條」，
                                    // 那會讓游標停在空白處時跳到遠處的長條，行為無法預期
                                    hoveredHour = Calendar.current.dateInterval(of: .hour, for: date)?.start
                                case .ended:
                                    hoveredHour = nil
                                }
                            }

                        if let hour = hoveredHour, let x0 = proxy.position(forX: hour) {
                            let x = rect.minX + x0
                            tooltip(hour, bucket: bucket(for: hour))
                                .frame(width: tooltipWidth)
                                .position(
                                    x: min(max(x, rect.minX + tooltipWidth / 2), rect.maxX - tooltipWidth / 2),
                                    y: rect.minY + 48
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(height: 260)
    }

    private var tooltipWidth: CGFloat { 190 }

    /// 該整點是否有樣本。沒有就是沒有 —— 不去找「最近的」湊數。
    private func bucket(for hour: Date) -> HourlyBucket? {
        buckets.first { abs($0.hourStart.timeIntervalSince(hour)) < 60 }
    }

    @ViewBuilder
    private func tooltip(_ hour: Date, bucket: HourlyBucket?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(hour, format: .dateTime.month().day().hour())
                .font(.caption.weight(.semibold))
            if let bucket {
                if let used = bucket.usedPercent, used > 0 {
                    row("已歸屬", value: used, color: .accentColor)
                }
                if let unknown = bucket.unknownPercent, unknown > 0 {
                    row("未知區間", value: unknown, color: .orange)
                    Text("取樣中斷，無法歸屬到特定小時")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if (bucket.usedPercent ?? 0) == 0 && (bucket.unknownPercent ?? 0) == 0 {
                    Text("有取樣，用量無變化").font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(bucket.pairCount) 筆取樣")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                // 無資料 ≠ 0，必須講清楚是哪一種
                Text("此小時無取樣").font(.caption2).foregroundStyle(.secondary)
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
}
