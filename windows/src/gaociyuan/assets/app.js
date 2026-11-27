const token = document.querySelector('meta[name="gao-token"]').content;
const main = document.querySelector("#main");
const dialog = document.querySelector("#dialog");
const navigation = document.querySelector("#navigation");
const topActions = document.querySelector("#top-actions");
const sidebarActions = document.querySelector("#sidebar-actions");
const workspaceContext = document.querySelector("#workspace-context");
const message = document.querySelector("#message");
const systemTheme = matchMedia("(prefers-color-scheme: dark)");
const fileConnection = "自动读取快照文件";
const localConnection = "本机软件自动读取";
const routeDefinitions = {
  overview: ["总览", "Agent 额度与状态，一眼看清", "overview"],
  agents: ["Agent 软件", "只记录本机 Agent 软件", "computer"],
  analytics: ["用量分析", "按日期、工具、模型与会话分析本地用量", "chart"],
  catalog: ["平台接入", "发现软件、连接额度、管理采集", "stack"],
};
const icons = {
  overview: "ECA5", computer: "E7F4", chart: "E9D2", stack: "E81E", refresh: "E72C",
  plus: "E710", more: "E712", settings: "E713", alert: "E783", pause: "E769",
  time: "E823", info: "E946", right: "E72A", database: "EDA2", bell: "E7ED",
  palette: "E790", download: "E896", upload: "E898", terminal: "E756", search: "E721",
  folder: "E8B7", key: "E8D7", down: "E74B", close: "E711", left: "E72B", cost: "E8C7",
  signal: "E702", window: "E737", cache: "EEA0", checklist: "E73A", external: "E8A7",
  chevron: "E76C", filter: "E71C", check: "E73E", link: "E71B",
};
const supplementalTranslations = {
  "总览": "Overview",
  "Agent 额度与状态，一眼看清": "Agent quotas and status at a glance",
  "只记录本机 Agent 软件": "Manage your local Agent apps",
  "用量分析": "Usage analytics",
  "按日期、工具、模型与会话分析本地用量": "Analyze local usage by date, tool, model and session",
  "发现软件、连接额度、管理采集": "Discover apps, connect quotas and manage collection",
  "已启用 Agent": "Enabled agents",
  "已接入平台": "Connected platforms",
  "需处理": "Needs attention",
  "账户与自动发现合并统计": "Configured and discovered accounts",
  "当前没有必须处理项": "Everything is up to date",
  "低额度、凭据或连续失败": "Low quotas, credentials or recurring failures",
  "从第一个 Agent 开始": "Connect your first Agent",
  "常用 AI 软件，一处查看。": "Your AI apps in one place.",
  "自动发现本机 Agent，读取真实额度与本地用量；不再记录大模型 API 账户。": "Discover installed Agent apps and see measured quotas and local usage.",
  "浏览 Agent 平台": "Browse Agent platforms",
  "添加 Codex": "Add Codex",
  "搜索软件、账户或套餐": "Search apps, accounts or plans",
  "选择 Agent 平台": "Choose an Agent platform",
  "添加 Agent 软件": "Add Agent app",
  "导出账户快照 CSV": "Export account snapshots as CSV",
  "添加与导出": "Add and export",
  "刷新全部 Agent": "Refresh all agents",
  "正在同步": "Syncing",
  "没有匹配的 Agent 软件": "No matching Agent apps",
  "暂无已接入的 Agent 软件": "No Agent apps connected",
  "暂无已启用的 Agent 软件": "No Agent apps enabled",
  "账户设置": "Account settings",
  "移除账户": "Remove account",
  "平台": "Platform",
  "账户名称": "Account name",
  "套餐 / 组织备注": "Plan / organization note",
  "连接方式": "Connection",
  "已保存凭据": "Credential saved",
  "Windows 快照文件路径": "Windows snapshot file path",
  "启用此账户": "Enable this account",
  "显示在悬浮条": "Show in the floating panel",
  "立即同步": "Sync now",
  "控制台 ↗": "Console ↗",
  "未找到匹配的 Agent 软件。": "No matching Agent apps.",
  "本机软件发现": "Local app discovery",
  "本机 Agent 软件状态": "Local Agent app status",
  "自动检测实际安装的软件和 CLI；账户配置不会被当作软件安装记录。": "Detect installed apps and command-line tools. A configured account does not count as an installation.",
  "刷新检测": "Rescan",
  "本机发现 · 额度连接": "Local discovery · quota connection",
  "采集设置": "Collection settings",
  "搜索 Agent 软件或本地来源": "Search Agent apps and local sources",
  "接入": "Connect",
  "已选择采集": "Selected",
  "未选择采集": "Not selected",
  "该采集源暂不支持 Windows": "This collection source is unavailable on Windows",
  "正在读取本机资料…": "Loading local data…",
  "账户快照": "Account snapshots",
  "CLI 与桌面端按实际日志格式归并": "Command-line and desktop tools are grouped by log format",
  "只分析 Agent 软件留下的 Token、模型和会话记录；没有日志时不显示成零用量。": "Analyze Agent token, model and session records. Missing records leave usage blank.",
  "未找到匹配的本地用量来源。": "No local usage sources match.",
  "尚未获取额度": "Quota unavailable",
  "上一计费周期已结束，等待平台新读数。": "The previous quota window ended. Waiting for a new reading.",
  "剩余": "remaining",
  "重置": "Resets",
  "数据截至": "Data as of",
  "采集说明": "Collection details",
  "状态栏配置示例": "Status line configuration example",
  "复制配置示例": "Copy configuration",
  "将下方 statusLine 字段合并到 Claude Code 的用户设置。若已使用自定义状态栏，请把接收命令加入现有脚本，并让它读取相同的标准输入。": "Merge the statusLine field below into your Claude Code user settings. If you already use a custom status line, add the capture command to your script and pass it the same standard input.",
  "移除 Agent 软件？": "Remove Agent app?",
  "将移除该软件在本机的额度快照和专属凭据，不影响平台上的账号。": "This removes the app's local quota snapshots and its saved credential. Your platform account remains active.",
  "请求失败": "Request failed",
  "下载失败": "Download failed",
  "资料库无法写入": "Local data is read-only",
  "添加": "Add",
  "跳到主内容": "Skip to main content",
  "全部同步": "Sync all",
  "新建账户": "New account",
  "账户状态": "Account status",
  "额度概览": "Quota overview",
  "账户明细": "Account details",
  "选一个账户查看额度和连接状态。": "Select an account to see its quotas and connection status.",
  "暂无可显示的账户": "No accounts to display",
  "接入第一个 Agent": "Connect your first Agent",
  "添加正在使用的 Agent，或接入外部采集器写入的额度快照。": "Add an Agent you use, or connect a quota snapshot from an external collector.",
  "快捷接入": "Quick connect",
  "自动同步": "Automatic sync",
  "自动同步已暂停": "Automatic sync paused",
  "最近同步尝试": "Last sync attempt",
  "未同步": "Not yet synced",
  "暂未同步": "Sync paused",
  "正常": "Healthy",
  "已启用": "Enabled",
  "已暂停": "Paused",
  "按账户状态筛选": "Filter by account status",
  "全部状态": "All statuses",
  "数据状态": "Data status",
  "连接与额度": "Connection and quota",
  "账户信息": "Account information",
  "连接配置": "Connection configuration",
  "显示与同步": "Visibility and sync",
  "Agent 平台": "Agent platforms",
  "采集来源": "Collection sources",
  "接入范围": "Connection type",
  "全部平台": "All platforms",
  "可直接读额度": "Direct quota readers",
  "通过快照文件": "Via snapshot files",
  "快照文件": "Snapshot file",
  "本机额度连接": "Client quota connection",
  "手动读取额度": "Manual quota read",
  "搜索 Agent 平台": "Search Agent platforms",
  "搜索本机软件": "Search installed apps",
  "搜索采集来源": "Search collection sources",
  "选择一个平台，查看 Windows 支持的连接方式。": "Choose a platform to see the connections supported on Windows.",
  "查看 Agent 账户": "View Agent accounts",
  "账户列表": "Accounts",
  "本周额度": "Weekly quota",
  "更多": "More",
  "返回账户列表": "Back to accounts",
};
const translations = new Map();
let state = null;
let providers = [];
let usageSources = null;
let discovery = null;
let nativeInterface = null;
let page = "overview";
let accountQuery = sessionStorage.getItem("accountQuery") || "";
let selectedAccountID = sessionStorage.getItem("selectedAgentAccount") || "";
let agentFilter = "all";
let overviewFilter = "all";
let catalogTab = "platforms";
let catalogFilter = "all";
let catalogQuery = "";
let operationCount = 0;
let isSyncingAll = false;
let transientMessage = "";
let settingsTab = "module";
let stateRevision = 0;

