import Testing
import Foundation
@testable import UsageUI

/// 修復指令是給人整段貼進終端機的。這裡用真的 zsh 跑，把四個指令換成只會報名字的函式 ——
/// 驗的是「貼上去會依序做什麼」，不是字串長得像不像。
@Suite("重新登入的整段指令")
struct LoginRemedyCommandTests {
    private let command = LoginRemedyView.command(
        team: "2PUS5K7TA4", account: "someone", appPath: "/Applications/AIUsage.app"
    )

    /// 用假的 pkill／claude／security／open 執行整段指令，回傳實際被呼叫的順序。
    private func run(loginSucceeds: Bool) throws -> [String] {
        let stubs = """
        pkill() { print -r -- "pkill $*" }
        claude() { print -r -- "claude $*"; return \(loginSucceeds ? 0 : 1) }
        security() { print -r -- "security $*" }
        open() { print -r -- "open $*" }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", stubs + "\n" + command]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return output.split(separator: "\n").map(String.init)
    }

    @Test("登入成功 -> 結束、登入、重設分區清單、重開，依序")
    func fullSequence() throws {
        let calls = try run(loginSucceeds: true)
        #expect(calls == [
            "pkill -x AIUsage",
            "claude auth login",
            "security set-generic-password-partition-list -S apple-tool:,apple:,teamid:2PUS5K7TA4 -s Claude Code-credentials -a someone",
            "open /Applications/AIUsage.app"
        ])
    }

    /// 在瀏覽器取消登入：分區清單不必動，但 app 一定要重新打開 ——
    /// 否則使用者只會看到 app 從選單列消失。
    @Test("登入失敗 -> 不動分區清單，但仍然重開 app")
    func reopensEvenIfLoginFails() throws {
        let calls = try run(loginSucceeds: false)
        #expect(calls == ["pkill -x AIUsage", "claude auth login", "open /Applications/AIUsage.app"])
    }

    /// 自動換行曾把 `apple-tool:` 斷在連字號上。現在每一行都自己斷在空白後的 ` \`，
    /// 而且顯示的就是複製出去的那一份。
    @Test("換行只出現在指令的續行符號之後")
    func linesBreakOnlyAfterContinuation() {
        let lines = command.split(separator: "\n")
        #expect(lines.dropLast().allSatisfy { $0.hasSuffix(" \\") })
        #expect(lines.contains { $0.contains("apple-tool:,apple:,teamid:2PUS5K7TA4") })
    }
}

@Suite("訊息裡的程式碼")
struct InlineMarkdownTests {
    @Test("反引號顯示成程式碼，不原樣印出")
    func backticksRendered() {
        let text = inlineMarkdown("在終端機執行 `claude auth login` 重新登入")
        #expect(String(text.characters) == "在終端機執行 claude auth login 重新登入")
    }

    /// 錯誤訊息也可能來自端點原文。格式怪的時候寧可照原文顯示，不可以把訊息吃掉。
    @Test("不成對的符號 -> 文字一個字都不少")
    func malformedKeepsText() {
        let raw = #"{"error":"invalid_grant"} *unclosed `tick"#
        let shown = String(inlineMarkdown(raw).characters)
        #expect(shown.contains("invalid_grant"))
        #expect(shown.contains("unclosed"))
    }
}
