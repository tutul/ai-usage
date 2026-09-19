import SwiftUI
import AppKit
import Security

/// 這台機器的身分，用來把修復指令**填成可以直接貼的樣子**。
/// 指令裡留 `<TEAMID>` 讓人自己查，等於把問題丟回去給使用者。
enum MachineIdentity {
    /// 從自己的簽章讀 team ID。ad-hoc 簽章沒有這個值，回 nil。
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    static var accountName: String { NSUserName() }
}

struct RemedyStep: Identifiable {
    let index: Int
    let title: String
    let command: String?
    let note: String?
    var id: Int { index }
}

/// Claude 登入失效時的修復步驟。
///
/// refresh token 有固定壽命（實測 28 天），**輪替不會延長它** ——
/// 所以這不是偶發故障，是每個月都會遇到一次的例行事項。
/// 訊息只說「請執行 claude auth login」不夠：重新登入會改寫 Keychain 項目、
/// 可能把本 app 的存取權擠掉，漏掉那一步就會開始跳密碼視窗。
public struct LoginRemedyView: View {
    let onQuit: () -> Void

    public init(onQuit: @escaping () -> Void) {
        self.onQuit = onQuit
    }

    private var steps: [RemedyStep] {
        let team = MachineIdentity.teamIdentifier ?? "你的十位 team ID"
        let partition = "security set-generic-password-partition-list"
            + " -S apple-tool:,apple:,teamid:\(team)"
            + " -s \"Claude Code-credentials\" -a \(MachineIdentity.accountName)"
        return [
            .init(index: 1, title: "先結束這個 app", command: nil,
                  note: "重新登入會改寫 Keychain 項目。app 同時在讀的話會跳出密碼視窗。"),
            .init(index: 2, title: "在終端機重新登入", command: "claude auth login",
                  note: "會開瀏覽器。這是唯一必要的步驟。"),
            .init(index: 3, title: "把兩邊寫回 Keychain 的分區清單", command: partition,
                  note: "會要求輸入登入密碼，可能問兩次。少了這步，之後每次讀取都會跳視窗。"),
            .init(index: 4, title: "重新打開 AIUsage", command: nil,
                  note: "下次取樣會自動接上，不需要其他設定。")
        ]
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Claude 的登入已失效")
                    .font(.title3.weight(.semibold))
                Text("refresh token 有固定壽命（實測約 28 天），每 8 小時續期一次也延長不了 —— "
                   + "這不是故障，是每個月會遇到一次的例行重新登入。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(step.index). \(step.title)").font(.callout.weight(.medium))
                        if let command = step.command {
                            CommandRow(command: command)
                        }
                        if let note = step.note {
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if step.index == 1 {
                            Button("結束 AIUsage", action: onQuit).controlSize(.small)
                        }
                    }
                }

                Divider()
                Text("做完之後 `claude` CLI 會再被登出一次 —— 本 app 續期時會把它手上那份換掉。"
                   + "這是刻意的取捨，見 README。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}

/// 指令 + 複製鈕。指令會很長，要能整條複製，不能讓人自己框選。
private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(command)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
            Button(copied ? "已複製" : "複製") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
            .controlSize(.small)
        }
    }
}
