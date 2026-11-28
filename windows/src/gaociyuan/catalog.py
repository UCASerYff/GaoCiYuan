"""账户目录，保留现有跨平台 Provider 和 Connection 标识。"""

from __future__ import annotations

from dataclasses import dataclass

FILE = "自动读取快照文件"
AGENT_LOCAL = "本机软件自动读取"
CODEX = "本机 Codex"
CLAUDE_DESKTOP = "Claude 桌面会话"
CLAUDE_STATUSLINE = "Claude Code 状态栏推送"
CURSOR = "Cursor 编辑器登录态"
COPILOT = "GitHub 设备流登录"
GROK_ACCOUNT = "Grok 账号额度"
MIMO = "小米 MiMo Coding Plan"
DEVIN_APP = "Devin 本机保存 plan"
DEVIN_API = "Devin 账单 API（粘贴凭证）"
OLLAMA = "Ollama Cloud 账号额度"
COMMAND_CODE = "Command Code API"
DSH = "DeepSeek Harness 本机凭证"
WORKBUDDY = "WorkBuddy 积分余额（本机只读）"
GEMINI_APP = "Gemini App 中的 Antigravity"
ANTIGRAVITY_REPORT = "Antigravity 独立版 /usage 报告"
GEMINI_APP_LEGACY_NAMES = ("Gemini 桌面端 Antigravity", "Gemini App 内置 Antigravity")
GEMINI_LEGACY_CONNECTIONS = frozenset((GEMINI_APP, AGENT_LOCAL, *GEMINI_APP_LEGACY_NAMES))
CUSTOM_API = "自定义 API 余额查询（GET）"
MINIMAX = "MiniMax Token Plan API"
MINIMAX_CLI = "MiniMax CLI 套餐额度"
GLM = "GLM Coding Plan API"
KIMI_CODING = "Kimi Code 额度 API"
KIMI_DESKTOP = "Kimi 桌面订阅页"
OPENCODE = "OpenCode 套餐额度"
OPENCODE_GO = "OpenCode Go 官方套餐额度"
CLINE = "Cline 账户额度"
FACTORY = "Factory Droid 账户额度"
ZED = "Zed 套餐额度"
KIRO = "Kiro CLI 额度"
QODER = "Qoder 积分额度"
TYPESAFE = "TypeSafe 账户余额"
OPENROUTER = "OpenRouter Key 额度"
TRAE = "Trae 中国站额度"
ALIBABA = "阿里云 Coding Plan 额度"
ALIBABA_TOKEN_CLI = "百炼 CLI Token Plan 额度"
ALIBABA_CODING_CLI = "百炼 CLI Coding Plan 额度"
STEPFUN = "StepFun 套餐额度"
NEW_API = "New API / One API 额度"
SUB2API = "Sub2API 账户额度"

KEY_CONNECTIONS = {
    OPENAI := "OpenAI 管理 API",
    ANTHROPIC := "Claude 管理 API",
    DEEPSEEK_API := "DeepSeek 余额 API",
    MOONSHOT := "Kimi 余额 API",
    MINIMAX,
    GLM,
    KIMI_CODING,
    XAI := "xAI 账单 API",
    ALIYUN := "阿里云百炼 / 余额 API",
    VOLC := "火山引擎方舟 / 余额 API",
    COPILOT,
    VOLC_ARK := "火山方舟 Coding Plan API",
    MIMO,
    DEVIN_API,
    OLLAMA,
    COMMAND_CODE,
}


@dataclass(frozen=True)
class Integration:
    name: str
    company: str
    mark: str
    url: str
    connection: str
    kind: str
    credential_label: str
    help: str


