Object.assign(supplementalTranslations, {
  "模块设置": "Module",
  "外观": "Appearance",
  "数据": "Data",
  "同步与提醒": "Sync and alerts",
  "屏幕边缘浮动条": "Screen-edge floating panel",
  "显示浮动条": "Show floating panel",
  "停靠位置": "Dock position",
  "悬浮条布局": "Panel layout",
  "悬浮条显示": "Accounts in panel",
  "额度告警阈值": "Usage alert threshold",
  "低余额提醒": "Low balance alert",
  "连续同步失败时提醒我": "Notify after repeated sync failures",
  "额度用尽时提醒我": "Notify when the platform reports a quota is exhausted",
  "浮动": "Floating",
  "单列": "One column",
  "双列": "Two columns",
  "数据目录": "Data directory",
  "Windows 数据目录": "Windows data directory",
  "Windows x64 应用": "Windows x64 application",
  "模块设置选项卡": "Module settings tab",
  "选择…": "Choose…",
  "设置已保存": "Settings saved",
  "没有配置更新源和签名公钥。": "Add the update feed and signing key to check for updates.",
  "已是当前版本。": "You are up to date.",
  "正在检查…": "Checking…",
  "正在下载并验证…": "Downloading and verifying…",
  "下载并验证": "Download and verify",
  "在资源管理器中显示": "Show in File Explorer",
  "语言": "Language",
  "版本": "Version",
  "时区": "Time zone",
  "连续同步失败达到 3 次时提醒。": "Notify after three consecutive sync failures.",
  "总览和浮动条按剩余额度变色。系统通知的额度告警按已用百分比触发。关闭应用后停止自动同步，手动账户由你发起刷新。": "Remaining quota sets the overview and panel color. System alerts use the percentage already used. Automatic sync stops when the app closes. Manual accounts refresh on request.",
  "空闲时收成屏幕边缘的细条，悬停展开。": "The panel collapses to a narrow strip when idle and expands on hover.",
  "在 Codex 账户设置中可为该连接指定 Codex CLI。": "Choose a Codex CLI executable in the Codex account settings.",
  "在 Claude Code 账户选择状态栏推送连接，并按账户设置中的说明配置官方状态栏命令。": "Choose the status line connection in your Claude Code account and use its setup instructions.",
  "检查仅获取更新元数据；点击下载后才获取安装包并验证签名，不自动安装。": "Checking fetches update metadata. Download verifies the package signature. Installation is manual.",
  "可下载版本": "Available version",
  "账户与用量记录保存在原数据目录。": "Accounts and usage records stay in the existing data directory.",
  "通用 Agent 快照文件": "Agent snapshot file",
  "Agent 软件可连接标准 JSON 快照。外部脚本更新文件后，应用会定时读取；observedAt 表示实际观测时间，不能用刷新时间冒充。": "Agents can use standard JSON snapshots. The app reads changes periodically. Set observedAt to the observation time.",
  "完成": "Done",
  "行为与连接": "Behavior and connections",
  "数据与更新": "Data and updates",
  "显示偏好": "Display preferences",
  "Windows 数据与软件更新": "Windows data and software updates",
  "应用程序": "Application",
  "同步频率由账户活动与平台规则决定。": "Sync frequency follows account activity and platform limits.",
  "已下载，签名验证通过": "Downloaded and signature verified",
  "默认目录": "Default folder",
  "正在保存…": "Saving…",
  "切换数据与更新": "Open data and updates",
});

let settingsQueue = Promise.resolve();
let updateResult = null;
let updateMessage = "";
let updateFile = null;
let updatePhase = "";

function settingsPanel(title, glyph, body) {
  return `<section class="panel settings-panel"><header class="preferences-card-heading"><span>${icon(glyph)}</span><h3>${t(title)}</h3></header><div class="preferences-rows">${body}</div></section>`;
}
function settingsField(label, control) {
  return `<label class="settings-field"><span>${t(label)}</span>${control}</label>`;
}
function settingsSelect(name, title, entries, current) {
  return settingsField(title, `<select name="${text(name)}">${selectOptions(entries, current)}</select>`);
}