const actions = new Map();
function action(name, callback) {
  actions.set(name, callback);
}

function inEnglish() {
  const language = state?.settings?.language || "zh-Hans";
  return language === "en" || language === "system" && !navigator.language.toLowerCase().startsWith("zh");
}

function tr(value) {
  return inEnglish() ? supplementalTranslations[value] || translations.get(value) || value : value;
}

function countText(number, chinese, english) {
  return inEnglish() ? `${number} ${english}` : `${number} ${chinese}`;
}

function text(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[character]);
}
function t(value) {
  return text(tr(value));
}

function icon(name, extra = "") {
  const code = icons[name] || icons.info;
  return `<span class="icon ${extra}" aria-hidden="true">&#x${code};</span>`;
}

function button(label, name, { glyph, classes = "", value, disabled = false, iconOnly = false } = {}) {
  return `<button type="button" class="${classes}${iconOnly ? " icon-button" : ""}" data-action="${name}"${value !== undefined ? ` data-value="${text(value)}"` : ""}${disabled ? " disabled" : ""}${iconOnly ? ` aria-label="${t(label)}" title="${t(label)}"` : ""}>${glyph ? icon(glyph) : ""}${iconOnly ? "" : t(label)}</button>`;
}

function menu(label, glyph, body, classes = "", iconOnly = false) {
  return `<details class="menu ${classes}"><summary class="${iconOnly ? "icon-button" : "button"}" title="${t(label)}"${iconOnly ? ` aria-label="${t(label)}"` : ""}>${icon(glyph)}${iconOnly ? "" : t(label)}</summary><div class="menu-items">${body}</div></details>`;
}

function selectOptions(items, value) {
  return items.map(([key, title]) => `<option value="${text(key)}"${String(key) === String(value) ? " selected" : ""}>${t(title)}</option>`).join("");
}

function switchInput(name, title, checked, attribs = "") {
  return `<label class="switch-row"><span>${t(title)}</span><input class="switch" type="checkbox" name="${text(name)}"${checked ? " checked" : ""}${attribs ? " " + attribs : ""}></label>`;
}

function providerFor(id) {
  return providers.find((item) => item.id === id);
}

function providerMark(item, size = 34) {
  const id = item?.id || "";
  const html = `<span class="provider-mark" style="--mark-size:${size}px" aria-hidden="true">${text(item?.mark || id.slice(0, 1).toUpperCase())}`;
  return html + (/^[a-z0-9]+$/.test(id) ? `<img src="/brand/${id}.png" alt="">` : "") + "</span>";
}

document.addEventListener("error", (event) => {
  if (event.target.matches?.(".provider-mark img")) event.target.remove();
}, true);

function externalURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === "https:" ? url.href : "";
  } catch {
    return "";
  }
}

function externalLink(url, label, classes = "") {
  const href = externalURL(url);
  return href ? `<a class="${classes}" href="${text(href)}" target="_blank" rel="noopener noreferrer">${t(label)}</a>` : "";
}

function displayDate(iso) {
  const datetime = new Date(iso);
  if (!iso || !Number.isFinite(datetime.valueOf())) return "—";
  const options = { month: "numeric", day: "numeric", hour: "numeric", minute: "2-digit" };
  try {
    return new Intl.DateTimeFormat(inEnglish() ? "en" : "zh-CN", {
      ...options, timeZone: state?.settings?.timeZone,
    }).format(datetime);
  } catch {
    return new Intl.DateTimeFormat(undefined, options).format(datetime);
  }
}

function number(value) {
  return value === null || value === undefined || !Number.isFinite(Number(value))
    ? "—"
    : Intl.NumberFormat(inEnglish() ? "en" : "zh-CN", { maximumFractionDigits: 2 }).format(Number(value));
}

function money(value, currency) {
  try {
    return Intl.NumberFormat(inEnglish() ? "en" : "zh-CN", { style: "currency", currency }).format(value);
  } catch {
    return `${number(value)} ${currency || ""}`.trim();
  }
}

async function api(path, body) {
  const options = { headers: { "X-Gao-Token": token }, cache: "no-store" };
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!response.ok || payload.ok === false) {
    const error = new Error(payload.error || tr("请求失败"));
    error.code = payload.code;
    throw error;
  }
  if (payload.state) {
    state = payload.state;
    stateRevision += 1;
  }
  return payload;
}

async function downloadFile(path, fileName) {
  const response = await fetch(path, { headers: { "X-Gao-Token": token } });
  if (!response.ok) {
    const payload = await response.json();
    throw new Error(payload.error || tr("下载失败"));
  }
  saveBlob(await response.blob(), fileName);
}

function saveBlob(blob, fileName) {
  const object = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = object;
  anchor.download = fileName;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(object), 60_000);
}

function updateAppearance() {
  const selected = state?.settings?.appearance || "system";
  const appearance = selected === "system" ? (systemTheme.matches ? "dark" : "light") : selected;
  document.documentElement.dataset.appearance = appearance;
  document.documentElement.lang = inEnglish() ? "en" : "zh-Hans";
}

function openDialog(content, style = "") {
  dialog.className = style;
  dialog.innerHTML = content;
  if (!dialog.open) dialog.showModal();
}

function closeDialog() {
  if (dialog.open) dialog.close();
}

dialog.addEventListener("close", () => {
  if (!dialog.open) dialog.innerHTML = "";
});

function showMessage(value = "") {
  transientMessage = value;
  renderMessages();
}

function renderMessages() {
  const value = transientMessage || state?.notice || "";
  message.classList.toggle("hidden", !value);
  message.innerHTML = value ? `<span>${t(value)}</span>${transientMessage ? button("关闭", "dismiss-message", { glyph: "close", iconOnly: true }) : ""}` : "";
}

function accounts() {
  return state?.accounts || [];
}

function activeAccounts() {
  return accounts().filter((account) => account.enabled);
}

function go(nextPage) {
  if (nextPage === "settings") {
    openSettings();
    return;
  }
  if (location.hash === "#" + nextPage) return;
  location.hash = nextPage;
}

function route() {
  const [id, query] = location.hash.slice(1).split("?", 2);
  const aliases = { agent: "agents", usage: "analytics", providers: "catalog" };
  const next = aliases[id] || id;
  if (next === "settings") {
    if (state) openSettings();
    return;
  }
  closeDialog();
  page = routeDefinitions[next] ? next : "overview";
  render();
  window.scrollTo(0, 0);
  const params = new URLSearchParams(query);
  const target = params.get("account");
  if (target) {
    if (page === "agents" && accounts().some((entry) => entry.id === target)) {
      pickAgent(target);
      agentFilter = "all";
      render();
    } else if (page === "overview") {
      overviewFilter = "all";
      render();
    }
    let card = document.getElementById(`account-${target}`);
    if (!card && accountQuery && accounts().some((entry) => entry.id === target)) {
      accountQuery = "";
      sessionStorage.removeItem("accountQuery");
      render();
      card = document.getElementById(`account-${target}`);
    }
    if (card && page === "agents" && matchMedia("(max-width: 850px)").matches) {
      revealInspector();
    } else if (card) {
      card.scrollIntoView({ block: "center" });
      card.focus({ preventScroll: true });
    }
  }
  if (page === "analytics") void loadUsage();
  if (page === "catalog") void loadCatalogTab();
}

