import SwiftUI
import Charts
import UsageCore
import UsageStore

/// 歷史圖表 + 取樣日誌。
///
/// 四種視覺，意義完全不同，不可混淆：
/// - 折線上的藍點：該區間有用量，且可精確歸屬
/// - 折線上的橘色 ✕：消耗確實發生，但取樣中斷，只能算在這附近
/// - 折線上貼著 0 的小點：有取樣，但用量無變化
/// - 線斷開／完全空白：沒有取樣。**不補值、不連過去**
public struct HistoryChartView: View {
    let model: UsageViewModel
    let tracking: TrackingSettings
    /// 重新取樣（而非只是重讀資料庫）—— 使用者按重新整理時想看的是「現在的用量」，
    /// 只重讀 DB 在沒有新樣本時什麼都不會變。
    let onRefresh: () async -> Void

    enum Tab: String, CaseIterable { case usage = "用量", cache = "快取" }
    @State private var tab: Tab = .usage
    @State private var service: Service = .claude
    @State private var hoveredBucketStart: Date?
    @State private var isRefreshing = false
    @Environment(\.appearsActive) private var appearsActive

    public init(
        model: UsageViewModel,
        tracking: TrackingSettings,
        onRefresh: @escaping () async -> Void
    ) {
        self.model = model
        self.tracking = tracking
        self.onRefresh = onRefresh
    }

    private var granularity: Granularity { model.granularity }
    private var buckets: [UsageBucket] { model.buckets[service] ?? [] }
    private var windowSpans: [UsageDatabase.WindowSpan] { model.windowSpans[service] ?? [] }
    private var bucketSeconds: TimeInterval {
        switch granularity {
        case .hour: 3600
        case .day:  86_400
        case .week: 604_800
        }
    }
    private var calendarUnit: Calendar.Component {
        switch granularity {
        case .hour: .hour
        case .day:  .day
        case .week: .weekOfYear
        }
    }
    private var chartUnit: Calendar.Component { calendarUnit }
    /// 說明文字用的量詞。`displayName` 的「日」接在「這一」後面不通順。
    private var bucketNoun: String {
        switch granularity {
        case .hour: "小時"
        case .day:  "天"
        case .week: "週"
        }
    }