INTEGRATIONS: dict[str, Integration] = {
    "opencode": Integration("OpenCode", "Anomaly", "Oc", "https://opencode.ai", OPENCODE, "Agent", "Zen 会话 Cookie / Go API Key", "Zen 使用 opencode.ai 控制台的 auth Cookie，可选填写 wrk_ 开头的工作区 ID；Go 使用独立套餐 API Key。两种套餐分别查询，不合并额度。"),
    "cline": Integration("Cline", "Cline", "Cl", "https://app.cline.bot", CLINE, "Agent", "Cline API Key / workos: 令牌", "粘贴 Cline API Key，或保留 workos: 前缀的 Cline 登录令牌。读取套餐窗口、Credits 积分余额与本月付费用量。"),
    "factory": Integration("Factory Droid", "Factory", "Fd", "https://app.factory.ai", FACTORY, "Agent", "Factory Key / 访问令牌", "粘贴 Factory 的 API Key 或访问令牌，读取标准/核心额度池及账户余额。"),
    "zed": Integration("Zed", "Zed", "Z", "https://dashboard.zed.dev/", ZED, "Agent", "zed.session Cookie", "在 dashboard.zed.dev 的账单请求中复制 Cookie。显示模型用量与编辑预测额度，不限量项目单独注明。"),
    "kiro": Integration("Kiro", "AWS", "Ki", "https://kiro.dev", KIRO, "Agent", "", "需要已安装并登录的 kiro-cli。只运行固定的 /usage 查询，不调用模型。"),
    "qoder": Integration("Qoder", "Qoder", "Qd", "https://qoder.com", QODER, "Agent", "Qoder 控制台 Cookie", "复制所选地区 Qoder 控制台的 Cookie，读取总积分、共享积分与重置日期。"),
    "typesafe": Integration("TypeSafe", "TypeSafe", "Ts", "https://console.typesafe.ai", TYPESAFE, "LLM", "TypeSafe 控制台 Cookie", "使用控制台登录 Cookie 读取余额和已用量。V4.13 起不再新增。"),
    "openrouter": Integration("OpenRouter", "OpenRouter", "Or", "https://openrouter.ai/settings/keys", OPENROUTER, "LLM", "OpenRouter API Key", "读取当前 Key 的费用与额度上限。V4.13 起不再新增。"),
    "trae": Integration("Trae CN", "字节", "Tr", "https://www.trae.cn", TRAE, "Agent", "Cloud-IDE-JWT / Access Token", "使用 Trae 中国站账户的访问令牌，查询套餐剩余额度。"),
    "alibaba": Integration("Alibaba Coding Plan", "阿里云", "Ali", "https://bailian.console.aliyun.com", ALIBABA, "Agent", "阿里云控制台 Cookie", "使用百炼控制台额度请求中的 Cookie，读取 Token Plan 额度。"),
    "stepfun": Integration("StepFun", "阶跃星辰", "St", "https://platform.stepfun.com", STEPFUN, "LLM", "Oasis-Token", "查询 Coding Plan 额度窗口。V4.13 起不再新增。"),
    "newapi": Integration("New API / One API", "第三方服务", "Na", "", NEW_API, "LLM", "API Key / 账户访问令牌", "自建 HTTPS 服务。V4.13 起不再新增。"),
    "sub2api": Integration("Sub2API", "第三方服务", "S2", "", SUB2API, "LLM", "账户访问令牌", "自建 HTTPS 服务。V4.13 起不再新增。"),
}

