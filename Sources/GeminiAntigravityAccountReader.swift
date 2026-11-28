import ApplicationServices
import Foundation

extension AntigravityDesktopQuota {
    static func readGeminiAccount(app: AXUIElement, window: AXUIElement, query: AccessibilityQuery) throws -> String {
        var reader = GeminiAccountReader(app: app, window: window)
        do {
            let email = try reader.read(using: query)
            try reader.restore(using: query)
            return email
        } catch {
            let recovery = AccessibilityQuery(timeout: .seconds(4), checksCancellation: false, messagingTimeout: 0.3)
            try? reader.restore(using: recovery)
            throw error
        }
    }

    private struct GeminiAccountReader {
        let app: AXUIElement
        let window: AXUIElement

        private var restoreAntigravity = false
        private var closeSidebar = false
        private var cancelAccountMenu = false

        init(app: AXUIElement, window: AXUIElement) {
            self.app = app
            self.window = window
        }

        private enum Control: String {
            case leaveAntigravity = "codeModeExitButton"
            case enterAntigravity = "codeModeSwitcherButton"
            case sidebar = "sidebar_toggle"
            case account
        }

        mutating func read(using query: AccessibilityQuery) throws -> String {
            guard let exit = try control(.leaveAntigravity, using: query) else { throw Failure.accountNotVerified }
            try checkActionTarget(exit, using: query)
            restoreAntigravity = true
            try query.perform(kAXPressAction, on: exit)
            _ = try wait(using: query) { try control(.enterAntigravity, using: query) }
            Log.connectors.notice("Gemini Antigravity native mode reached for account verification")
            try query.pause()

            if try control(.account, using: query) == nil {
                guard let sidebar = try control(.sidebar, using: query) else { throw Failure.accountNotVerified }
                try checkActionTarget(sidebar, using: query)
                try query.perform(kAXPressAction, on: sidebar)
                closeSidebar = true
            }
            let account = try wait(using: query) { try control(.account, using: query) }
            Log.connectors.notice("Gemini Antigravity native account button located")
            try checkActionTarget(account, using: query)
            cancelAccountMenu = true
            try query.performFirstSupported([kAXPressAction, kAXShowMenuAction], on: account)
            let menu = try wait(using: query) { try self.menu(of: account, using: query) }
            Log.connectors.notice("Gemini Antigravity native account menu opened")
            let (item, email) = try currentAccount(in: menu, using: query)
            _ = try checkWindow(using: query)
            guard let currentMenu = try self.menu(of: account, using: query), CFEqual(currentMenu, menu) else {
                throw Failure.accountNotVerified
            }
            let (currentItem, currentEmail) = try currentAccount(in: currentMenu, using: query)
            guard CFEqual(currentItem, item), currentEmail == email else { throw Failure.accountNotVerified }
            Log.connectors.notice("Gemini Antigravity native account label stable")
            _ = try wait(using: query) { try checkWindow(using: query) }
            return email
        }

        mutating func restore(using query: AccessibilityQuery) throws {
            guard restoreAntigravity || closeSidebar || cancelAccountMenu else { return }
            try query.prepare(app)
            try checkWindow(using: query)
            if cancelAccountMenu {
                guard let button = try control(.account, using: query) else { throw Failure.accountNotVerified }
                if let menu = try menu(of: button, using: query) {
                    _ = try checkWindow(using: query)
                    try query.perform(kAXCancelAction, on: menu)
                }
                cancelAccountMenu = false
            }
            if closeSidebar {
                if try control(.account, using: query) != nil {
                    guard let sidebar = try control(.sidebar, using: query) else { throw Failure.accountNotVerified }
                    try checkActionTarget(sidebar, using: query)
                    try query.perform(kAXPressAction, on: sidebar)
                    _ = try wait(using: query) { try control(.account, using: query) == nil ? true : nil }
                }
                closeSidebar = false
            }
            if restoreAntigravity {
                if try control(.leaveAntigravity, using: query) == nil {
                    let enter = try wait(using: query) { try control(.enterAntigravity, using: query) }
                    try checkActionTarget(enter, using: query)
                    try query.perform(kAXPressAction, on: enter)
                    _ = try wait(using: query) { try control(.leaveAntigravity, using: query) }
                }
                restoreAntigravity = false
            }
        }

        private func checkWindow(using query: AccessibilityQuery) throws -> AXUIElement {
            try foregroundWindow(app, original: window, allowRecreated: restoreAntigravity, query: query)
        }

