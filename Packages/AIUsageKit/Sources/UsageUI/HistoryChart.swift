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
    @State private var service: Service = .claude
    @State private var hovered: HourlyBucket?

    public init(model: UsageViewModel) { self.model = model }

    var buckets: [HourlyBucket] { model.hourly[service] ?? [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("服務", selection: $service) {
                ForEach(Service.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: service) { hovered = nil }

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

            Text("「未知區間」表示該段消耗確實發生，但因取樣中斷而無法歸屬到特定小時；"
                 + "日與週的彙總仍會計入。沒有樣本的小時不會出現長條。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 400)
    }

    private var chart: some View {
        Chart {
            ForEach(buckets, id: \.hourLocal) { bucket in
                if let used = bucket.usedPercent {
                    BarMark(
                        x: .value("時間", bucket.hourStart, unit: .hour),
                        y: .value("用量 %", used)
                    )
                    .foregroundStyle(by: .value("類別", "已歸屬"))
                    .opacity(dimmed(bucket) ? 0.35 : 1)
                }
                if let unknown = bucket.unknownPercent {
                    BarMark(
                        x: .value("時間", bucket.hourStart, unit: .hour),
                        y: .value("用量 %", unknown)
                    )
                    .foregroundStyle(by: .value("類別", "未知區間"))
                    .opacity(dimmed(bucket) ? 0.2 : 0.45)
                }
            }
        }
        .chartForegroundStyleScale([
            "已歸屬": Color.accentColor,
            "未知區間": Color.orange
        ])
        .chartLegend(position: .top, alignment: .leading)
        // 指示線與提示框自己畫，不用 RuleMark + annotation ——
        // 單參數的 RuleMark(x:) 會被解析成 3D 圖表的多載，且位置較難控制。
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let rect = geometry[plotFrame]
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    guard rect.contains(location),
                                          let date = proxy.value(atX: location.x - rect.minX, as: Date.self)
                                    else { hovered = nil; return }
                                    hovered = nearestBucket(to: date)
                                case .ended:
                                    hovered = nil
                                }
                            }

                        if let hovered, let offset = proxy.position(forX: hovered.hourStart) {
                            let x = rect.minX + offset
                            Rectangle()
                                .fill(Color.secondary.opacity(0.4))
                                .frame(width: 1, height: rect.height)
                                .position(x: x, y: rect.midY)
                            tooltip(hovered)
                                .frame(width: tooltipWidth)
                                .position(
                                    x: min(max(x, rect.minX + tooltipWidth / 2), rect.maxX - tooltipWidth / 2),
                                    y: rect.minY + 52
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
        .frame(height: 260)
    }

    private var tooltipWidth: CGFloat { 180 }

    private func dimmed(_ bucket: HourlyBucket) -> Bool {
        hovered != nil && hovered?.hourLocal != bucket.hourLocal
    }

    /// 只在游標落在該小時格內時才選中 —— 超過半小時就不算，
    /// 否則游標停在空白處也會顯示遠處某根長條的數字，那是誤導。
    private func nearestBucket(to date: Date) -> HourlyBucket? {
        buckets
            .min { abs($0.hourStart.timeIntervalSince(date)) < abs($1.hourStart.timeIntervalSince(date)) }
            .flatMap { abs($0.hourStart.timeIntervalSince(date)) <= 1800 ? $0 : nil }
    }

    @ViewBuilder
    private func tooltip(_ bucket: HourlyBucket) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(bucket.hourStart, format: .dateTime.month().day().hour())
                .font(.caption.weight(.semibold))
            if let used = bucket.usedPercent {
                row("已歸屬", value: used, color: .accentColor)
            }
            if let unknown = bucket.unknownPercent {
                row("未知區間", value: unknown, color: .orange)
                Text("取樣中斷，無法歸屬到特定小時")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if bucket.usedPercent == nil && bucket.unknownPercent == nil {
                Text("無用量變化").font(.caption2).foregroundStyle(.secondary)
            }
            Text("\(bucket.pairCount) 筆取樣")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