_CORE = {
    "cursor": ("Cursor", "Cursor", "Cursor", "▷", "https://cursor.com/settings", "Cursor 复用编辑器登录态读取双额度池与套餐余额，不读取浏览器 Cookie，不发起模型调用。"),
    "copilot": ("GitHub", "Copilot", "Copilot", "⎇", "https://github.com/settings/copilot", "GitHub 设备流仅申请 read:user 权限，经 Copilot 插件接口读取 Premium、Chat 与 Completions 月度额度。"),
    "openai": ("OpenAI", "ChatGPT", "Codex", "O", "https://chatgpt.com/codex/settings/usage", "Codex 复用本机官方登录服务读取真实额度窗，不读取聊天，也不发起模型调用。"),
    "claude": ("Anthropic", "Claude", "Claude Code", "C", "https://claude.ai/settings/usage", "Claude Code 支持官方 OAuth、状态栏推送和显式选择的桌面会话路，读取 5 小时、每周及按模型额度窗。"),
    "deepseek": ("DeepSeek", "DeepSeek", "DeepSeek 桌面端", "D", "https://chat.deepseek.com", "DeepSeek Harness 是独立 Agent 入口；此处不再提供大模型 API 账户。"),
    "grok": ("xAI", "Grok", "Grok Bot", "𝕏", "https://grok.com", "Grok Bot 没有面向第三方的每周用量接口。Windows 版只在点击「读取本机额度」时读取 grokbot-usage.json，不访问未公开接口，也不在自动刷新里打开这份文件。"),
    "gemini": ("Google", "Gemini", "Antigravity", "✦", "https://antigravity.google/docs/cli/commands/usage", "Antigravity 按模型组共享 5 小时与每周额度。"),
    "qwen": ("阿里", "通义千问", "Qwen CLI", "Q", "https://www.qianwen.com", "Qoder 和 Alibaba Coding Plan 使用各自独立 Agent 入口；此处不再提供大模型 API 账户。"),
    "kimi": ("月之暗面", "Kimi", "Kimi Work", "K", "https://www.kimi.com", "Kimi Work / Kimi Code 支持专用额度 Key 或本机桌面订阅页只读采集，未运行时保留上次真实状态。"),
    "doubao": ("字节", "豆包", "豆包 Work", "豆", "https://www.doubao.com", "豆包桌面端经辅助功能只读采集当前时段、近 7 天额度和重置信息，前台使用中不打扰。"),
    "glm": ("智谱", "GLM", "Zcode", "Z", "https://chatglm.cn", "Zcode 自动读取 Coding Plan 的真实额度窗口。"),
    "minimax": ("MiniMax", "MiniMax", "MiniMax Code", "M", "https://agent.minimaxi.com", "MiniMax Code 自动查询 Token Plan 的真实额度窗口。"),
    "hy": ("腾讯", "混元", "混元", "元", "https://hunyuan.tencent.com", "WorkBuddy 使用独立 Agent 入口；此处不再提供大模型 API 账户。"),
    "mimo": ("小米", "MiMo", "MiMo Agent", "mi", "https://platform.xiaomimimo.com", "MiMo Agent 自动检测本机软件，并按所选连接方式读取真实额度。"),
    "devin": ("Devin", "Devin", "Devin", "◆", "https://app.devin.ai", "Devin 支持本机保存 plan 或账单连接，两路独立展示，互不回退、不混用口径。"),
    "ollama": ("Ollama", "Ollama Cloud", "Ollama", "ol", "https://ollama.com/settings", "Ollama 按显式提供的账号会话读取 Session 与 Weekly 用量。"),
    "commandcode": ("Command Code", "Command Code", "Command Code", "⌘", "https://commandcode.ai", "Command Code 读取滚动窗、组织上限、套餐额度与余额。"),
    "dsh": ("DeepSeek", "Harness", "DeepSeek Harness", "ds", "https://harness.deepseek.com/usage", "DeepSeek Harness 自动检测本机软件与登录凭证，读取钱包余额、赠金与累计消费。"),
    "workbuddy": ("腾讯", "WorkBuddy", "WorkBuddy", "W", "https://www.workbuddy.cn", "WorkBuddy 只读读取桌面端积分余额，后台采集并做 5 分钟节流，积分值不写日志。"),
    "custom": ("自定义", "API 计费", "自定义 API", "◈", "", "自定义 API 账户已于 V4.13 移除。"),
}


def known_provider(provider: str) -> bool:
    return provider in _CORE or provider in INTEGRATIONS


def integration(provider: str) -> Integration | None:
    return INTEGRATIONS.get(provider)


def company(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][0]
    item = INTEGRATIONS.get(provider)
    return item.company if item else provider


def platform(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][1]
    item = INTEGRATIONS.get(provider)
    return item.name if item else provider


def agent_software(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][2]
    item = INTEGRATIONS.get(provider)
    return item.name if item else provider


def mark(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][3]
    item = INTEGRATIONS.get(provider)
    return item.mark if item else provider[:1].upper()