        private func checkActionTarget(_ element: AXUIElement, using query: AccessibilityQuery) throws {
            _ = try checkWindow(using: query)
            guard sameProcess(element), try query.bool(element, kAXEnabledAttribute) != false,
                  try !query.isHidden(element) else { throw Failure.accountNotVerified }
        }

        private func sameProcess(_ element: AXUIElement) -> Bool {
            var appPID: pid_t = 0
            var elementPID: pid_t = 0
            return AXUIElementGetPid(app, &appPID) == .success && appPID > 0
                && AXUIElementGetPid(element, &elementPID) == .success && appPID == elementPID
        }

        private func wait<T>(using query: AccessibilityQuery, forValue: () throws -> T?) throws -> T {
            for attempt in 0..<35 {
                do {
                    _ = try checkWindow(using: query)
                    if let value = try forValue() { return value }
                } catch Failure.clientNotResponding {
                    // The native and web views can be recreated between accessibility calls.
                }
                if attempt < 34 { try query.pause() }
            }
            throw Failure.accountNotVerified
        }

        private func control(_ control: Control, using query: AccessibilityQuery) throws -> AXUIElement? {
            let window = try checkWindow(using: query)
            var matches: [AXUIElement] = []
            for child in try query.children(window, role: kAXWindowRole) {
                try query.prepare(child)
                let role = try query.string(child, kAXRoleAttribute)
                if (role == kAXToolbarRole && control != .account) ||
                    ([kAXSplitGroupRole, kAXGroupRole, "AXLayoutArea"].contains(role) && (control == .account || control == .sidebar)) {
                    try collectControls(control, in: child, role: role, depth: 0, using: query, matches: &matches)
                }
            }
            guard matches.count <= 1 else { throw Failure.accountNotVerified }
            return matches.first
        }

        private func collectControls(_ control: Control, in parent: AXUIElement, role: String, depth: Int,
                                     using query: AccessibilityQuery, matches: inout [AXUIElement]) throws {
            guard depth < 3, try !query.isHidden(parent) else { return }
            for child in try query.children(parent, role: role) {
                try query.prepare(child)
                let role = try query.string(child, kAXRoleAttribute)
                if control == .account, [kAXMenuButtonRole, kAXPopUpButtonRole].contains(role) {
                    let title = try query.string(child, kAXTitleAttribute)
                    let description = try query.string(child, kAXDescriptionAttribute)
                    let labels = ["账号和设置", "account and settings"]
                    if (labels.contains(title.lowercased()) || labels.contains(description.lowercased())), try !query.isHidden(child) {
                        matches.append(child)
                    }
                } else if role == kAXButtonRole {
                    if try query.string(child, kAXIdentifierAttribute) == control.rawValue, try !query.isHidden(child) {
                        matches.append(child)
                    }
                } else if [kAXGroupRole, kAXSplitGroupRole, "AXLayoutArea", "AXLayoutItem"].contains(role),
                          control == .account || control == .sidebar {
                    try collectControls(control, in: child, role: role, depth: depth + 1, using: query, matches: &matches)
                }
            }
        }

        private func menu(of button: AXUIElement, using query: AccessibilityQuery) throws -> AXUIElement? {
            let menus = try query.list(button).filter { child in
                try query.prepare(child)
                return try query.string(child, kAXRoleAttribute) == kAXMenuRole && !query.isHidden(child)
            }
            var distinct: [AXUIElement] = []
            for menu in menus where !distinct.contains(where: { CFEqual($0, menu) }) { distinct.append(menu) }
            guard distinct.count <= 1, distinct.allSatisfy(sameProcess) else { throw Failure.accountNotVerified }
            return distinct.first
        }

        private func currentAccount(in menu: AXUIElement, using query: AccessibilityQuery) throws -> (AXUIElement, String) {
            // Gemini presents the active account on the first direct native menu item.
            // Its submenu contains other accounts. Inspect only its role and never open it.
            guard let first = try query.list(menu).first, sameProcess(first) else { throw Failure.accountNotVerified }
            try query.prepare(first)
            guard try query.string(first, kAXRoleAttribute) == kAXMenuItemRole,
                  try !query.isHidden(first),
                  let submenu = try query.list(first).first, sameProcess(submenu) else { throw Failure.accountNotVerified }
            try query.prepare(submenu)
            guard try query.string(submenu, kAXRoleAttribute) == kAXMenuRole,
                  let email = try AntigravityStatusLine.canonicalEmail(query.leafText(first)) else {
                throw Failure.accountNotVerified
            }
            return (first, email)
        }
    }
}
