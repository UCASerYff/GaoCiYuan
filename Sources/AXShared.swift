import Foundation
import ApplicationServices

// 共享 AX 遍历实现：主 app 的豆包 / Kimi 桌面连接器与 doubao-reader 助手编译同一文件。
// 只读遍历；findAndPress 是唯一的动作（点击），递归深度上限 30，与文本收集一致。
enum AXShared {
    static let maxDepth = 30

    static func collectTexts(_ el: AXUIElement, depth: Int = 0, into result: inout [String], limit: Int = 1000) {
        if depth > maxDepth || result.count > limit { return }
        var val: CFTypeRef?
        for attr in [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
            if AXUIElementCopyAttributeValue(el, attr as CFString, &val) == .success,
               let s = val as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed.count < 200 {
                    result.append(trimmed)
                }
            }
        }
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectTexts(child, depth: depth + 1, into: &result, limit: limit)
            }
        }
    }

    static func axString(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    @discardableResult
    static func findAndPress(_ el: AXUIElement, depth: Int = 0, matching: (String, String) -> Bool) -> Bool {
        if depth > maxDepth { return false }
        let sTitle = axString(el, kAXTitleAttribute) ?? ""
        let sVal = axString(el, kAXValueAttribute) ?? ""
        let sRole = axString(el, kAXRoleAttribute) ?? ""
        let text = "\(sTitle) \(sVal)"

        if matching(sRole, text) {
            let err = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if err == .success { return true }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                if findAndPress(child, depth: depth + 1, matching: matching) { return true }
            }
        }
        return false
    }
}
