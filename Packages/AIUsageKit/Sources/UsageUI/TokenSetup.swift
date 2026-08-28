import SwiftUI

/// Claude token 輸入。
///
/// 由 **app 自己**寫入 Keychain，而非請使用者跑 `security` CLI ——
/// CLI 建立的項目 ACL 只信任 `security`，app 讀取時 macOS 會跳授權對話框。
/// app 自己建立則擁有該項目，不會有提示。
/// 同時 token 也不會經過 shell history。
public struct TokenSetupView: View {
    @State private var token = ""
    @State private var message: String?
    @State private var saved = false
    let onSave: (String) throws -> Void

    public init(onSave: @escaping (String) throws -> Void) {
        self.onSave = onSave
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("設定 Claude Token").font(.headline)
            Text("在終端機執行 `claude setup-token`，把產生的 token 貼在下面。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("貼上 token", text: $token)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Button("儲存", action: save)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(saved ? .green : .red)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func save() {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try onSave(trimmed)
            token = ""
            saved = true
            message = "已儲存，下次取樣生效"
        } catch {
            saved = false
            message = "儲存失敗：\(error)"
        }
    }
}