function renderNav() {
  const focused = document.activeElement;
  const focusRegion = [navigation, sidebarActions, topActions].find((region) => region.contains(focused));
  const focusAction = focusRegion ? focused.dataset.action : null;
  const focusValue = focusRegion ? focused.dataset.value : null;
  document.querySelector("#brand").textContent = tr("搞词元");
  document.querySelector("#skip-link").textContent = tr("跳到主内容");
  navigation.innerHTML = Object.entries(routeDefinitions).map(([target, definition]) =>
    `<button type="button" data-action="page" data-value="${target}" aria-label="${t(definition[0])}" title="${t(definition[0])}"${page === target ? ' aria-current="page"' : ""}>${icon(definition[2])}<span>${t(definition[0])}</span></button>`
  ).join("");
  sidebarActions.innerHTML = `<button type="button" data-action="settings" aria-label="${t("设置")}" title="${t("设置")}">${icon("settings")}<span>${t("设置")}</span></button>`;
  const canSync = activeAccounts().some((account) => !grokManual(account));
  const syncing = isSyncingAll || state?.refreshing?.length;
  const auto = state?.library?.autoRefresh;
  const syncLabel = syncing ? tr("正在同步") : tr(auto === false ? "自动同步已暂停" : "自动同步");
  workspaceContext.innerHTML = `<span class="agent-count"><span class="status-dot${syncing ? " syncing" : auto === false ? " paused" : ""}"></span>${text(syncLabel)}</span>`;
  topActions.innerHTML = `
    ${button("全部同步", "refresh-all", { glyph: "refresh", disabled: !canSync || !!syncing })}
    ${menu("添加", "plus", [
      button("新建账户", "edit", { value: "openai", glyph: "plus" }),
      button("选择 Agent 平台", "page", { value: "catalog", glyph: "stack" }),
      "<hr>",
      button("导出账户快照 CSV", "export-accounts", { glyph: "download" }),
    ].join(""), "top-add")}
  `;
  if (focusAction && focusRegion) {
    [...focusRegion.querySelectorAll("[data-action]")].find((item) =>
      item.dataset.action === focusAction && item.dataset.value === focusValue)?.focus({ preventScroll: true });
  }
}

function heading(pageInfo) {
  return `<header class="page-heading"><div><h1>${t(pageInfo[0])}</h1><p class="muted">${t(pageInfo[1])}</p></div></header>`;
}

function render() {
  updateAppearance();
  renderNav();
  renderMessages();
  main.setAttribute("aria-busy", String(!state));
  if (!state) return;
  if (state.status === "readonly") {
    main.innerHTML = `${heading(routeDefinitions[page])}<section class="panel"><h2>${t("资料库无法写入")}</h2><p>${t(state.notice)}</p>${button("打开数据目录", "open-data")}</section>`;
    return;
  }
  const contents = { overview: renderOverview, agents: renderAgents, analytics: renderUsage, catalog: renderCatalog };
  main.dataset.page = page;
  main.innerHTML = heading(routeDefinitions[page]) + contents[page]();
}

function metric(title, value, detail, glyph, tone = "") {
  return `<div class="panel metric ${tone}"><div class="metric-heading"><span>${t(title)}</span>${icon(glyph)}</div><strong>${text(value)}</strong><p>${t(detail)}</p></div>`;
}

function tag(title, tone = "accent") {
  return `<span class="tag ${tone}">${t(title)}</span>`;
}

function emptyPanel(title, glyph, description = "", controls = "") {
  return `<section class="panel empty-panel">${icon(glyph)}<h2>${t(title)}</h2>${description ? `<p class="muted">${t(description)}</p>` : ""}${controls}</section>`;
}

function accountSearch() {
  return `<label class="search-field">${icon("search")}<input class="search" id="account-search" type="search" aria-label="${t("搜索软件、账户或套餐")}" placeholder="${t("搜索软件、账户或套餐")}" value="${text(accountQuery)}"></label>`;
}

const healthDisplay = {
  needsAction: ["需处理", "alert", "red"],
  syncPaused: ["暂未同步", "pause", "amber"],
  historical: ["历史数据", "time", "secondary"],
  ok: ["正常", "check", "teal"],
  paused: ["已暂停", "pause", "secondary"],
};

function agentHealth(account) {
  return account.enabled ? (Object.hasOwn(healthDisplay, account.health) ? account.health : "ok") : "paused";
}

function statusMark(level) {
  const [label, glyph, tone] = healthDisplay[level];
  return `<span class="health-label ${tone}">${icon(glyph)}<span>${t(label)}</span></span>`;
}

function overviewCounts(active) {
  const counts = { needsAction: 0, syncPaused: 0, historical: 0, ok: 0 };
  for (const account of active) counts[agentHealth(account)] += 1;
  return counts;
}

function overviewStatus(active, counts) {
  const latest = Math.max(0, ...active.map((account) => Date.parse(account.lastAttempt) || 0));
  return `<aside class="panel overview-status" aria-label="${t("账户状态")}">
    <div class="section-heading"><h2>${t("账户状态")}</h2>
      <span class="muted caption">${text(countText(active.length, "个已启用", "enabled"))}</span>
    </div>
    <div class="health-rows">${Object.entries(counts).map(([level, count]) => `<button type="button" data-action="health-target" data-value="${level}" aria-pressed="${level === overviewFilter}"${count ? "" : " disabled"}>
      ${statusMark(level)}<strong>${number(count)}</strong>${icon("chevron")}
    </button>`).join("")}</div>
    <div class="last-sync spread"><span>${t("最近同步尝试")}</span><strong>${latest ? text(displayDate(latest)) : t("未同步")}</strong></div>
  </aside>`;
}

function onboardingPanel() {
  const quickStart = ["openai", "claude", "grok"].map(providerFor).filter(Boolean);
  return `<section class="panel onboarding">
    <div class="onboarding-intro">
      <div class="onboarding-mark">${icon("computer")}</div>
      <h2>${t("接入第一个 Agent")}</h2>
      <p class="muted">${t("添加正在使用的 Agent，或接入外部采集器写入的额度快照。")}</p>
      ${button("浏览 Agent 平台", "page", { value: "catalog", glyph: "chevron", classes: "primary" })}
    </div>
    ${quickStart.length ? `<div class="starter-providers">
      <h3>${t("快捷接入")}</h3>
      <div>${quickStart.map((item) => `<button type="button" class="starter-provider" data-action="edit" data-value="${text(item.id)}" aria-label="${t("接入")} ${t(item.agent)}">${providerMark(item, 25)}${t(item.agent)}${icon("plus")}</button>`).join("")}</div>
    </div>` : ""}
  </section>`;
}

function renderOverview() {
  const active = activeAccounts();
  const counts = overviewCounts(active);
  const stats = [
    ["已启用 Agent", active.length, "computer", ""],
    ["已接入平台", new Set(accounts().map((account) => account.provider)).size, "stack", ""],
    ["需处理", counts.needsAction, "alert", counts.needsAction ? "red" : ""],
  ];
  return `
    <dl class="panel overview-metrics">${stats.map(([label, value, glyph, tone]) => `<div class="${tone}"><dt>${icon(glyph)}${t(label)}</dt><dd>${number(value)}</dd></div>`).join("")}</dl>
    <div class="overview-grid">
      ${!accounts().length ? onboardingPanel() : `<section class="overview-quota">
        <div class="section-heading">
          <h2>${t("额度概览")}</h2>
          ${accountSearch()}
        </div>
        <div id="overview-filter" class="${overviewFilter === "all" ? "hidden" : "cluster"}">${overviewFilterMarkup()}</div>
        <div id="account-grid" class="overview-accounts">${renderOverviewAccounts()}</div>
      </section>`}
      ${overviewStatus(active, counts)}
    </div>`;
}