function settingsDescription(value) {
  return `<p class="caption muted">${t(value)}</p>`;
}

function settingsActions(...items) {
  return `<div class="cluster preferences-actions">${items.join("")}</div>`;
}

function moduleSettings() {
  const library = state.library || {};
  const settings = state.settings || {};
  const active = activeAccounts();
  const interval = [1, 5, 10, 15, 30, 60];
  if (library.refreshMinutes && !interval.includes(library.refreshMinutes)) interval.push(library.refreshMinutes);
  interval.sort((a, b) => a - b);
  return `<form id="module-settings" class="settings-sections preferences-card-list">
    ${settingsPanel("同步与提醒", "refresh", [
      switchInput("autoRefresh", "应用运行时自动同步", library.autoRefresh),
      switchInput("refreshFixedInterval", "固定间隔同步", settings.refreshFixedInterval),
      settings.refreshFixedInterval ? settingsSelect("refreshMinutes", "同步间隔", interval.map((minutes) => [minutes, countText(minutes, "分钟", "min")]), library.refreshMinutes)
        : settingsDescription("同步频率由账户活动与平台规则决定。"),
      settingsField("剩余额度提醒阈值", `<span class="slider-field"><input name="warningThreshold" type="range" min="5" max="50" step="5" value="${text(library.warningThreshold ?? 20)}"><output>${number(library.warningThreshold ?? 20)}%</output></span>`),
      settingsDescription("总览和浮动条按剩余额度变色。系统通知的额度告警按已用百分比触发。关闭应用后停止自动同步，手动账户由你发起刷新。"),
    ].join(""))}
    ${settingsPanel("屏幕边缘浮动条", "window", [
      switchInput("panelFloating", "显示浮动条", settings.panelFloating !== false),
      settings.panelFloating !== false ? [
        Object.hasOwn(settings, "panelActivityDot") ? switchInput("panelActivityDot", "活跃状态圆点", settings.panelActivityDot) : "",
        Object.hasOwn(settings, "panelHideFullScreen") ? switchInput("panelHideFullScreen", "全屏时隐藏", settings.panelHideFullScreen) : "",
        Object.hasOwn(settings, "panelFollowDisplay") ? switchInput("panelFollowDisplay", "跟随活跃显示器", settings.panelFollowDisplay) : "",
        settingsSelect("panelDock", "停靠位置", [["left", "左"], ["right", "右"], ["top", "顶部"], ["floating", "浮动"]], settings.panelDock || "right"),
        settingsSelect("panelTwoColumns", "悬浮条布局", [["false", "单列"], ["true", "双列"]], Boolean(settings.panelTwoColumns)),
        settingsDescription("空闲时收成屏幕边缘的细条，悬停展开。"),
        active.length ? `<details class="preferences-account-list" data-settings-details="rail"><summary>${t("悬浮条显示")}<span class="muted caption">${active.filter((account) => account.showInRail).length} / ${active.length}</span></summary>
          <div>${active.map((account) => switchInput("rail-account", account.name, account.showInRail, `data-account="${text(account.id)}"`)).join("")}</div></details>` : "",
      ].join("") : "",
    ].join(""))}
    ${settingsPanel("系统通知", "bell", [
      settingsSelect("notifyThreshold", "额度告警阈值", [[0, "关闭"], [75, "75%"], [80, "80%"], [90, "90%"], [95, "95%"]], settings.notifyThreshold ?? 0),
      Object.hasOwn(settings, "notifyOnReset") ? switchInput("notifyOnReset", "窗口重置时提醒我", settings.notifyOnReset) : "",
      switchInput("notifyExhausted", "额度用尽时提醒我", settings.notifyExhausted),
      switchInput("notifyFailures", "连续同步失败时提醒我", settings.notifyFailures),
      settingsField("低余额提醒", `<input type="number" min="0" step="any" name="notifyLowBalance" placeholder="${t("关闭")}" value="${text(settings.notifyLowBalance || "")}">`),
      settingsDescription("按账户币种，余额跌破时提醒；0 或留空为关闭。"),
      settingsDescription("连续同步失败达到 3 次时提醒。"),
    ].join(""))}
    ${settingsPanel("行为与连接", "terminal", [
      Object.hasOwn(settings, "codexPath") ? settingsField("Codex 程序", `<input name="codexPath" placeholder="${t("自动查找已安装的 Codex")}" value="${text(settings.codexPath || "")}">`) : "",
      settingsDescription("在 Codex 账户设置中可为该连接指定 Codex CLI。"),
      `<h4>${t("Claude Code 状态栏推送")}</h4>`,
      settingsDescription("在 Claude Code 账户选择状态栏推送连接，并按账户设置中的说明配置官方状态栏命令。"),
      settingsActions(button("账户设置", "open-claude", { glyph: "right" })),
    ].join(""))}
  </form>`;
}

