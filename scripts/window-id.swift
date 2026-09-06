// 列出本 app 的視窗 id，供 screencapture -l 只截自己的視窗用。
//
// 整螢幕擷取會拍到使用者其他 app 的私人內容，所以一律只截單一視窗：
//   swift scripts/window-id.swift
//   screencapture -x -o -l <windowID> /tmp/win.png
import CoreGraphics
import Foundation

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerName as String] as? String) == "AIUsage" {
    let id = w[kCGWindowNumber as String] as? Int ?? -1
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("\(id)\t\(name)\t\(b["Width"] ?? "?")x\(b["Height"] ?? "?")")
}