function overviewFilterMarkup() {
  return overviewFilter === "all" ? "" : statusMark(overviewFilter) + button("全部状态", "health-target", { value: "all", classes: "plain" });
}

function accountsMatching(candidates) {
  const needle = accountQuery.toLocaleLowerCase().trim();
  return candidates.filter((account) => {
    const item = providerFor(account.provider);
    return [account.name, account.plan, account.provider, item?.name, item?.agent].some((part) =>
      String(part ?? "").toLocaleLowerCase().includes(needle));
  });
}

function renderOverviewAccounts() {
  const latest = (account) => Date.parse(account.lastQuotaChangedAt || account.snapshot?.observedAt) || 0;
  const sorted = [...activeAccounts()].sort((left, right) =>
    Number(right.health === "needsAction") - Number(left.health === "needsAction") || latest(right) - latest(left));
  const visible = accountsMatching(sorted).filter((account) => overviewFilter === "all" || agentHealth(account) === overviewFilter);
  if (visible.length) return visible.map((account) => renderAccount(account)).join("");
  const filtered = accountQuery.trim() || overviewFilter !== "all";
  return emptyPanel(filtered ? "没有匹配的 Agent 软件" : "暂无已启用的 Agent 软件", "computer", "",
    !filtered ? button("查看 Agent 账户", "page", { value: "agents" }) : "");
}

function renderAgents() {
  const filterOptions = [["all", "全部状态"], ...Object.entries(healthDisplay).map(([key, [label]]) => [key, label])];
  return `<div class="collection-toolbar">
    <div class="cluster">${accountSearch()}
      <label class="filter-field">${icon("filter")}<select id="agent-filter" aria-label="${t("按账户状态筛选")}">${selectOptions(filterOptions, agentFilter)}</select></label>
    </div>
    ${button("添加 Agent 软件", "page", { value: "catalog", glyph: "plus", classes: "primary" })}
  </div>
  <div id="account-grid">${renderAgentWorkspace()}</div>`;
}

function pickAgent(id) {
  selectedAccountID = id;
  if (id) sessionStorage.setItem("selectedAgentAccount", id);
  else sessionStorage.removeItem("selectedAgentAccount");
}

function renderAgentWorkspace() {
  const visible = accountsMatching(accounts()).filter((account) => agentFilter === "all" || agentHealth(account) === agentFilter);
  const selected = visible.find((account) => account.id === selectedAccountID) || visible[0];
  const counts = text(countText(visible.length, "个 Agent 账户", "Agent accounts"));
  const filtered = accountQuery.trim() || agentFilter !== "all";
  return `<div class="agent-layout">
    <section class="panel agent-register" aria-label="${t("Agent 软件")}">
      <div class="section-heading"><h2>${t("账户列表")}</h2><span class="muted caption">${counts}</span></div>
      ${visible.length ? `<div class="agent-table">
        <div class="agent-columns" aria-hidden="true"><span>${t("账户名称")}</span><span>${t("数据状态")}</span><span>${t("剩余")}</span></div>
        ${visible.map((account) => agentRow(account, account.id === selected?.id)).join("")}
      </div>` : emptyPanel(filtered ? "没有匹配的 Agent 软件" : "暂无已接入的 Agent 软件", "computer", "",
        !filtered ? button("选择 Agent 平台", "page", { value: "catalog" }) : "")}
    </section>
    <section class="agent-inspector" id="agent-inspector" aria-label="${t("账户明细")}">
      ${selected ? renderAccount(selected, true) : emptyPanel("暂无可显示的账户", "info", "选一个账户查看额度和连接状态。")}
    </section>
  </div>`;
}

function revealInspector() {
  const inspected = document.querySelector("#agent-inspector article");
  if (inspected) {
    inspected.scrollIntoView({ block: "start" });
    inspected.focus({ preventScroll: true });
  }
}

function agentRow(account, selected) {
  const provider = providerFor(account.provider) || { id: account.provider, agent: account.provider };
  const id = text(account.id);
  const mostConstrained = account.ring?.showsDash || credentialProblem(account) ? "—" : account.ring?.label || "—";
  return `<button type="button" id="account-${id}" class="agent-row agent-columns" data-action="select-agent" data-value="${id}" aria-pressed="${selected}" aria-controls="agent-inspector">
    <span class="marked">${providerMark(provider, 30)}<span class="agent-names"><strong title="${text(account.name)}">${text(account.name)}</strong><small class="muted">${t(provider.agent)}${account.plan ? " · " + text(account.plan) : ""}</small></span></span>
    ${statusMark(agentHealth(account))}
    <span class="agent-remaining${account.ring?.stale ? " muted" : ""}">${text(mostConstrained)}</span>
  </button>`;
}

function grokManual(account) {
  return account.provider === "grok" && account.connection === localConnection;
}

function quotaRow(quota, stale, keepExpired) {
  if (typeof quota.usedPercent !== "number") return "";
  const remaining = Math.max(0, Math.min(100, 100 - quota.usedPercent));
  const expired = quota.resetsAt && Date.parse(quota.resetsAt) <= Date.now();
  const masked = expired && !keepExpired;
  const color = remaining <= (state.library.warningThreshold ?? 20) ? "amber" : "teal";
  const resetText = quota.resetsAt
    ? masked ? tr("重置时间已到，等待新数据") : `${tr("重置")} ${displayDate(quota.resetsAt)}`
    : tr("平台未提供重置时间");
  const estimate = !stale && !expired ? quotaEstimate(quota) : "";
  return `<div class="quota ${color}${stale || expired ? " stale" : ""}">
    <div class="spread"><span title="${text(quota.title)}">${t(quota.title)}</span><strong>${masked ? t("待刷新") : `${Math.trunc(remaining)}% ${t("剩余")}`}</strong></div>
    <progress aria-label="${t(quota.title)}" max="100" value="${remaining}"></progress>
    <div class="spread quota-meta"><span>${text(resetText)}</span>${stale ? `<span class="amber">${t("历史数据")}</span>` : ""}</div>
    ${estimate ? `<p class="quota-meta">${text(estimate)}</p>` : ""}
  </div>`;
}

function quotaEstimate({ usedPercent, resetsAt, windowSeconds }) {
  const reset = Date.parse(resetsAt) / 1000;
  if (!Number.isFinite(reset) || !(usedPercent > 0 && usedPercent < 100) || !(windowSeconds > 0)) return "";
  const elapsed = (Date.now() / 1000 - reset + windowSeconds) / windowSeconds;
  if (elapsed < 0.03 || elapsed > 1) return "";
  const untilEmpty = (100 - usedPercent) / usedPercent * elapsed * windowSeconds;
  if (untilEmpty >= (1 - elapsed) * windowSeconds || untilEmpty > 7200) return "";
  const duration = untilEmpty < 3600
    ? countText(Math.max(5, Math.round(untilEmpty / 300) * 5), "分钟后", "min")
    : countText(Math.round(untilEmpty / 1800) / 2, "小时后", "h");
  return inEnglish() ? `Estimated to run out in ${duration} at the current rate` : `按当前速率约 ${duration}耗尽（估算）`;
}

function credentialProblem(account) {
  return account.errorIsCredential || account.errorCode === "credential"
    || /密钥无效|登录(?:态)?已过期|凭证已被拒绝|凭据失效|会话已过期|缺少会话项/.test(account.error || "");
}

