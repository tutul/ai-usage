import Foundation
import Observation
import ServiceManagement

/// 開機自動啟動。
///
/// **狀態一律從 `SMAppService` 讀取，不自行記錄** —— 使用者可以在
/// 「系統設定 → 一般 → 登入項目」直接關掉，自行記錄的話 UI 會顯示錯誤狀態。
@MainActor
@Observable
public final class LaunchAtLogin {
    public private(set) var isEnabled = false
    public private(set) var needsApproval = false
    public private(set) var errorMessage: String?

    /// 從建置產物目錄註冊會把該路徑寫進登入項目 —— 目錄一清就失效。
    /// 這不是錯誤，但值得提醒使用者搬進 /Applications。
    public var isInApplicationsFolder: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    public init() { refresh() }

    public func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled:
            isEnabled = true;  needsApproval = false
        case .requiresApproval:
            isEnabled = true;  needsApproval = true
        case .notRegistered, .notFound:
            isEnabled = false; needsApproval = false
        @unknown default:
            isEnabled = false; needsApproval = false
        }
    }

    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = "設定失敗：\(error.localizedDescription)"
        }
        refresh()
    }
}