function appearanceSettings() {
  const settings = state.settings || {};
  return `<form id="appearance-settings" class="settings-sections preferences-card-list">
    ${settingsPanel("显示偏好", "palette", [
      settingsSelect("appearance", "外观", [["system", "跟随系统"], ["light", "浅色"], ["dark", "深色"]], settings.appearance || "system"),
      `<div class="preferences-theme-preview" aria-hidden="true"><div class="theme-sample theme-sample-light"><i></i><i></i><i></i></div><div class="theme-sample theme-sample-dark"><i></i><i></i><i></i></div></div>`,
      settingsSelect("language", "语言", [["system", "跟随系统"], ["zh-Hans", "简体中文"], ["en", "English"]], settings.language || "zh-Hans"),
      settingsField("时区", `<input name="timeZone" value="${text(settings.timeZone || "Asia/Shanghai")}" spellcheck="false">`),
    ].join(""))}
  </form>`;
}

function dataSettings() {
  const settings = state.settings || {};
  return `<form id="data-settings" class="settings-sections preferences-card-list">
    ${settingsPanel("检查更新", "download", [
      settingsField("更新源地址", `<input type="url" name="updateAppcastURL" placeholder="${t("留空则不自动检查")}" value="${text(settings.updateAppcastURL)}" spellcheck="false">`),
      settingsField("签名公钥", `<input name="updatePublicKey" placeholder="Ed25519 · Base64" value="${text(settings.updatePublicKey)}" spellcheck="false">`),
      settingsDescription("检查仅获取更新元数据；点击下载后才获取安装包并验证签名，不自动安装。"),
      settingsActions(button("立即检查", "check-updates", { glyph: "refresh" })),
      `<div id="update-state">${updateStatusMarkup()}</div>`,
    ].join(""))}
    ${settingsPanel("数据目录", "database", [
      `<dl class="preferences-paths"><div><dt>${t("Windows 数据目录")}</dt><dd><code>${text(state.dataDir)}</code></dd></div>
      <div><dt>Grok Bot</dt><dd><code>${text(state.grokbotPath)}</code></dd></div></dl>`,
      settingsActions(button("打开数据目录", "open-data", { glyph: "folder" }), button("导出账户快照 CSV", "export-accounts", { glyph: "download" })),
      `<h4>${t("通用 Agent 快照文件")}</h4>`,
      settingsDescription("Agent 软件可连接标准 JSON 快照。外部脚本更新文件后，应用会定时读取；observedAt 表示实际观测时间，不能用刷新时间冒充。"),
      settingsActions(button("导出快照格式示例…", "snapshot-example", { glyph: "download" })),
    ].join(""))}
    ${settingsPanel("应用程序", "info", `<div class="preferences-version"><span>搞词元 · ${t("Windows x64 应用")}</span><strong>${text(state.version || "4.13")}</strong></div>`)}
  </form>`;
}