function renderSnapshot(account) {
  const snapshot = account.snapshot;
  if (credentialProblem(account)) {
    return `<p class="info-row amber">${icon("key")}${t("凭证已失效，重新连接前不展示旧读数。")}</p>`;
  }
  if (grokManual(account) && !account.ring?.showsDash && Number.isFinite(account.ring?.remainingPercent)) {
    const ring = account.ring;
    const color = ring.remainingPercent <= (state.library.warningThreshold ?? 20) ? "amber" : "teal";
    return `<div class="quota ${color}${ring.stale ? " stale" : ""}"><div class="spread">
      <span>${t("本周额度")}</span><strong>${text(ring.label)} ${t("剩余")}</strong></div>
      <progress max="100" value="${ring.remainingPercent}" aria-label="${t("本周额度")}"></progress>
      ${ring.stale ? `<p class="quota-meta">${t("历史数据")}</p>` : ""}
    </div>`;
  }
  if (!snapshot) {
    return `<div class="no-quota"><span>—</span><p>${t("尚未获取额度")}</p><p class="caption muted">${t("连接后读取真实数据，不预填额度。")}</p></div>`;
  }
  const quotas = (snapshot.quotas || []).filter((quota) => !String(quota.id).includes("status") && !/运行中|未启动/.test(quota.title));
  const keepExpired = !!account.keepsSnapshotOnError || !!account.error
    && (account.provider === "gemini" || account.provider === "openai" && account.connection === "本机 Codex");
  const unexpired = quotas.filter((quota) => !quota.resetsAt || Date.parse(quota.resetsAt) > Date.now());
  const shown = keepExpired ? quotas : unexpired;
  const creditRows = (snapshot.creditBalances || []).map((credit) => `<div class="spread"><span class="muted">${t(credit.title)}</span><strong>${text(number(credit.value))} ${text(credit.unit)}</strong></div>`);
  const balanceLabel = account.provider === "dsh" ? "钱包余额" : account.provider === "workbuddy" ? "积分余额" : "账户余额";
  const balances = (snapshot.balances || []).map((balance) =>
    `<div class="spread money-row"><span class="muted">${t(balanceLabel)}</span><strong>${text(account.provider === "workbuddy" ? number(balance.value) : money(balance.value, balance.currency))}</strong></div>`);
  const costs = (snapshot.costs || []).map((cost) =>
    `<div class="spread"><span class="muted">${t("统计期费用")}</span><strong>${text(money(cost.value, cost.currency))}</strong></div>`);
  const note = snapshot.note || "";
  const noteMarkup = note.length > 40
    ? `<details class="detail-note"><summary>${t("采集说明")}</summary><p>${t(note)}</p></details>`
    : note ? `<p class="caption muted">${t(note)}</p>` : "";
  return [
    shown.map((quota) => quotaRow(quota, account.stale, keepExpired)).join(""),
    ...creditRows, ...balances, ...costs,
    !shown.length && quotas.length ? `<p class="caption muted">${t("上一计费周期已结束，等待平台新读数。")}</p>` : "",
    !quotas.length && !creditRows.length && !balances.length && !costs.length ? `<p class="muted">${t("— 尚未读取到额度")}</p>` : "",
    noteMarkup,
    `<p class="caption-small muted">${account.stale ? t("数据截至") + " " + text(displayDate(snapshot.observedAt)) + " · " + text(snapshot.source) : text(snapshot.source) + " · " + text(displayDate(snapshot.observedAt))}</p>`,
  ].join("");
}

function renderAccount(account, inspector = false) {
  const provider = providerFor(account.provider) || { id: account.provider, agent: account.provider };
  const connection = provider.connectionDetails?.[account.connection]?.label || account.connection;
  const status = account.grokStatus || account.statusNote;
  const id = text(account.id);
  const syncing = state?.refreshing?.includes(account.id);
  return `<article id="${inspector ? "inspecting" : "account"}-${id}" class="panel account-card${inspector ? " inspected-account" : ""}" data-health="${agentHealth(account)}" tabindex="-1">
    ${inspector ? `<div class="section-heading inspector-heading"><h2>${t("账户明细")}</h2><div class="cluster">
      ${statusMark(agentHealth(account))}
      ${button("返回账户列表", "return-agent-list", { glyph: "left", classes: "return-agent-list plain" })}
    </div></div>` : ""}
    <div class="spread account-header"><div class="marked">${providerMark(provider, inspector ? 43 : 36)}<div>
      <h2 title="${text(account.name)}">${text(account.name)}</h2>
      <p class="caption muted">${t(provider.agent)}${account.plan ? " · " + text(account.plan) : ""}</p></div></div>
      ${menu("更多", "more", [
        inspector ? "" : button("账户设置", "edit", { value: account.id }),
        inspector ? "" : externalLink(provider.url, "打开官方控制台"),
        inspector ? "" : "<hr>",
        button("移除账户", "remove", { value: account.id, classes: "red" }),
      ].join(""), "", true)}
    </div>
    <div class="cluster tags">
      ${!inspector ? statusMark(agentHealth(account)) : ""}
      ${tag(account.enabled ? connection : "已暂停", "secondary")}
      ${account.autoDiscovered ? tag("自动发现", "teal") : ""}
    </div>
    <div class="account-reading">
      ${inspector ? `<h3>${t("连接与额度")}</h3>` : ""}
      ${renderSnapshot(account)}
      ${status ? `<p class="info-row muted">${icon("info")}${t(status)}</p>` : ""}
      ${account.error ? `<p class="info-row amber">${icon("alert")}${t(account.error)}</p>` : ""}
    </div>
    <div class="spread account-foot">
      <div class="cluster">
        ${button(syncing ? "同步中…" : grokManual(account) ? "读取本机额度" : "立即同步", grokManual(account) ? "grok" : "refresh", { value: account.id, glyph: "refresh", disabled: !account.enabled || syncing })}
        ${inspector ? button("账户设置", "edit", { value: account.id }) : ""}
      </div>
      ${inspector ? externalLink(provider.url, "控制台 ↗", "muted caption") : button("账户明细", "inspect-account", { value: account.id, glyph: "chevron", classes: "plain" })}
    </div>
  </article>`;
}

const catalogTabs = [
  ["platforms", "Agent 平台", "stack", "搜索 Agent 平台"],
  ["discovery", "本机软件发现", "computer", "搜索本机软件"],
  ["sources", "采集来源", "chart", "搜索采集来源"],
];

function renderCatalog() {
  const currentTab = catalogTabs.find(([key]) => key === catalogTab);
  return `<div class="catalog-workspace">
    <nav class="workspace-tabs" aria-label="${t("平台接入")}">
      ${catalogTabs.map(([key, label, glyph]) => `<button type="button" data-action="catalog-tab" data-value="${key}"${catalogTab === key ? ' aria-current="page"' : ""}>${icon(glyph)}${t(label)}</button>`).join("")}
    </nav>
    <div class="collection-toolbar">
      <div class="cluster">
        <label class="search-field">${icon("search")}<input class="search catalog-search" id="catalog-search" type="search" aria-label="${t(currentTab[3])}" placeholder="${t(currentTab[3])}" value="${text(catalogQuery)}"></label>
        ${catalogTab === "platforms" ? `<label class="filter-field">${icon("filter")}<select id="catalog-filter" aria-label="${t("接入范围")}">${selectOptions([
          ["all", "全部平台"], ["direct", "可直接读额度"], ["snapshot", "通过快照文件"],
        ], catalogFilter)}</select></label>` : ""}
      </div>
      ${catalogTab === "sources" ? button("采集设置", "usage-settings", { glyph: "settings", classes: "primary" }) : ""}
      ${catalogTab === "discovery" ? button("刷新检测", "discover", { glyph: "refresh" }) : ""}
    </div>
    <div id="catalog-content">${catalogTabMarkup()}</div>
  </div>`;
}

