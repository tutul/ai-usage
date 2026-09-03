// 印出某個 Keychain 項目的授權清單與**分區清單**。
//
// 分區清單是 macOS 疊在 ACL 之上的第二道關卡，Keychain Access 的 GUI 看不到它 ——
// 而它才是「每次重新建置就被要求輸入密碼」的成因（見 docs/history/decisions.md D-015）。
//
//   swift scripts/keychain-acl.swift                     # 預設看 Claude Code-credentials
//   swift scripts/keychain-acl.swift "其他服務名稱"
//
// 唯讀，不會修改任何東西。分區清單會以 ACLAuthorizationPartitionID 那一條的
// description 呈現，內容是十六進位編碼的 plist。

import Foundation
import Security

var ref: CFTypeRef?
let q: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: CommandLine.arguments.dropFirst().first ?? "Claude Code-credentials",
    kSecReturnRef as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
let st = SecItemCopyMatching(q as CFDictionary, &ref)
guard st == errSecSuccess, let item = ref else {
    print("找不到項目 OSStatus \(st)"); exit(1)
}
var access: SecAccess?
let a = SecKeychainItemCopyAccess(item as! SecKeychainItem, &access)
guard a == errSecSuccess, let access else { print("讀 ACL 失敗 OSStatus \(a)"); exit(1) }

var aclList: CFArray?
guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
      let acls = aclList as? [SecACL] else { print("列 ACL 失敗"); exit(1) }

print("ACL 數量: \(acls.count)")
for (i, acl) in acls.enumerated() {
    var apps: CFArray?
    var desc: CFString?
    var prompt = SecKeychainPromptSelector()
    let r = SecACLCopyContents(acl, &apps, &desc, &prompt)
    let auths = SecACLCopyAuthorizations(acl) as? [String] ?? []
    let rawDesc = desc as String? ?? "-"
    let shown: String
    if auths.contains("ACLAuthorizationPartitionID"),
       let bytes = try? Data(hex: rawDesc), let plist = String(data: bytes, encoding: .utf8) {
        shown = "（分區清單，已解碼）\n" + plist.split(separator: "\n")
            .filter { $0.contains("<string>") }
            .map { "      " + $0.trimmingCharacters(in: .whitespaces)
                     .replacingOccurrences(of: "<string>", with: "")
                     .replacingOccurrences(of: "</string>", with: "") }
            .joined(separator: "\n")
    } else {
        shown = rawDesc
    }
    print("\n[\(i)] status=\(r) desc=\(shown)")
    print("    授權項目: \(auths.joined(separator: ", "))")
    print("    prompt flags: rawValue=\(prompt.rawValue) requirePassphrase=\(prompt.contains(.requirePassphase))")
    if let list = apps as? [SecTrustedApplication] {
        print("    信任的應用程式 (\(list.count)):")
        for app in list {
            var d: CFData?
            if SecTrustedApplicationCopyData(app, &d) == errSecSuccess, let d = d as Data? {
                print("      - \(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters) ?? "?")")
            }
        }
    } else {
        print("    信任的應用程式: nil（= 任何程式都要問使用者）")
    }
}


extension Data {
    /// ACLAuthorizationPartitionID 的 description 是十六進位編碼的 plist。
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self = out
    }
}