function updateStatusMarkup() {
  const available = updateResult?.status === "available";
  const version = updateResult?.version;
  return `${updateMessage ? `<p class="preferences-state ${updatePhase === "error" ? "red" : "muted"}" role="status">${icon(updatePhase === "error" ? "alert" : "info")}${t(updateMessage)}</p>` : ""}
    ${available && !updateFile ? `<div class="preferences-state"><span>${t("可下载版本")} <strong>${text(version)}</strong></span>${button("下载并验证", "download-update", { glyph: "download", classes: "primary" })}</div>` : ""}
    ${updateFile ? `<div class="preferences-state preferences-update-file"><strong class="teal">${icon("checklist")}${t("已下载，签名验证通过")}</strong><code>${text(updateFile)}</code>${button("在资源管理器中显示", "open-updates", { glyph: "folder" })}</div>` : ""}`;
}

function openSettings(tab = settingsTab, preserveScroll = false) {
  if (!state) return;
  settingsTab = tab;
  const scroll = preserveScroll ? dialog.querySelector(".dialog-body")?.scrollTop || 0 : 0;
  const openDetails = preserveScroll && dialog.querySelector('[data-settings-details="rail"]')?.open;
  const tabs = [["module", "模块设置", "settings"], ["appearance", "外观", "palette"], ["data", "数据与更新", "database"]];
  const bodies = { module: moduleSettings, appearance: appearanceSettings, data: dataSettings };
  openDialog(`${editorHeading("设置")}
    <div class="preferences-layout">
      <div class="settings-tabs preferences-tabs" role="tablist" aria-label="${t("设置")}">${tabs.map(([value, title, glyph]) =>
        `<button type="button" role="tab" id="settings-tab-${value}" tabindex="${value === tab ? 0 : -1}" aria-controls="settings-content" aria-selected="${value === tab}" data-action="settings-tab" data-value="${value}">${icon(glyph)}${t(title)}</button>`
      ).join("")}</div>
      <div class="dialog-body settings-body" role="tabpanel" id="settings-content" aria-labelledby="settings-tab-${tab}">${bodies[tab]()}</div>
    </div>
    <footer class="dialog-foot"><p id="settings-status" class="caption muted" role="status"></p>${button("完成", "close-dialog", { classes: "primary" })}</footer>`, "settings-dialog");
  dialog.querySelector(".dialog-body").scrollTop = scroll;
  if (openDetails) dialog.querySelector('[data-settings-details="rail"]')?.setAttribute("open", "");
  dialog.querySelector("form")?.addEventListener("submit", (event) => event.preventDefault());
  if (tab === "data" && !preserveScroll) void syncUpdateState();
}

async function syncUpdateState() {
  const target = dialog.querySelector("#update-state");
  if (!target || updateResult || updateMessage) return;
  try {
    const result = await api("/api/updates");
    if (target.isConnected && !updateResult && !updateMessage && result.status !== "unconfigured") {
      updateResult = result;
      if (result.status === "current") updateMessage = "已是当前版本。";
      target.innerHTML = updateStatusMarkup();
    }
  } catch {
    // A manual check reports errors if the configured feed is inaccessible.
  }
}
function writeSettings(target) {
  const name = target.name;
  let value = target.value.trim();
  if (target.type === "checkbox") value = target.checked;
  else if (["notifyLowBalance", "notifyThreshold", "warningThreshold", "refreshMinutes"].includes(name)) value = Number(value);
  else if (name === "panelTwoColumns") value = value === "true";
  const pending = dialog.querySelector("#settings-status");
  if (pending) {
    pending.classList.remove("red");
    pending.textContent = tr("正在保存…");
  }
  return settingsQueue = settingsQueue.catch(() => {}).then(async () => {
    if (name === "rail-account") {
      const account = accounts().find((item) => item.id === target.dataset.account);
      if (account) await api("/api/accounts/save", { ...publicAccount(account), showInRail: value });
    } else {
      await api("/api/settings", { [name]: value });
    }
    if (["appearance", "language"].includes(name)) render();
    if (dialog.open && dialog.classList.contains("settings-dialog")
      && ["language", "refreshFixedInterval", "panelFloating"].includes(name)) {
      openSettings(settingsTab, true);
      dialog.querySelector(`[name="${name}"]`)?.focus({ preventScroll: true });
    }
    const status = dialog.querySelector("#settings-status");
    if (status) {
      status.classList.remove("red");
      status.textContent = tr("设置已保存");
    }
  });
}