function discoverableProvider(item) {
  return item.creatable && !item.removed;
}

function providerCards() {
  const needle = catalogQuery.trim().toLocaleLowerCase();
  const entries = providers.filter(discoverableProvider).map((item) => {
    const modes = Object.values(item.connectionDetails || {}).map((details) => details.mode);
    return [item, modes.includes("connector") ? "connector" : modes.includes("grokbot") ? "grokbot" : "snapshot"];
  });
  const found = entries.filter(([item, route]) =>
    (catalogFilter === "all" || (catalogFilter === "snapshot" ? route === "snapshot" : route !== "snapshot"))
    && `${item.name} ${item.agent} ${item.company} ${item.id}`.toLocaleLowerCase().includes(needle));
  const assigned = new Set(accounts().map((account) => account.provider));
  const labels = { connector: "本机额度连接", grokbot: "手动读取额度", snapshot: "快照文件" };
  return `<section class="panel catalog-list" id="catalog-providers" aria-label="${t("Agent 平台")}">
    <div class="section-heading"><div class="stacked"><h2>${t("Agent 平台")}</h2><p class="muted caption">${t("选择一个平台，查看 Windows 支持的连接方式。")}</p></div><span class="muted caption">${text(countText(found.length, "个平台", "platforms"))}</span></div>
    ${found.length ? found.map(([item, route]) => `<article class="catalog-row">
      <div class="marked">${providerMark(item, 37)}
        <div class="stacked"><h3>${t(item.agent)}</h3><p class="muted caption">${t(item.company)}${assigned.has(item.id) ? ` · ${t("已接入")}` : ""}</p></div>
      </div>
      <p class="caption muted catalog-note">${t(item.note)}</p>
      <div class="catalog-row-actions">${tag(labels[route], route === "snapshot" ? "secondary" : "teal")}${button("接入", "edit", { value: item.id, glyph: "chevron" })}</div>
    </article>`).join("") : `<p class="muted catalog-empty">${t("未找到匹配的 Agent 软件。")}</p>`}
  </section>`;
}

function renderDiscovery() {
  const needle = catalogQuery.trim().toLocaleLowerCase();
  const rows = (discovery?.observations || []).filter((item) =>
    `${item.softwareName} ${item.provider} ${item.status}`.toLocaleLowerCase().includes(needle));
  return `<section class="panel catalog-list discovery-inner" id="discovery">
    <div class="section-heading"><div class="stacked"><h2>${t("本机 Agent 软件状态")}</h2>
      <p class="muted caption">${t("自动检测实际安装的软件和 CLI；账户配置不会被当作软件安装记录。")}</p></div>
      <span class="muted caption">${text(countText(rows.length, "个已发现", "detected"))}</span></div>
    ${discovery?.error ? `<p class="red" role="alert">${text(discovery.error)}</p>` : ""}
    ${rows.length ? `<div class="discovery-list">${rows.map((item) => `<div class="discovered">
      ${providerMark(providerFor(item.provider), 32)}<div><strong>${t(item.softwareName)}</strong><p class="${item.isRunning ? "teal" : "muted"}">${t(item.status)}</p></div><span class="spacer"></span>
      ${!accounts().some((account) => account.provider === item.provider) && providerFor(item.provider)?.creatable ? button("接入", "discovery-add", { value: item.id }) : ""}
    </div>`).join("")}</div>` : `<p class="catalog-empty muted">${t(needle ? "未找到匹配的 Agent 软件。" : discovery ? "暂未检测到本机已安装的 Agent 软件（如 Codex、Claude Code、Antigravity 等）。" : "等待读取软件安装状态…")}</p>`}
  </section>`;
}

function sourceCards() {
  if (!usageSources) return `<p class="panel muted">${t("正在读取本机资料…")}</p>`;
  const needle = catalogQuery.trim().toLocaleLowerCase();
  const selected = new Set(usageSources.engine?.enabledClientIDs || []);
  const sources = usageSources.sources || [];
  const matching = sources.filter((item) => `${item.name} ${item.id}`.toLocaleLowerCase().includes(needle));
  return `<section class="panel catalog-list" id="source-cards">
    <div class="section-heading"><div class="stacked"><h2>${t("采集来源")}</h2><p class="caption muted">${t("只分析 Agent 软件留下的 Token、模型和会话记录；没有日志时不显示成零用量。")}</p></div><span class="caption muted">${text(countText(matching.length, "类来源", "sources"))}</span></div>
    ${matching.map((item) => `<article class="source-row">
      <div class="marked">${icon("terminal")}<h3>${t(item.name)}</h3></div>
      <p class="caption muted" title="${text((item.paths || []).join(" · "))}">${text((item.paths || []).join(" · "))}</p>
      ${tag(item.supported === false ? "该采集源暂不支持 Windows" : selected.has(item.id) ? "已选择采集" : "未选择采集", selected.has(item.id) && item.supported !== false ? "teal" : "secondary")}
    </article>`).join("") || `<p class="catalog-empty muted">${t("未找到匹配的本地用量来源。")}</p>`}
  </section>`;
}

function catalogTabMarkup() {
  if (catalogTab === "discovery") return renderDiscovery();
  if (catalogTab === "sources") return sourceCards();
  return providerCards();
}

function refreshCatalogContent() {
  const target = document.querySelector("#catalog-content");
  if (page === "catalog" && target) target.innerHTML = catalogTabMarkup();
}

async function loadCatalogTab() {
  if (catalogTab === "sources" && !usageSources) await refreshSourceCards();
  if (catalogTab !== "discovery" || discovery) return;
  try {
    discovery = await api("/api/discovery");
  } catch (error) {
    discovery = { error: error.message };
  }
  if (catalogTab === "discovery") refreshCatalogContent();
}

async function refreshSourceCards() {
  try {
    usageSources = await api("/api/usage/settings");
    if (catalogTab === "sources") refreshCatalogContent();
  } catch (error) {
    const target = document.querySelector("#catalog-content");
    if (catalogTab === "sources" && target) target.innerHTML = `<p class="panel red" role="alert">${text(error.message)}</p>`;
  }
}

function editorField(label, control) {
  return `<label class="field"><span>${t(label)}</span>${control}</label>`;
}

function editorHeading(title, kicker = "") {
  return `<header class="dialog-head"><div><h2 id="dialog-title">${t(title)}</h2>${kicker ? `<p class="muted">${t(kicker)}</p>` : ""}</div>
    ${button("关闭", "close-dialog", { glyph: "close", iconOnly: true })}</header>`;
}

function publicAccount(account) {
  return Object.fromEntries([
    "id", "provider", "connection", "name", "plan", "filePath", "enabled", "budget",
    "currency", "showInRail", "scopeID", "region", "autoDiscovered", "balanceBasis", "baselines",
  ].map((key) => [key, account[key]]));
}

function draftFor(provider) {
  return {
    provider: provider.id,
    connection: provider.defaultConnection || provider.connections[0],
    name: provider.defaultName, plan: "", filePath: "", currency: "USD", enabled: true, showInRail: true,
  };
}

