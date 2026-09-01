import SwiftUI
import Charts
import UsageCore
import UsageStore

/// 歷史圖表 + 取樣日誌。
///
/// 四種視覺，意義完全不同，不可混淆：
/// - 折線上的大點：該區間有用量
/// - 折線上貼著 0 的小點：有取樣，但用量無變化
/// - 線斷開／完全空白：沒有取樣。**不補值、不連過去**
/// - 橘色長條：未知區間（消耗確實發生，但取樣中斷，無法歸屬到某一格）
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

            Text("線只連接相鄰且都有取樣的區間，**斷開處代表沒有取樣**，不補值。貼著 0 的小點 = 有取樣但用量沒變。「未知區間」表示消耗確實發生，但因取樣中斷而無法歸屬到某一格，日與週的彙總仍會計入。")
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

    /// 只有「相鄰且都有取樣」的區間才連線；一有中斷就分段。
    ///
    /// 折線天生會在兩點之間畫出中間值，而這個專案不憑空補值 —— 所以斷線是刻意的，
    /// 它就是「這段沒有取樣」的視覺表示。點才是真正的觀測，線只是趨勢。
    private var segments: [[UsageBucket]] {
        var result: [[UsageBucket]] = []
        var current: [UsageBucket] = []
        for bucket in buckets {
            if let prev = current.last,
               Calendar.current.date(byAdding: calendarUnit, value: 1, to: prev.start) != bucket.start {
                result.append(current)
                current = []
            }
            current.append(bucket)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 資料範圍內的每個午夜，用來畫換日分隔與日期標籤。
    private var dayStarts: [Date] {
        guard granularity == .hour,
              let first = buckets.first?.start, let last = buckets.last?.start else { return [] }
        let calendar = Calendar.current
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: first)
        while cursor <= last {
            if cursor >= first { days.append(cursor) }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private var chart: some View {
        Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.key) { bucket in
                    LineMark(
                        x: .value("時間", bucket.start),
                        y: .value("用量 %", bucket.usedPercent ?? 0),
                        series: .value("段", index)
                    )
                    .foregroundStyle(by: .value("類別", "已歸屬"))
                    .interpolationMethod(.linear)

                    // 每個區間都畫點：單獨一段（前後都沒取樣）時線畫不出來，只剩點。
                    // 沒有用量的點畫小一些，讓「有取樣但沒用」與真正的消耗仍分得出來。
                    PointMark(
                        x: .value("時間", bucket.start),
                        y: .value("用量 %", bucket.usedPercent ?? 0)
                    )
                    .foregroundStyle(by: .value("類別", "已歸屬"))
                    .symbolSize((bucket.usedPercent ?? 0) > 0 ? 26 : 8)
                }
            }

            // 未知區間不是「某小時的用量」，不能進折線 —— 它的意思是
            // 「這段消耗確實發生，但不知道落在哪一格」。維持長條，視覺上明顯不同。
            ForEach(buckets.filter { ($0.unknownPercent ?? 0) > 0 }, id: \.key) { bucket in
                BarMark(
                    x: .value("時間", bucket.start, unit: chartUnit),
                    y: .value("用量 %", bucket.unknownPercent ?? 0)
                )
                .foregroundStyle(by: .value("類別", "未知區間"))
                .opacity(0.85)
            }
        }
        .chartForegroundStyleScale([
            "已歸屬": Color.accentColor,
            "未知區間": Color.orange
        ])
        .chartLegend(position: .top, alignment: .leading)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    // 交替底色分日 —— 光靠時刻標籤看不出哪裡換天。
                    ForEach(Array(dayStarts.enumerated()), id: \.element) { index, day in
                        if index.isMultiple(of: 2),
                           let x0 = proxy.position(forX: day),
                           let x1 = proxy.position(
                             forX: Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
                           ) {
                            let lo = max(x0, 0)
                            let hi = min(x1, rect.width)
                            if hi > lo {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.13))
                                    .frame(width: hi - lo, height: rect.height)
                                    .position(x: rect.minX + (lo + hi) / 2, y: rect.midY)
                            }
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: axisStride.unit, count: axisStride.count)) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: granularity == .day
                             ? .dateTime.month(.defaultDigits).day()
                             : .dateTime.hour())
                            .font(.caption2)
                    }
                }
            }
            // 第二層：換日的分隔線與日期。日粒度的標籤本來就是日期，不需要。
            AxisMarks(values: dayStarts) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.9))
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.month(.defaultDigits).day())
                            .font(.caption2.weight(.semibold))
                            .fixedSize()          // 不加會被壓成「8/…」
                            .offset(y: 13)
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

    private struct FetchDay: Identifiable {
        let day: Date
        let items: [RecentFetch]
        var id: Date { day }
    }

    /// 依當地日期分組。一次載 50 筆時，沒有日期分隔會完全看不出跨到哪一天。
    private var groupedFetches: [FetchDay] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [RecentFetch]] = [:]
        for fetch in model.recentFetches {
            let day = calendar.startOfDay(for: fetch.completedAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(fetch)
        }
        return order.map { FetchDay(day: $0, items: byDay[$0] ?? []) }
    }

    private var fetchLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("取樣紀錄").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("已載入 \(model.recentFetches.count) 筆")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if model.recentFetches.isEmpty {
                Text("尚無紀錄").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groupedFetches) { group in
                            Section {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, fetch in
                                    logRow(fetch)
                                        .padding(.vertical, 2)
                                        .padding(.horizontal, 6)
                                        .background(
                                            index.isMultiple(of: 2)
                                                ? Color.clear : Color.secondary.opacity(0.06)
                                        )
                                }
                            } header: {
                                dayHeader(group.day)
                            }
                        }
                        footer
                    }
                }
                .frame(height: 190)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func dayHeader(_ day: Date) -> some View {
        HStack(spacing: 6) {
            Text(day, format: .dateTime.month(.defaultDigits).day())
                .font(.caption2.weight(.semibold))
            Text(day, format: .dateTime.weekday(.abbreviated))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var footer: some View {
        if model.hasMoreFetches {
            Button {
                model.loadMoreFetches()
            } label: {
                Text("載入更多 \(UsageViewModel.fetchPageSize) 筆").font(.caption)
            }
            .buttonStyle(.borderless)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else {
            Text("已經是最早的紀錄")
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
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