def member_url(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][4]
    item = INTEGRATIONS.get(provider)
    return item.url if item else ""


def note(provider: str) -> str:
    if provider in _CORE:
        return _CORE[provider][5]
    item = INTEGRATIONS.get(provider)
    return item.help if item else ""


def display_name(provider: str) -> str:
    item = INTEGRATIONS.get(provider)
    if item:
        return item.name
    if provider == "copilot":
        return "GitHub · Copilot"
    if provider in {"deepseek", "minimax", "devin", "ollama", "commandcode"}:
        return platform(provider) if provider != "ollama" else "Ollama Cloud"
    if provider == "custom":
        return "自定义 · API 计费"
    if provider == "dsh":
        return "DeepSeek · Harness"
    if provider == "workbuddy":
        return "腾讯 · WorkBuddy"
    return f"{company(provider)} · {platform(provider)}"


def default_agent_name(provider: str) -> str:
    item = INTEGRATIONS.get(provider)
    if item:
        return item.name
    if provider == "custom":
        return "自定义账户"
    return f"{company(provider)} · {platform(provider)} · {agent_software(provider)}"


def creation_kinds(provider: str) -> list[str]:
    item = INTEGRATIONS.get(provider)
    if item:
        return ["Agent"] if item.kind == "Agent" else []
    if provider in {"qwen", "hy", "deepseek", "custom"}:
        return []
    if provider in _CORE:
        return ["Agent"]
    return []


def available_connections(provider: str, kind: str) -> list[str]:
    item = INTEGRATIONS.get(provider)
    if item:
        if provider == "opencode":
            return [OPENCODE_GO, item.connection, FILE]
        if provider == "alibaba":
            return [ALIBABA_TOKEN_CLI, ALIBABA_CODING_CLI, item.connection, FILE]
        return [item.connection, FILE]
    if kind == "Agent":
        listed: list[str] = []
        if provider == "openai":
            listed.append(CODEX)
        if provider == "claude":
            listed.extend((CLAUDE_STATUSLINE, CLAUDE_DESKTOP))
        if provider == "cursor":
            listed.append(CURSOR)
        if provider == "copilot":
            listed.append(COPILOT)
        if provider == "grok":
            listed.append(GROK_ACCOUNT)
        if provider == "mimo":
            listed.append(MIMO)
        if provider == "devin":
            listed.extend([DEVIN_APP, DEVIN_API])
        if provider == "ollama":
            listed.append(OLLAMA)
        if provider == "commandcode":
            listed.append(COMMAND_CODE)
        if provider == "dsh":
            listed.append(DSH)
        if provider == "workbuddy":
            listed.append(WORKBUDDY)
        if provider == "gemini":
            listed.extend((ANTIGRAVITY_REPORT, GEMINI_APP, *GEMINI_APP_LEGACY_NAMES))
        if provider == "custom":
            listed.append(CUSTOM_API)
        if provider == "minimax":
            listed.extend((MINIMAX_CLI, MINIMAX))
        elif provider == "glm":
            listed.append(GLM)
        elif provider == "kimi":
            listed.append(KIMI_CODING)
        if provider == "kimi":
            listed.append(KIMI_DESKTOP)
        listed.append(AGENT_LOCAL)
        listed.append(FILE)
        return listed
    listed = []
    mapping = {
        "openai": [OPENAI],
        "claude": [ANTHROPIC],
        "deepseek": [DEEPSEEK_API],
        "kimi": [MOONSHOT, KIMI_CODING],
        "grok": [XAI],
        "qwen": [ALIYUN],
        "doubao": [VOLC, VOLC_ARK],
        "glm": [GLM],
        "minimax": [MINIMAX],
    }
    listed.extend(mapping.get(provider, []))
    listed.append(FILE)
    return listed


def needs_key(connection: str) -> bool:
    if connection == OPENCODE_GO:
        return True
    item_connections = {item.connection for item in INTEGRATIONS.values()}
    if connection in item_connections and connection != KIRO:
        return True
    return connection in KEY_CONNECTIONS


