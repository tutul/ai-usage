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

/// Claude 登入失效時的修復步驟。
///
/// refresh token 有固定壽命（實測 28 天），**輪替不會延長它** ——
/// 所以這不是偶發故障，是每個月都會遇到一次的例行事項。
/// 訊息只說「請執行 claude auth login」不夠：重新登入會改寫 Keychain 項目、
/// 可能把本 app 的存取權擠掉，漏掉那一步就會開始跳密碼視窗。
///
/// **四個步驟合成一段指令，整段貼到終端機。** 原本是分開列、第一步放一顆「結束 AIUsage」——
/// 但這個視窗屬於 AIUsage，按下去視窗就跟著關了，後面兩條指令再也看不到（2026-10-17 第一次看到實際畫面時發現）。
/// 交給終端機跑，app 結束之後指令照樣往下走。
public struct LoginRemedyView: View {
    public init() {}

    /// 這台機器上可以直接貼的整段指令。每行結尾的 ` \` 讓它可以原樣貼進 shell。
    ///
    /// - 登入失敗（例如在瀏覽器取消）就不重設分區清單，但**不管成敗都把 app 打開** ——
    ///   不然使用者會以為 app 不見了。
    nonisolated static func command(team: String, account: String, appPath: String) -> String {
        [
            "pkill -x AIUsage; \\",
            "claude auth login && \\",
            "security set-generic-password-partition-list \\",
            "  -S apple-tool:,apple:,teamid:\(team) \\",
            "  -s \"Claude Code-credentials\" -a \(account); \\",
            "open \"\(appPath)\""
        ].joined(separator: "\n")
    }

    private var command: String {
        Self.command(
            team: MachineIdentity.teamIdentifier ?? "你的十位team-ID",
            account: MachineIdentity.accountName,
            appPath: Bundle.main.bundlePath
        )
    }

    private let explanation: [(String, String)] = [
        ("結束 AIUsage", "重新登入會改寫 Keychain 項目，app 同時在讀的話會跳出密碼視窗。這個視窗會跟著關掉，指令會繼續跑。"),
        ("重新登入", "會開瀏覽器。這是唯一必要的步驟。"),
        ("把 Keychain 的分區清單寫回去", "會要求輸入登入密碼，可能問兩次。少了這步，之後每次讀取都會跳視窗。"),
        ("重新打開 AIUsage", "下次取樣會自動接上，不需要其他設定。登入沒完成也會打開。")
    ]

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

                VStack(alignment: .leading, spacing: 6) {
                    Text("複製整段，貼到終端機執行").font(.callout.weight(.medium))
                    CommandRow(command: command)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("它會依序做這四件事").font(.callout.weight(.medium))
                    ForEach(Array(explanation.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(item.0)").font(.callout)
                            Text(item.1)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Divider()
                Text(inlineMarkdown("做完之後 `claude` CLI 會再被登出一次 —— 本 app 續期時會把它手上那份換掉。"
                   + "這是刻意的取捨，見 README。"))
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

/// 字串裡的 `程式碼` 照 Markdown 顯示。用 `+` 接起來的字串是 String，
/// `Text` 不會解析它 —— 反引號會原樣印出來（2026-10-17 實際畫面）。
/// 解析失敗就照原文顯示，不要因為格式把訊息吃掉。
func inlineMarkdown(_ string: String) -> AttributedString {
    (try? AttributedString(
        markdown: string,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(string)
}

/// 指令 + 複製鈕。指令會很長，要能整條複製，不能讓人自己框選。
///
/// **不自動換行，改成可以左右捲。** 自動換行會在連字號處斷開
/// （實際畫面：`apple-` 與 `tool:` 被拆成兩行），照著打的人會打錯。
private struct CommandRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal) {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(6)
            }
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
