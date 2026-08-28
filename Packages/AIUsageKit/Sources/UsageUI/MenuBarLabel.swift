import SwiftUI
import UsageCore

/// menu bar 只放一個圖示 —— 文字標籤在項目多的 menu bar 上會被擠掉。
/// 狀態靠顏色與符號傳達，細節點開才看。
public struct MenuBarLabel: View {
    let model: UsageViewModel
    public init(model: UsageViewModel) { self.model = model }

    /// 任一服務停擺就整體示警 —— 「有一家沒在記錄」比「另一家的數字」重要。
    var anyStale: Bool { Service.allCases.contains { model.isStale($0) } }

    var maxPercent: Double {
        Service.allCases.compactMap { model.weekly(for: $0)?.percent }.max() ?? 0
    }

    var symbol: String {
        guard !anyStale else { return "exclamationmark.triangle.fill" }
        switch maxPercent {
        case ..<20: return "gauge.with.dots.needle.0percent"
        case ..<45: return "gauge.with.dots.needle.33percent"
        case ..<70: return "gauge.with.dots.needle.50percent"
        case ..<90: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    var tint: Color {
        if anyStale { return .orange }
        switch maxPercent {
        case ..<70: return .primary
        case ..<90: return .orange
        default: return .red
        }
    }

    public var body: some View {
        Image(systemName: symbol).foregroundStyle(tint)
    }
}