function openEditor(account, defaultProvider, overrideConnection) {
  let provider = providerFor(account?.provider || defaultProvider);
  if (!provider) return;
  let draft = account ? publicAccount(account) : draftFor(provider);
  if (overrideConnection && provider.connections.includes(overrideConnection)) draft.connection = overrideConnection;
  const original = account;
  const availableProviders = providers.filter((item) => discoverableProvider(item) || item.id === account?.provider);
  const providerOptions = () => selectOptions(availableProviders.map((item) => [item.id, item.name]), provider.id);
  const draw = () => {
    const current = provider.connectionDetails?.[draft.connection] || {};
    const options = provider.connections.map((item) => [item, provider.connectionDetails?.[item]?.label || item]);
    if (draft.connection && !options.some(([id]) => id === draft.connection)) options.push([draft.connection, draft.connection]);
    const regions = (current.regions || []).map((item) => Array.isArray(item) ? item : [item.id || item.value, item.label || item.name]);
    const isFile = draft.connection === fileConnection || current.mode === "file";
    const isClaudeStatus = draft.connection === "Claude Code 状态栏推送";
    const showSecret = !!current.credentialLabel && current.mode !== "unsupported";
    const savedSecret = original?.hasCredential && original.connection === draft.connection;
    const pathLabel = current.pathLabel || "Windows 快照文件路径";
    openDialog(`<header class="dialog-head editor-title">
        <div class="marked">${providerMark(provider, 42)}<div><h2 id="dialog-title">${t(original ? "账户设置" : "新建账户")}</h2><p class="muted">${t(provider.agent)}</p></div></div>
        ${button("关闭", "close-dialog", { glyph: "close", iconOnly: true })}
      </header>
      <form id="account-editor">
        <div class="dialog-body editor-body">
          <section class="editor-section">
            <h3>${t("账户信息")}</h3>
            ${editorField("平台", `<select name="provider"${original ? " disabled" : ""}>${providerOptions()}</select>`)}
            ${editorField("账户名称", `<input name="name" value="${text(draft.name)}" required>`)}
            ${editorField("套餐 / 组织备注", `<input name="plan" value="${text(draft.plan)}" placeholder="${t("如 Plus、Pro、Max、Coding Plan")}">`)}
          </section>
          <section class="editor-section">
            <h3>${t("连接配置")}</h3>
            ${editorField("连接方式", `<select name="connection">${selectOptions(options, draft.connection)}</select>`)}
            ${current.scopeLabel ? editorField(current.scopeLabel, `<input name="scopeID" value="${text(draft.scopeID)}">`) : ""}
            ${regions.length ? editorField("服务地区", `<select name="region">${selectOptions(regions, draft.region)}</select>`) : ""}
            ${showSecret ? editorField(current.credentialLabel, `<input name="secret" type="password" autocomplete="new-password"${savedSecret ? ` placeholder="${t("留空保留已存密钥")}"` : " required"}>`) : ""}
            ${showSecret && savedSecret ? `<p class="caption muted">${t("已保存凭据")}</p>` : ""}
            ${isFile || current.pathLabel ? `<div class="editor-path">
              ${editorField(pathLabel, `<input name="filePath" value="${text(draft.filePath)}" placeholder="${isFile ? "C:\\…\\snapshot.json" : "C:\\…\\codex.exe"}"${isFile ? " required" : ""}>`)}
              ${isFile ? button("选择…", "pick-snapshot", { glyph: "folder" }) : ""}</div>` : ""}
            ${current.help ? `<p class="caption muted connection-help">${t(current.help)}</p>` : ""}
            ${isClaudeStatus ? claudeSetupMarkup() : ""}
            ${isFile ? `<p class="caption muted">${t("读取标准 JSON 快照，不是任意平台原始账单。格式示例见设置页，可由外部脚本持续更新。")}</p>` : ""}
            <div class="editor-test">${button("测试连接", "test-account", { glyph: "link", disabled: current.mode === "unsupported" || current.mode === "grokbot" })}<p id="editor-result" class="caption" role="status"></p></div>
          </section>
          <section class="editor-section">
            <h3>${t("显示与同步")}</h3>
            <div class="editor-switches">
              ${switchInput("showInRail", "显示在悬浮条", draft.showInRail)}
              ${switchInput("enabled", "启用此账户", draft.enabled)}
            </div>
          </section>
          <p id="editor-error" class="red" role="alert"></p>
        </div>
        <footer class="dialog-foot">${button("取消", "close-dialog")}<button type="submit" class="primary">${t("保存账户")}</button></footer>
      </form>`, "account-dialog");
    const form = dialog.querySelector("form");
    form.addEventListener("change", (event) => {
      const field = event.target.name;
      if (field === "provider") {
        provider = providerFor(event.target.value);
        draft = draftFor(provider);
        draw();
        dialog.querySelector('[name="provider"]').focus();
      } else if (field === "connection") {
        draft = { ...readDraft(form), filePath: "", scopeID: null, region: null, secret: undefined };
        draw();
        dialog.querySelector('[name="connection"]').focus();
      }
    });
    form.addEventListener("submit", async (event) => {
      event.preventDefault();
      const submit = event.submitter;
      if (submit) submit.disabled = true;
      try {
        const outgoing = readDraft(form);
        const { result } = await api("/api/accounts/save", outgoing);
        if (outgoing.enabled && outgoing.connection === fileConnection) {
          await api("/api/accounts/refresh", { id: result.id });
        }
        if (result?.id && page === "agents") {
          pickAgent(result.id);
          agentFilter = "all";
        }
        closeDialog();
        if (result?.id && !original && page === "catalog") {
          location.hash = "agents?account=" + encodeURIComponent(result.id);
          return;
        }
        render();
        if (result?.id) document.getElementById(`account-${result.id}`)?.focus({ preventScroll: true });
      } catch (error) {
        form.querySelector("#editor-error").textContent = error.message;
      } finally {
        if (submit) submit.disabled = false;
      }
    });
  };
  function readDraft(form) {
    const { elements } = form;
    const accountDraft = {
      ...draft,
      provider: provider.id,
      name: elements.name.value.trim(),
      plan: elements.plan.value.trim(),
      connection: elements.connection.value,
      filePath: elements.filePath?.value.trim() || "",
      scopeID: elements.scopeID?.value.trim() || draft.scopeID,
      region: elements.region?.value || draft.region,
      enabled: elements.enabled.checked,
      showInRail: elements.showInRail.checked,
    };
    if (elements.secret?.value.trim()) accountDraft.secret = elements.secret.value;
    return accountDraft;
  }
  dialog.editorDraft = readDraft;
  draw();
}

function setEditorError(error) {
  const target = dialog.querySelector("#editor-error");
  if (target) target.textContent = error.message;
}

function claudeSetupMarkup() {
  const executable = nativeInterface?.cliPath?.replaceAll("\\", "/") || "GaoCiYuan-cli.exe";
  const configuration = JSON.stringify({
    statusLine: { type: "command", command: '"' + executable + '" --capture-claude-status' },
  }, null, 2);
  return `<details class="disclosure claude-setup"><summary>${t("状态栏配置示例")}</summary>
    <p class="caption muted">${t("将下方 statusLine 字段合并到 Claude Code 的用户设置。若已使用自定义状态栏，请把接收命令加入现有脚本，并让它读取相同的标准输入。")}</p>
    <pre id="claude-setup-code">${text(configuration)}</pre>
    ${button("复制配置示例", "copy-claude")}</details>`;
}

action("page", (button) => go(button.dataset.value));
action("settings", () => openSettings());
action("close-dialog", closeDialog);
action("dismiss-message", () => showMessage());
action("open-data", () => api("/api/open/data", {}));
action("copy-claude", async () => {
  const configuration = dialog.querySelector("#claude-setup-code");
  if (configuration) await navigator.clipboard.writeText(configuration.textContent);
});
action("edit", (button) => {
  const value = button.dataset.value;
  openEditor(accounts().find((item) => item.id === value), value);
});

action("export-accounts", () => downloadFile("/api/export/accounts.csv", "GaoCiYuan-accounts.csv"));
action("health-target", (button) => {
  const requested = button.dataset.value;
  overviewFilter = requested === overviewFilter ? "all" : requested;
  for (const control of main.querySelectorAll(".health-rows button")) {
    control.setAttribute("aria-pressed", String(control.dataset.value === overviewFilter));
  }
  const applied = document.querySelector("#overview-filter");
  if (applied) {
    applied.classList.toggle("hidden", overviewFilter === "all");
    applied.classList.toggle("cluster", overviewFilter !== "all");
    applied.innerHTML = overviewFilterMarkup();
  }
  refreshAccountArea();
});