def windows_read_mode(provider: str, connection: str) -> str:
    """Select the Windows reader without reinterpreting saved connection names."""
    if connection == FILE:
        return "file"
    if provider == "grok" and connection == AGENT_LOCAL:
        return "grokbot"
    if provider == "gemini" and connection == ANTIGRAVITY_REPORT:
        return "antigravity-report"
    if (provider, connection) in _WINDOWS_CONNECTORS:
        return "connector"
    return "unsupported"


def is_legacy_gemini_connection(provider: str, connection: str) -> bool:
    return provider == "gemini" and connection in GEMINI_LEGACY_CONNECTIONS


_WINDOWS_CONNECTORS = {
    ("openai", CODEX), ("openai", AGENT_LOCAL),
    ("claude", CLAUDE_STATUSLINE), ("claude", AGENT_LOCAL),
    ("mimo", MIMO),
    ("minimax", MINIMAX_CLI),
    ("opencode", OPENCODE_GO),
    ("alibaba", ALIBABA_TOKEN_CLI), ("alibaba", ALIBABA_CODING_CLI),
}

_WINDOWS_LIMITS = {
    "cursor": "Cursor 的组织管理 API 不提供个人双额度池。可在 Cursor 官方用量页查看。",
    "copilot": "GitHub 的公共账单 API 不返回个人的所有套餐额度窗口。可在 GitHub 官方用量页查看。",
    "grok": "Grok 账号额度与 Grok Bot 本机手动用量是两个独立来源。此账号连接没有公开查询接口。",
    "gemini": "这是已保存的旧 Gemini 连接。请另建 Antigravity 独立版账户来导入 /usage 报告。",
    "claude": "Claude 桌面会话读取依赖 macOS。Claude Code 可通过官方状态栏推送额度。",
    "kimi": "Windows 可以使用 Kimi 官方用量页查看额度。Mac 的本机桌面订阅页读取暂未移植。",
    "doubao": "豆包订阅页的本机读取已在 macOS 验证。请在豆包客户端查看额度。",
    "glm": "Zcode 的个人／团队额度可在客户端使用统计页查看。",
    "minimax": "请切换到 MiniMax CLI 套餐额度，并使用官方 mmx CLI 登录。",
    "alibaba": "使用官方百炼 CLI 的 Token Plan 或 Coding Plan 连接查询本人的订阅。",
    "opencode": "Windows 支持 OpenCode Go 的官方额度接口。Zen 仍可从其官方控制台查看。",
    "devin": "Devin 本机计划文件或网页账单会话目前在 macOS 可用。",
    "ollama": "Ollama Cloud 两个时段的用量可在官方设置页查看。",
    "dsh": "DeepSeek Harness 钱包余额可在官方用量页查看。",
    "workbuddy": "WorkBuddy 积分页的本机读取已在 macOS 验证。请在 WorkBuddy 客户端查看积分。",
    "kiro": "已登录的 Kiro CLI 支持交互式 /usage。",
    "qoder": "已登录的 Qoder CLI 支持交互式 /usage。",
}


def default_connection(provider: str) -> str:
    preferred = {"openai": CODEX, "claude": CLAUDE_STATUSLINE, "grok": AGENT_LOCAL, "mimo": MIMO, "gemini": ANTIGRAVITY_REPORT,
                 "minimax": MINIMAX_CLI, "opencode": OPENCODE_GO, "alibaba": ALIBABA_TOKEN_CLI}
    return preferred.get(provider, FILE)