    /// **必須與 `v_weekly` 的分桶一致（週一起算）。**
    /// `Calendar.current.firstWeekday` 隨地區設定 —— 台灣與美國是**週日**，
    /// 用它算出的週起日會比資料庫早一天，hover 查不到那一格，
    /// 於是明明畫著點卻顯示「此週無取樣」。
    private var bucketCalendar: Calendar {
        guard granularity == .week else { return .current }
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    @ViewBuilder
    private func axisLabel(_ date: Date) -> some View {
        Text(date, format: granularity == .hour
             ? .dateTime.hour()
             : .dateTime.month(.defaultDigits).day())
            .font(.caption2)
            .fixedSize()   // 不加會被裁成「…」
    }

    /// 一格的量畫在該格的**中點**，不是起點。
    ///
    /// 每個點代表的是一整段區間的消耗，不是某一瞬間的值。畫在起點時，點會正好
    /// 壓在格線上 —— 於是「8/31 那一週」的點看起來像是「8/24 那一格的結尾」。
    /// 小時粒度因為另外有換日的帶狀底色，區間感還在，週粒度就完全看不出來了。
    /// 畫在中點，點就落在自己那一格的正中間，三種粒度的讀法一致。
    private func midpoint(_ bucket: UsageBucket) -> Date {
        bucket.start.addingTimeInterval(bucketSeconds / 2)
    }

    /// 刻度畫在區間邊界（含最後一格的收尾），與中點的資料點交錯。
    private var weekTicks: [Date]? {
        guard granularity == .week, let last = buckets.last?.start else { return nil }
        return buckets.map(\.start) + [last.addingTimeInterval(bucketSeconds)]
    }

    /// 涵蓋所有區間的完整跨度：第一格的起點到最後一格的**終點**。
    private var xDomain: ClosedRange<Date>? {
        guard let first = buckets.first?.start, let last = buckets.last?.start else { return nil }
        return first...last.addingTimeInterval(bucketSeconds)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("分頁", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if tab == .cache {
                cacheServicePicker
                rangeBar
                CacheTableView(model: model)
            } else {
                usageTab
            }
        }
        .padding(16)
        .onChange(of: appearsActive) { _, active in
            // 切回這個視窗時把資料庫最新狀態畫出來
            if active { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 640, minHeight: 620)
    }

    private var usageTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rangeBar

            if buckets.isEmpty {
                ContentUnavailableView(
                    "這個範圍內沒有資料",
                    systemImage: "calendar.badge.exclamationmark",
                    description: Text("換個日期範圍，或按「快速選擇 → 全部」看看有哪些資料。")
                )
                .frame(height: 240)
            } else {
                chart
            }

            Text("線只連接相鄰且都有取樣的區間，**斷開處代表沒有取樣**，不補值。貼著 0 的小點 = 有取樣但用量沒變。**橘色 ✕** 代表該筆消耗確實發生、但因取樣中斷而無法精確歸屬到這一\(bucketNoun)，只能算在這附近。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()
            fetchLog
        }
    }

    // MARK: - 標題列

    private var header: some View {
        HStack(spacing: 12) {
            // 只列已啟用的服務。歷史資料不會消失 —— 重新啟用就看得到。
            Picker("服務", selection: $service) {
                ForEach(tracking.enabledServices, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: service) { hoveredBucketStart = nil }
            // 選中的服務被關掉時，Picker 會停在一個不存在的選項上、看起來像壞了。
            .onChange(of: tracking.enabled) { _, _ in
                if !tracking.isEnabled(service), let first = tracking.enabledServices.first {
                    service = first
                }
            }

            Picker("粒度", selection: Binding(
                get: { model.granularity },
                set: { granularity in
                    model.granularity = granularity
                    hoveredBucketStart = nil
                    // 預設範圍是七天，切到週粒度只會框到一個曆週、圖上一個點。
                    // **只擴不縮**，所以不會弄丟使用者原本正在看的區間。
                    if granularity == .week { widenRangeAtLeast(days: 56) }
                    model.reload()
                }
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

    /// 快取分頁自己的服務選擇。與用量分頁分開 —— 兩者關心的東西不同，
    /// 而且兩家的快取機制不同、摘要數字不可混算。
    private var cacheServicePicker: some View {
        Picker("服務", selection: Binding(
            get: { model.cacheService },
            set: { model.cacheService = $0; model.reload() }
        )) {
            ForEach(tracking.enabledServices, id: \.self) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    // MARK: - 顯示範圍

    /// 兩端都經過夾擠，避免起 > 迄 —— DatePicker 的 `in:` 收到反向區間會當掉。
    private var startBinding: Binding<Date> {
        Binding(get: { model.rangeStart },
                set: { model.rangeStart = min($0, model.rangeEnd); model.reload() })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { model.rangeEnd },
                set: {
                    let today = Calendar.current.startOfDay(for: .now)
                    model.rangeEnd = max(min($0, today), model.rangeStart)
                    model.reload()
                })
    }

    /// 下界取「最早的樣本」與目前起日的較早者 —— 不能大於 `rangeStart`，
    /// 否則 `in:` 會是反向區間而當掉。
    private var pickerLowerBound: Date {
        let earliest = model.earliestSample ?? model.rangeStart
        return min(Calendar.current.startOfDay(for: earliest), model.rangeStart)
    }

    private var pickerUpperBound: Date {
        max(Calendar.current.startOfDay(for: .now), model.rangeEnd)
    }

    /// 把起日往前推到至少涵蓋 `days` 天。已經更早就不動。
    private func widenRangeAtLeast(days: Int) {
        let calendar = Calendar.current
        guard let target = calendar.date(byAdding: .day, value: -days, to: model.rangeEnd),
              target < model.rangeStart else { return }
        model.rangeStart = calendar.startOfDay(for: target)
    }

    private func setRange(daysBack: Int) {
        let today = Calendar.current.startOfDay(for: .now)
        model.rangeEnd = today
        model.rangeStart = Calendar.current.date(byAdding: .day, value: -daysBack, to: today) ?? today
        hoveredBucketStart = nil
        model.reload()
    }

    private var rangeBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(.secondary)

            // 兩端都給明確界線。開放式區間（`...end` / `start...`）搭配 macOS 的
            // stepper 欄位會在首次渲染時把值歸到界線上，把範圍縮成單一天。
            DatePicker("起", selection: startBinding,
                       in: pickerLowerBound...model.rangeEnd, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()

            Text("–").foregroundStyle(.secondary)

            DatePicker("迄", selection: endBinding,
                       in: model.rangeStart...pickerUpperBound, displayedComponents: .date)
                .labelsHidden()
                .fixedSize()

            Menu {
                Button("今天") { setRange(daysBack: 0) }
                Button("近 3 天") { setRange(daysBack: 2) }
                Button("近 7 天") { setRange(daysBack: 6) }
                Button("近 30 天") { setRange(daysBack: 29) }
                Divider()
                Button("近 4 週") { setRange(daysBack: 27) }
                Button("近 12 週") { setRange(daysBack: 83) }
                Divider()
                Button("全部") { hoveredBucketStart = nil; model.showAllRange() }
            } label: {
                Text("快速選擇").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            // 「N 個小時區間」講的是用量取樣，放在快取分頁會誤導。
            if tab == .cache {
                importControl
            } else {
                Text("\(buckets.count) 個\(granularity.displayName)區間")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var importControl: some View {
        HStack(spacing: 8) {
            if let result = model.cacheImport {
                Text(result.inserted > 0 ? "新增 \(result.inserted) 筆" : "沒有新紀錄")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Task { await model.importTranscripts() }
            } label: {
                if model.isImporting {
                    ProgressView().controlSize(.small)
                } else {
                    Label("匯入", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
            }
            .disabled(model.isImporting)
            .help("重新掃描 ~/.claude/projects 的 JSONL。可重複執行，不會產生重複資料。")
        }
    }

    // MARK: - 圖表

    /// 依資料跨度決定 X 軸刻度密度，避免長條細又對不上時間。
    private var axisStride: (count: Int, unit: Calendar.Component) {
        guard let first = buckets.first?.start, let last = buckets.last?.start else {
            return (1, calendarUnit)
        }
        let span = last.timeIntervalSince(first)
        // Swift Charts 的 `.stride(by:)` 不吃 `.weekOfYear`（給了會完全不畫刻度），
        // 用等價的 7 天。
        if granularity == .week {
            return (7, .day)
        }
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
               bucketCalendar.date(byAdding: calendarUnit, value: 1, to: prev.start) != bucket.start {
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

    /// 該區間的總消耗。已歸屬與未知都是「這一格發生的消耗」，圖上不該拆成兩套視覺。
    private func total(_ bucket: UsageBucket) -> Double {
        (bucket.usedPercent ?? 0) + (bucket.unknownPercent ?? 0)
    }

    private func isUncertain(_ bucket: UsageBucket) -> Bool { (bucket.unknownPercent ?? 0) > 0 }

    private func category(_ bucket: UsageBucket) -> String {
        isUncertain(bucket) ? "未知區間" : "已歸屬"
    }

    /// 上方留白。自動縮放會把最高的點畫在圖表邊緣，符號有一半被切掉、還會疊到圖例。
    private var yDomain: ClosedRange<Double> {
        let peak = buckets.map(total).max() ?? 0
        return 0...max(peak * 1.15, 1)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.key) { bucket in
                    // 線本身不分類別，否則同一段會被拆開。用固定色、壓低存在感，讓點說話。
                    LineMark(
                        x: .value("時間", midpoint(bucket)),
                        y: .value("用量 %", total(bucket)),
                        series: .value("段", index)
                    )
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .interpolationMethod(.linear)

                    // 未知區間併進同一條線 —— 它本來就已經被歸在某一格
                    //（v_hourly 算在後一個樣本所在的那小時），分成兩套視覺反而看不出在講同一件事。
                    // 不確定性改用點的顏色與形狀表示：同時用兩種通道，色覺障礙也分得出來。
                    PointMark(
                        x: .value("時間", midpoint(bucket)),
                        y: .value("用量 %", total(bucket))
                    )
                    .foregroundStyle(by: .value("類別", category(bucket)))
                    .symbol(by: .value("類別", category(bucket)))
                    .symbolSize(total(bucket) > 0 ? (isUncertain(bucket) ? 60 : 30) : 8)
                }
            }
        }
        .chartXScale(domain: xDomain ?? Date.distantPast...Date.distantFuture)
        .chartYScale(domain: yDomain)
        // 顏色與形狀兩個尺度的定義域必須一致，否則資料裡缺某個類別時
        // （例如日粒度沒有未知區間）會各自畫一個圖例，出現兩次「已歸屬」。
        .chartForegroundStyleScale([
            "已歸屬": Color.accentColor,
            "未知區間": Color.orange
        ])
        .chartSymbolScale([
            "已歸屬": BasicChartSymbolShape.circle,
            "未知區間": BasicChartSymbolShape.cross
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
            // 週粒度直接用每一格的起點當刻度。用 `.stride` 會從定義域起點起算，
            // 而定義域為了留白往前推了半格 —— 刻度就會落在 8/27、9/3 這種
            // 不是週起日的位置上。格數愈少，這種偏移愈明顯。
            if let ticks = weekTicks {
                AxisMarks(values: ticks) { value in
                    AxisGridLine()
                    AxisTick()
                    if let date = value.as(Date.self) { AxisValueLabel { axisLabel(date) } }
                }
            } else {
                AxisMarks(values: .stride(by: axisStride.unit, count: axisStride.count)) { value in
                    AxisGridLine()
                    AxisTick()
                    if let date = value.as(Date.self) { AxisValueLabel { axisLabel(date) } }
                }
            }
            // 第二層：換日的分隔線與日期。日／週粒度的標籤本來就是日期，不需要。
            AxisMarks(values: dayStarts) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.secondary.opacity(0.9))
                if let date = value.as(Date.self) {
                    AxisValueLabel {
                        Text(date, format: .dateTime.month(.defaultDigits).day())
                            .font(.caption2.weight(.semibold))
                            .fixedSize()
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
                                    hoveredBucketStart = bucketCalendar
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
            // 週粒度標成「X/Y 那一週」，否則只看到一個日期會以為是單日。
            Group {
                switch granularity {
                case .hour:
                    Text(start, format: .dateTime.month().day().hour())
                case .day:
                    Text(start, format: .dateTime.year().month().day())
                case .week:
                    Text(start, format: .dateTime.month().day()) + Text(" 那一週")
                }
            }
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
                if let note = windowNote(start) {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
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

    /// 這一格裡面有幾個額度窗。
    ///
    /// **時間桶不是額度窗**：曆週從週一起算，額度窗以首次使用為錨點，還會被提前重置。
    /// 一格含兩個窗時，百分比是兩個窗的加總，**可能超過 100%** ——
    /// 那個數字是對的，但不說清楚就會被當成算錯。
    /// 只在「多於一個窗」或「有提前重置」時才出現，否則每一格都掛一行等於沒說。
    private func windowNote(_ start: Date) -> String? {
        let end = bucketCalendar.date(byAdding: chartUnit, value: 1, to: start)
            ?? start.addingTimeInterval(bucketSeconds)
        // **重疊**，不是起點落在格內 —— 從上一格延續進來的窗一樣有消耗算在這一格。
        let inside = windowSpans.filter { $0.startedAt < end && $0.endedAt >= start }
        // 只算「在這一格裡結束」的提前重置，否則會把更早那一格的事報在這裡。
        let early = inside.filter { $0.endedEarly && $0.endedAt >= start && $0.endedAt < end }.count
        if inside.count >= 2 {
            let suffix = early > 0 ? "，其中 \(early) 次是提前重置" : ""
            return "此\(granularity.displayName)含 \(inside.count) 個額度窗\(suffix)。"
                 + "百分比是各窗加總，可能超過 100%。"
        }
        if early > 0 {
            return "此\(granularity.displayName)的額度窗被提前重置（未用滿就換窗）。"
        }
        return nil
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
                // 撐滿剩餘高度：固定高度會在視窗放大時留下一塊死空間，
                // 而日誌正是使用者會想看更多的部分。
                .frame(minHeight: 160, maxHeight: .infinity)
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
        // 睡眠中斷不是失敗，只是那一次沒有觀測。用灰色，別和真正的失敗搶注意力。
        let slept = fetch.errorKind == "slept"
        HStack(spacing: 8) {
            Text(fetch.completedAt, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Text(fetch.service.displayName)
                .font(.caption2)
                .frame(width: 48, alignment: .leading)

            Image(systemName: fetch.ok ? "checkmark.circle.fill" : (slept ? "moon.zzz.fill" : "xmark.circle.fill"))
                .font(.caption2)
                .foregroundStyle(fetch.ok ? Color.green : (slept ? Color.secondary : Color.orange))

            if fetch.ok {
                Text(fetch.weeklyPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.caption2.monospacedDigit())
                    .frame(width: 44, alignment: .leading)
                // 成功但缺週窗 —— 端點回 200 不代表拿到週用量
                if fetch.errorKind == "missing_window" {
                    Text("缺週窗").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(slept ? "睡眠中斷" : (fetch.errorKind ?? "失敗"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(slept ? Color.secondary : Color.orange)
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
