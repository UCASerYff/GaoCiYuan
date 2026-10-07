import Foundation

// 各平台本机 Agent 软件的共享识别表：运行检测、安装检测、CLI 候选路径唯一来源。
// 语义与 V1.7 逐平台内联判断完全一致，仅收敛为一处维护。
enum AgentPlatformTable {
    struct Identity {
        var exactBundles: [String] = []     // bundle ID 精确匹配
        var bundleContains: [String] = []   // bundle ID 包含匹配
        var bundleExcludes: [String] = []   // 包含匹配的排除项（如 safari）
        var exactNames: [String] = []       // 进程本地化名称精确匹配（小写）
        var appNames: [String] = []         // /Applications 下的 .app 名称
        var cli: [String] = []              // CLI 候选路径，~ 代表用户目录
    }

    static func identity(_ p: Provider) -> Identity {
        switch p {
        case .openai:
            return Identity(exactBundles: ["com.openai.codex", "com.openai.chat"],
                            exactNames: ["chatgpt", "codex"],
                            appNames: ["ChatGPT.app", "Codex.app"],
                            cli: ["/usr/local/bin/codex", "/opt/homebrew/bin/codex", "~/.local/bin/codex"])
        case .claude:
            return Identity(exactBundles: ["com.anthropic.claudefordesktop"],
                            bundleContains: ["anthropic"],
                            exactNames: ["claude", "claude code"],
                            appNames: ["Claude.app"],
                            cli: ["/usr/local/bin/claude", "/opt/homebrew/bin/claude", "~/.local/bin/claude"])
        case .gemini:
            return Identity(exactBundles: ["com.google.antigravity"],
                            exactNames: ["antigravity"],
                            appNames: ["Antigravity.app"],
                            cli: ["/usr/local/bin/antigravity", "/opt/homebrew/bin/antigravity", "~/.local/bin/antigravity"])
        case .grok:
            return Identity(exactBundles: ["com.anysphere.sand"],
                            bundleContains: ["xai"],
                            exactNames: ["grok bot", "grok"],
                            appNames: ["Grok.app"])
        case .deepseek:
            // DeepSeek Harness（com.deepseek.dsh）自 2.9 起由独立 .dsh 平台检测，
            // 这里必须排除，否则「本机 Agent 软件状态」网格会出现两行 DeepSeek Harness。
            return Identity(bundleContains: ["deepseek"],
                            bundleExcludes: ["safari", "deepseek.dsh"],
                            exactNames: ["deepseek"],
                            appNames: ["DeepSeek.app"])
        case .kimi:
            return Identity(exactBundles: ["com.moonshot.kimichat"],
                            bundleContains: ["moonshot"],
                            bundleExcludes: ["safari"],
                            exactNames: ["kimi", "kimi work"],
                            appNames: ["Kimi.app"])
        case .glm:
            return Identity(exactBundles: ["dev.zcode.app"],
                            bundleContains: ["zcode"],
                            exactNames: ["zcode", "chatglm"],
                            appNames: ["Zcode.app"],
                            cli: ["/usr/local/bin/zcode", "/opt/homebrew/bin/zcode"])
        case .qwen:
            return Identity(exactNames: ["qwen"],
                            cli: ["/usr/local/bin/qwen", "/opt/homebrew/bin/qwen", "~/.local/bin/qwen"])
        case .qoder:
            return Identity(exactBundles: ["com.qoder.app"],
                            bundleContains: ["qoder"],
                            bundleExcludes: ["dock"],
                            exactNames: ["qoder", "qodercn"],
                            appNames: ["Qoder.app", "QoderCN.app"],
                            cli: ["/usr/local/bin/qoder", "/opt/homebrew/bin/qoder"])
        case .doubao:
            return Identity(exactBundles: ["com.bot.pc.doubao"],
                            exactNames: ["doubao", "豆包", "豆包 work"],
                            appNames: ["Doubao.app", "豆包.app"])
        case .minimax:
            return Identity(exactBundles: ["com.minimax.agent.cn"],
                            exactNames: ["minimax", "minimax code"],
                            appNames: ["MiniMax.app"])
        case .hy:
            // 3.2 起 WorkBuddy（com.tencent.workbuddy.mac）归独立 .workbuddy 平台检测，
            // 这里必须留空，否则「本机 Agent 软件状态」网格会出现两行 WorkBuddy（dsh 同款教训）。
            return Identity()
        case .workbuddy:
            return Identity(exactBundles: ["com.tencent.workbuddy.mac"],
                            exactNames: ["workbuddy", "混元"],
                            appNames: ["WorkBuddy.app", "Workbuddy.app"],
                            cli: ["/usr/local/bin/workbuddy", "/opt/homebrew/bin/workbuddy"])
        case .mimo:
            return Identity(bundleContains: ["mimo"],
                            exactNames: ["mimo", "mimo agent"],
                            appNames: ["MiMo.app"])
        case .cursor:
            return Identity(bundleContains: ["todesktop"],
                            exactNames: ["cursor"],
                            appNames: ["Cursor.app"],
                            cli: ["/usr/local/bin/cursor-agent", "/opt/homebrew/bin/cursor-agent", "~/.local/bin/cursor-agent"])
        case .copilot:
            return Identity(bundleContains: ["github"],
                            exactNames: ["github desktop"],
                            appNames: ["GitHub Desktop.app"],
                            cli: ["/usr/local/bin/gh", "/opt/homebrew/bin/gh"])
        case .devin:
            // Devin.app 是改名后的 Windsurf 编辑器，bundle id 仍是 com.exafunction.windsurf。
            return Identity(exactBundles: ["com.exafunction.windsurf"],
                            exactNames: ["devin", "windsurf"],
                            appNames: ["Devin.app", "Windsurf.app"])
        case .ollama:
            return Identity(bundleContains: ["ollama"],
                            exactNames: ["ollama"],
                            appNames: ["Ollama.app"],
                            cli: ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama"])
        case .commandcode:
            return Identity(bundleContains: ["commandcode"],
                            exactNames: ["command code", "commandcode"],
                            cli: ["/usr/local/bin/command-code", "/opt/homebrew/bin/command-code", "/usr/local/bin/cmdc", "/opt/homebrew/bin/cmdc"])
        case .dsh:
            return Identity(exactBundles: ["com.deepseek.dsh"],
                            exactNames: ["deepseek harness"],
                            appNames: ["DeepSeek Harness.app"])
        default:
            // 自定义 API 账户没有对应本机软件：识别表留空，不参与运行/安装检测。
            return Identity()
        }
    }

    static func hasSoftwareIdentity(_ provider: Provider) -> Bool {
        let id = identity(provider)
        return !id.exactBundles.isEmpty || !id.bundleContains.isEmpty || !id.exactNames.isEmpty || !id.appNames.isEmpty || !id.cli.isEmpty
    }

    /// 进程运行匹配（入参已小写；调用方负责过滤系统进程）。
    static func matchesRunning(_ p: Provider, bundle: String, name: String) -> Bool {
        let id = identity(p)
        if id.exactBundles.contains(bundle) { return true }
        if !id.bundleContains.isEmpty,
           id.bundleContains.contains(where: { bundle.contains($0) }),
           !id.bundleExcludes.contains(where: { bundle.contains($0) }) { return true }
        if id.exactNames.contains(name) { return true }
        return false
    }

    /// CLI 候选路径。includeDedicatedHelper 时把数据目录内的 codex 助手与 ~/.codex/bin/codex 并入（与 V1.7 isAgentInstalled 语义一致）。
    static func cliCandidates(_ p: Provider, home: String, appSupport: String, includeDedicatedHelper: Bool) -> [String] {
        var list = identity(p).cli.map { $0.hasPrefix("~/") ? home + String($0.dropFirst(1)) : $0 }
        if includeDedicatedHelper, p == .openai {
            if !appSupport.isEmpty { list.insert("\(appSupport)/GaoSeries/Token/bin/codex", at: 0) }
            list.append("\(home)/.codex/bin/codex")
        }
        return list
    }
}
