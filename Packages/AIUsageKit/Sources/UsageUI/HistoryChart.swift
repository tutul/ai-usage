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

    public init(model: UsageViewModel) { self.model = model }

    var buckets: [HourlyBucket] { model.hourly[service] ?? [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("服務", selection: $service) {
                ForEach(Service.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if buckets.isEmpty {
                ContentUnavailableView(
                    "尚無資料",
                    systemImage: "chart.bar",
                    description: Text("累積幾天後才會看得出模式。")
                )
                .frame(height: 260)
            } else {
                Chart {
                    ForEach(buckets, id: \.hourLocal) { bucket in
                        if let used = bucket.usedPercent {
                            BarMark(
                                x: .value("時間", bucket.hourStart, unit: .hour),
                                y: .value("用量 %", used)
                            )
                            .foregroundStyle(by: .value("類別", "已歸屬"))
                        }
                        if let unknown = bucket.unknownPercent {
                            BarMark(
                                x: .value("時間", bucket.hourStart, unit: .hour),
                                y: .value("用量 %", unknown)
                            )
                            .foregroundStyle(by: .value("類別", "未知區間"))
                            .opacity(0.45)
                        }
                    }
                }
                .chartForegroundStyleScale([
                    "已歸屬": Color.accentColor,
                    "未知區間": Color.orange
                ])
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 260)
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
}
