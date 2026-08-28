import Foundation
import CryptoKit

/// JSON 的**結構**指紋（排序後的 key path 雜湊），用來偵測端點改版。
///
/// 不可對整包 body 做雜湊去重：Codex 回應含 `reset_after_seconds`，每次呼叫都不同，
/// 逐 byte 比對會讓每筆都被視為新內容，儲存量回到 200 MB/年。
/// 陣列一律折疊為 `[]`，故元素個數變化不影響指紋 —— 只有結構真的改變才會變。
public enum JSONShape {
    public static func fingerprint(body: String) -> String {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        let paths = keyPaths(object).sorted().joined(separator: "\n")
        return SHA256.hash(data: Data(paths.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        if let dict = value as? [String: Any] {
            var out: Set<String> = []
            for (key, child) in dict {
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                out.insert(path)
                out.formUnion(keyPaths(child, prefix: path))
            }
            return out
        }
        if let array = value as? [Any] {
            var out: Set<String> = []
            for element in array { out.formUnion(keyPaths(element, prefix: "\(prefix)[]")) }
            return out
        }
        return []
    }
}