document.addEventListener("input", (event) => {
  const target = event.target;
  if (target.name === "warningThreshold" && target.closest("#module-settings")) {
    target.nextElementSibling.value = target.value + "%";
  }
});

document.addEventListener("change", (event) => {
  const target = event.target;
  if (!target.closest("#module-settings,#appearance-settings,#data-settings") || !target.name) return;
  if (["updateAppcastURL", "updatePublicKey"].includes(target.name)) {
    updateResult = null;
    updateFile = null;
    updateMessage = "";
    updatePhase = "";
    const status = dialog.querySelector("#update-state");
    if (status) status.innerHTML = "";
  }
  writeSettings(target).catch((error) => {
    const status = dialog.querySelector("#settings-status");
    if (status) {
      status.classList.add("red");
      status.textContent = error.message;
    } else {
      showMessage(error.message);
    }
  });
});

function activateSettingsTab(tab) {
  openSettings(tab);
  dialog.querySelector(`#settings-tab-${tab}`)?.focus({ preventScroll: true });
}

action("settings-tab", (button) => activateSettingsTab(button.dataset.value));
dialog.addEventListener("keydown", (event) => {
  const tab = event.target.closest(".preferences-tabs [role=tab]");
  if (!tab) return;
  const tabs = [...dialog.querySelectorAll(".preferences-tabs [role=tab]")];
  const index = tabs.indexOf(tab);
  const next = {
    ArrowLeft: index - 1, ArrowUp: index - 1, ArrowRight: index + 1, ArrowDown: index + 1,
    Home: 0, End: tabs.length - 1,
  }[event.key];
  if (next === undefined) return;
  event.preventDefault();
  activateSettingsTab(tabs[(next + tabs.length) % tabs.length].dataset.value);
});
action("open-claude", () => openEditor(accounts().find((account) => account.provider === "claude"), "claude"));
action("open-updates", () => api("/api/open/updates", {}));

async function updateAction(button, path, pending) {
  const original = button.textContent;
  button.disabled = true;
  button.textContent = tr(pending);
  try {
    await settingsQueue;
    return (await api(path, {})).result;
  } catch (error) {
    updateMessage = error.message;
    updatePhase = "error";
    return null;
  } finally {
    button.disabled = false;
    button.textContent = original;
  }
}

action("check-updates", async (button) => {
  updateFile = null;
  updateMessage = "";
  updatePhase = "";
  updateResult = await updateAction(button, "/api/updates/check", "正在检查…");
  if (updateResult?.status === "unconfigured") updateMessage = "没有配置更新源和签名公钥。";
  if (updateResult?.status === "current") updateMessage = "已是当前版本。";
  const target = dialog.querySelector("#update-state");
  if (target) target.innerHTML = updateStatusMarkup();
});

action("download-update", async (button) => {
  updateMessage = "";
  updatePhase = "";
  const result = await updateAction(button, "/api/updates/download", "正在下载并验证…");
  if (result?.path) updateFile = result.path;
  const target = dialog.querySelector("#update-state");
  if (target) target.innerHTML = updateStatusMarkup();
});

action("snapshot-example", () => {
  const example = {
    observedAt: null, periodStart: null, periodEnd: null, source: "自定义采集器",
    quotas: [], inputTokens: null, outputTokens: null, costs: [], balances: [], creditBalances: [],
    note: "请将 observedAt 替换为实际观测的 ISO 8601 时间，未知用量可留空，勿使用示例数值。",
    deadlines: [],
  };
  saveBlob(new Blob([JSON.stringify(example, null, 2) + "\n"], { type: "application/json" }), "用量快照示例.json");
});
