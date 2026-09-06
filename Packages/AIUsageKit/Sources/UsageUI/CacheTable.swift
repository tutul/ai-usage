import SwiftUI
import UsageStore

/// 快取分頁：按專案 × 日呈現 token 分解。
///
/// **刻意不做成圖表。** 這裡要回答的是「我那天做了什麼、為什麼快取被重寫」，
/// 需要的是可以逐列對照的數字，不是趨勢線。
///
/// 只標記「閒置後重寫」這一種原因 —— 它可驗證（距上次請求超過快取 TTL）。
/// 其餘寫入的成因（改動前面的內容、context 壓縮、換模型…）從紀錄判斷不出來，
/// 所以不猜、不歸因，只把數量放著讓使用者自己對照。
struct CacheTableView: View {
    let model: UsageViewModel

    private var rows: [UsageDatabase.CacheDailyRow] { model.cacheRows }
    private var totalCreated: Int { rows.reduce(0) { $0 + $1.createdTokens } }
    private var totalIdle: Int { rows.reduce(0) { $0 + $1.createdAfterIdle } }
    private var totalRead: Int { rows.reduce(0) { $0 + $1.readTokens } }
    private var totalRequests: Int { rows.reduce(0) { $0 + $1.requests } }
    private var totalIdleResumes: Int { rows.reduce(0) { $0 + $1.idleResumes } }

    private var days: [(day: String, items: [UsageDatabase.CacheDailyRow])] {
        var order: [String] = []
        var byDay: [String: [UsageDatabase.CacheDailyRow]] = [:]
        for row in rows {
            if byDay[row.day] == nil { order.append(row.day) }
            byDay[row.day, default: []].append(row)
        }
        return order.map { ($0, byDay[$0] ?? []) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                ContentUnavailableView(
                    "這個範圍內沒有對話紀錄",
                    systemImage: "tray",
                    description: Text("紀錄來自 ~/.claude/projects 的 JSONL，換個日期範圍看看。")
                )
                .frame(maxHeight: .infinity)
            } else {
                summary
                Divider()
                table
            }
        }
    }

    // MARK: - 摘要

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 20) {
                stat("快取讀取", tokens(totalRead), "便宜的部分")
                stat("快取寫入", tokens(totalCreated), "貴的部分")
                stat("其中閒置後重寫", tokens(totalIdle),
                     totalCreated > 0
                        ? String(format: "%.0f%%・%d 次", 100.0 * Double(totalIdle) / Double(totalCreated), totalIdleResumes)
                        : "—")
                stat("請求數", "\(totalRequests)", "")
                Spacer()
            }
            if totalCreated > 0, totalRequests > 0 {
                Text("這段期間 \(totalIdleResumes) 次「隔了超過一小時才回來」的請求，"
                     + "佔了全部快取寫入的 \(Int(100.0 * Double(totalIdle) / Double(totalCreated)))%"
                     + "（請求數只佔 \(String(format: "%.1f", 100.0 * Double(totalIdleResumes) / Double(totalRequests)))%）。"
                     + "快取的存活時間是 1 小時，超過就得整包重寫。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stat(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.medium))
            if !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 表格

    private var table: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader
            ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(days, id: \.day) { group in
                    Section {
                        ForEach(Array(group.items.enumerated()), id: \.element.id) { index, row in
                            projectRow(row)
                                .padding(.vertical, 3)
                                .padding(.horizontal, 6)
                                .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                        }
                    } header: {
                        dayHeader(group)
                    }
                }
            }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    /// 四個數字欄沒有標題就看不懂哪個是哪個。
    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("專案").frame(width: 190, alignment: .leading)
            Text("寫入").frame(width: 70, alignment: .trailing)
            Text("閒置後").frame(width: 70, alignment: .trailing)
            Text("讀取").frame(width: 78, alignment: .trailing)
            Text("請求").frame(width: 46, alignment: .trailing)
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private func dayHeader(_ group: (day: String, items: [UsageDatabase.CacheDailyRow])) -> some View {
        let created = group.items.reduce(0) { $0 + $1.createdTokens }
        let idle = group.items.reduce(0) { $0 + $1.createdAfterIdle }
        return HStack(spacing: 8) {
            Text(group.day).font(.caption.weight(.semibold))
            Text("寫入 \(tokens(created))").font(.caption2).foregroundStyle(.secondary)
            if idle > 0 {
                Text("閒置後 \(tokens(idle))").font(.caption2).foregroundStyle(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private func projectRow(_ row: UsageDatabase.CacheDailyRow) -> some View {
        HStack(spacing: 8) {
            Text(row.shortProject)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(width: 190, alignment: .leading)
                .help(row.project)

            Text(tokens(row.createdTokens))
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)

            // 閒置後重寫：唯一能可靠判斷的原因，用顏色點出來。
            Text(row.createdAfterIdle > 0 ? tokens(row.createdAfterIdle) : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.createdAfterIdle > 0 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.tertiary))
                .frame(width: 70, alignment: .trailing)
                .help(row.idleResumes > 0 ? "\(row.idleResumes) 次隔了超過一小時才回來" : "")

            Text(tokens(row.readTokens))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .trailing)

            Text("\(row.requests)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)

            Spacer(minLength: 0)
        }
    }

    private func tokens(_ value: Int) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:     return String(format: "%.0fK", Double(value) / 1_000)
        default:           return "\(value)"
        }
    }
}