def connection_details(provider: str, connection: str) -> dict:
    mode = windows_read_mode(provider, connection)
    details = {"mode": mode, "label": connection, "help": "", "credentialLabel": "", "pathLabel": "",
               "scopeLabel": "", "regions": []}
    if mode == "file":
        details.update(pathLabel="快照文件路径", help="读取明确选择的本地 JSON 快照。")
    elif mode == "grokbot":
        details.update(label="Grok Bot 本机用量", help="只有点击「读取本机额度」才读取应用资料里的 grokbot-usage.json。")
    elif mode == "antigravity-report":
        details.update(help="在官方 Antigravity CLI 中导出目标账户的 /usage JSON 或 UTF-8 文本。报告账户及采集时间未经验证，仅作历史参考。")
    elif mode == "unsupported":
        details.update(help=_WINDOWS_LIMITS.get(provider, "此连接在 Windows 暂无经验证的读取方式。可从官方页面查看，或选择本地快照。"))
        if is_legacy_gemini_connection(provider, connection):
            details["legacy"] = True
    elif provider == "openai":
        details.update(pathLabel="Codex CLI 可执行文件（可选）", help="使用已安装且已登录 ChatGPT 的 Codex CLI 查询额度。首次点击刷新以启用。")
    elif provider == "claude":
        details.update(help="在 Claude Code 配置官方 statusLine，用命令行工具的 --capture-claude-status 接收额度。")
    elif provider == "mimo":
        details.update(credentialLabel="MiMo 个人 Token Plan 专属密钥（tp-）",
                       regions=[{"value": "cn", "label": "中国"}, {"value": "sgp", "label": "新加坡"}, {"value": "ams", "label": "欧洲"}],
                       help="使用专属密钥查询个人套餐当前周期的积分与余量。请选择密钥所属集群。")
    elif provider == "minimax":
        details.update(help="安装官方 mmx CLI，在其中登录 Token Plan，再点击刷新查询 5 小时和每周额度。")
    elif provider == "opencode":
        details.update(credentialLabel="OpenCode Go API Key", help="使用 Go 专属密钥查询 5 小时、每周、每月额度。")
    elif provider == "alibaba":
        plan = "Token Plan" if connection == ALIBABA_TOKEN_CLI else "Coding Plan"
        details.update(help=f"安装官方百炼 CLI 并运行 bl auth login --console 完成授权，然后刷新 {plan} 额度。")
    return details


def catalog_entries() -> list[dict]:
    rows = []
    for provider in list(_CORE) + list(INTEGRATIONS):
        kinds = creation_kinds(provider)
        connections = available_connections(provider, "Agent")
        preferred = default_connection(provider)
        rows.append(
            {
                "id": provider,
                "name": display_name(provider),
                "defaultName": default_agent_name(provider),
                "company": company(provider),
                "agent": agent_software(provider),
                "mark": mark(provider),
                "note": connection_details(provider, preferred)["help"] if preferred != FILE else _WINDOWS_LIMITS.get(provider, "可查看官方用量页，或接入明确选择的本地快照。"),
                "url": member_url(provider),
                "creatable": bool(kinds),
                "connections": [ANTIGRAVITY_REPORT] if provider == "gemini" else connections,
                "defaultConnection": preferred,
                "connectionDetails": {item: connection_details(provider, item) for item in connections},
                "removed": provider == "custom" or (INTEGRATIONS.get(provider) is not None and INTEGRATIONS[provider].kind != "Agent"),
            }
        )
    return rows


def normalize_kind(raw: str) -> str:
    if raw in {"Agent", "agent", "会员额度", "membership"}:
        return "Agent"
    return "LLM"


_CONNECTION_ALIASES = {
    "本机 Codex": CODEX,
    "本机页面自动读取": AGENT_LOCAL,
    "本机软件自动读取": AGENT_LOCAL,
    "手动记录": AGENT_LOCAL,
    "screen": AGENT_LOCAL,
    "manual": AGENT_LOCAL,
    "阿里云余额 API": ALIYUN,
    "火山引擎余额 API": VOLC,
    **dict.fromkeys(GEMINI_APP_LEGACY_NAMES, GEMINI_APP),
}


def normalize_connection(raw: str) -> tuple[str, bool]:
    if raw in _CONNECTION_ALIASES:
        mapped = _CONNECTION_ALIASES[raw]
        return mapped, mapped != raw and raw not in {AGENT_LOCAL, CODEX}
    known = set()
    for provider in list(_CORE) + list(INTEGRATIONS):
        known.update(available_connections(provider, "Agent"))
        known.update(available_connections(provider, "LLM"))
    if raw in known:
        return raw, False
    return AGENT_LOCAL, True
