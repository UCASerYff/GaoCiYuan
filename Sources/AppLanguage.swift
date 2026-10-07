import Foundation

/// App 级统一语言偏好：UserDefaults.standard 的 `gqns.language`（system / zh-Hans / en）。
/// 各模块 framework 独立编译，本文件是该键在搞词元模块内的最小读取实现。
enum GQNSLanguage {
    static let key = "gqns.language"

    static var raw: String { UserDefaults.standard.string(forKey: key) ?? "system" }

    /// 解析后的界面语言是否为英文。system 时跟随系统首选语言：中文 → 简体，其余 → 英文；
    /// 读不到系统偏好时维持中文（与模块既有默认值一致）。
    static var isEnglish: Bool {
        switch raw {
        case "en": return true
        case "zh-Hans": return false
        default:
            guard let first = Locale.preferredLanguages.first else { return false }
            return !first.hasPrefix("zh")
        }
    }

    static var localeIdentifier: String { isEnglish ? "en" : "zh-Hans" }

    /// 一次性迁移：app 级键尚未写入、而模块旧键存在时，把旧选择提升为 app 级偏好。
    static func migrateLegacy(defaults: UserDefaults, legacyKey: String) {
        guard UserDefaults.standard.object(forKey: key) == nil,
              let legacy = defaults.string(forKey: legacyKey),
              ["zh-Hans", "en"].contains(legacy) else { return }
        UserDefaults.standard.set(legacy, forKey: key)
    }
}