action("select-agent", (trigger) => {
  pickAgent(trigger.dataset.value);
  refreshAccountArea();
  if (matchMedia("(max-width: 850px)").matches) revealInspector();
  else document.getElementById(`account-${selectedAccountID}`)?.focus({ preventScroll: true });
});
action("return-agent-list", () => {
  const current = document.querySelector(".agent-row[aria-pressed='true']");
  if (current) {
    current.scrollIntoView({ block: "start" });
    current.focus({ preventScroll: true });
  }
});
action("inspect-account", (trigger) => {
  location.hash = "agents?account=" + encodeURIComponent(trigger.dataset.value);
});
action("catalog-tab", (trigger) => {
  const requested = trigger.dataset.value;
  if (catalogTab === requested) return;
  catalogTab = requested;
  catalogQuery = "";
  render();
  main.querySelector('[data-action="catalog-tab"][aria-current]')?.focus({ preventScroll: true });
  return loadCatalogTab();
});

action("refresh-all", async () => {
  isSyncingAll = true;
  renderNav();
  try {
    await api("/api/accounts/refresh-all", {});
  } finally {
    isSyncingAll = false;
    render();
  }
});

async function refreshAccount(button, manualGrok) {
  const oldHTML = button.innerHTML;
  button.disabled = true;
  button.innerHTML = icon("refresh") + t("同步中…");
  try {
    await api(manualGrok ? "/api/grokbot/read" : "/api/accounts/refresh", { id: button.dataset.value });
    render();
  } finally {
    if (button.isConnected) {
      button.disabled = false;
      button.innerHTML = oldHTML;
    }
  }
}
action("refresh", (button) => refreshAccount(button, false));
action("grok", (button) => refreshAccount(button, true));

action("remove", (trigger) => {
  const id = trigger.dataset.value;
  openDialog(`${editorHeading("移除 Agent 软件？")}<div class="dialog-body"><p>${t("将移除该软件在本机的额度快照和专属凭据，不影响平台上的账号。")}</p></div>
    <footer class="dialog-foot">${button("取消", "close-dialog")}${button("移除", "confirm-remove", { value: id, classes: "danger" })}</footer>`, "small-dialog");
});

action("confirm-remove", async (button) => {
  button.disabled = true;
  try {
    await api("/api/accounts/delete", { id: button.dataset.value });
    closeDialog();
    render();
  } finally {
    button.disabled = false;
  }
});

action("test-account", async (button) => {
  const form = dialog.querySelector("form");
  if (!form.reportValidity()) return;
  const result = dialog.querySelector("#editor-result");
  button.disabled = true;
  result.textContent = tr("测试中…");
  result.className = "caption";
  try {
    const payload = await api("/api/accounts/test", dialog.editorDraft(form));
    const details = payload.result || payload;
    result.textContent = tr(details.message || details.note || "连接成功 ✓");
    result.classList.add(details.supported === false || details.ok === false ? "amber" : "teal");
  } catch (error) {
    result.textContent = error.message;
    result.classList.add("red");
  } finally {
    button.disabled = false;
  }
});

action("pick-snapshot", async () => {
  try {
    const { result } = await api("/api/choose/snapshot", {});
    const filePath = dialog.querySelector('[name="filePath"]');
    if (result?.path && filePath) filePath.value = result.path;
  } catch (error) {
    setEditorError(error);
  }
});

action("discover", async (button) => {
  button.disabled = true;
  try {
    discovery = await api("/api/discovery?rescan=1");
  } catch (error) {
    discovery = { error: error.message };
  } finally {
    button.disabled = false;
  }
  if (catalogTab === "discovery") refreshCatalogContent();
});

action("discovery-add", (button) => {
  const observed = discovery?.observations?.find((item) => String(item.id) === button.dataset.value);
  if (!observed) return;
  openEditor(null, observed.provider, observed.defaultConnection);
});

document.addEventListener("click", async (event) => {
  const button = event.target.closest("[data-action]");
  for (const item of document.querySelectorAll(".menu[open]")) {
    if (button?.closest(".menu") === item || !item.contains(event.target)) item.open = false;
  }
  if (!button || button.disabled) return;
  const callback = actions.get(button.dataset.action);
  if (!callback) return;
  operationCount += 1;
  try {
    await callback(button);
  } catch (error) {
    showMessage(error.message);
  } finally {
    operationCount -= 1;
  }
});

function refreshAccountArea() {
  const target = document.querySelector("#account-grid");
  if (target) target.innerHTML = page === "agents" ? renderAgentWorkspace() : renderOverviewAccounts();
}

document.addEventListener("input", (event) => {
  if (event.target.id === "account-search") {
    accountQuery = event.target.value;
    sessionStorage.setItem("accountQuery", accountQuery);
    refreshAccountArea();
  } else if (event.target.id === "catalog-search") {
    catalogQuery = event.target.value;
    refreshCatalogContent();
  }
});

document.addEventListener("change", (event) => {
  if (event.target.id === "agent-filter") {
    agentFilter = event.target.value;
    refreshAccountArea();
  } else if (event.target.id === "catalog-filter") {
    catalogFilter = event.target.value;
    refreshCatalogContent();
  }
});

document.querySelector("#skip-link").addEventListener("click", (event) => {
  event.preventDefault();
  main.focus();
});
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || dialog.open) return;
  const opened = document.querySelector(".menu[open]");
  if (!opened) return;
  opened.open = false;
  opened.querySelector("summary")?.focus();
});
systemTheme.addEventListener("change", updateAppearance);
window.addEventListener("hashchange", route);

async function boot() {
  try {
    const [initial, providerList, dictionary, native] = await Promise.all([
      api("/api/state"), api("/api/catalog"),
      fetch("/translations.tsv").then((response) => response.ok ? response.text() : "").catch(() => ""),
      api("/api/native").catch(() => null),
    ]);
    for (const entry of dictionary.split(/\r?\n/)) {
      const [key, value] = entry.split("\t", 2);
      if (value) translations.set(key, value);
    }
    state = initial;
    providers = providerList.providers || [];
    nativeInterface = native;
    if (!state.persisted && state.status === "ready") {
      try {
        await api("/api/library/create", {});
      } catch (error) {
        if (error.code !== "exists") throw error;
        state = await api("/api/state");
      }
    }
    route();
    if (!main.querySelector("h1")) render();
  } catch (error) {
    main.setAttribute("aria-busy", "false");
    showMessage(error.message);
  }
}

window.addEventListener("DOMContentLoaded", () => {
  void boot();
  setInterval(async () => {
    if (!state || operationCount || dialog.open || document.hidden || document.querySelector(".menu[open]")) return;
    const revision = stateRevision;
    try {
      const current = await api("/api/state");
      if (revision !== stateRevision || operationCount || dialog.open || document.querySelector(".menu[open]")) return;
      if (JSON.stringify(current) === JSON.stringify(state)) return;
      const focused = document.activeElement;
      const grid = document.querySelector("#account-grid");
      if (grid?.querySelector("details[open]") || (grid?.contains(focused) && !focused.id)) return;
      state = current;
      if (page === "overview" || page === "agents") {
        const selection = focused.id === "account-search" ? [focused.selectionStart, focused.selectionEnd] : null;
        render();
        const replacement = document.getElementById(focused.id);
        if (replacement && replacement !== focused) {
          replacement.focus({ preventScroll: true });
          if (selection) replacement.setSelectionRange(...selection);
        }
      } else {
        renderNav();
      }
    } catch {
      // The window may still be open after the desktop service has stopped.
    }
  }, 12000);
});
