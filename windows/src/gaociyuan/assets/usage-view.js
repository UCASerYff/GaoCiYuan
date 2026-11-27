Object.assign(supplementalTranslations, {
  "本地用量": "Local usage",
  "按工具日志统计，部分来源含估算值；保留已采集的历史。": "Usage comes from tool logs and may include estimates. Collected history is retained.",
  "用量采集设置": "Usage collection settings",
  "采集用量": "Collect usage",
  "采集中": "Collecting",
  "正在读取本机用量记录": "Reading local usage records",
  "这个时间段还没有用量记录": "No usage records in this period",
  "使用支持的 AI 工具后采集用量。自定义数据目录可在采集设置中配置。": "Collect usage after using a supported AI tool. You can add log folders in Collection settings.",
  "立即采集": "Collect now",
  "导出 CSV · 当前日期范围": "Export CSV · selected dates",
  "导出 JSON · 全部历史与设备": "Export JSON · all history and devices",
  "合并其他设备 JSON…": "Merge JSON from another device…",
  "近 7 天": "Last 7 days",
  "近 30 天": "Last 30 days",
  "今天": "Today",
  "本月": "This month",
  "全部": "All",
  "Token 总量": "Total tokens",
  "输入、输出、推理与缓存汇总": "Input, output, reasoning and cache",
  "输出与推理": "Output and reasoning",
  "本期输入 Token": "Input tokens this period",
  "缓存读取": "Cache read",
  "缓存写入": "Cache write",
  "未提供可计算的缓存比例": "Cache ratio unavailable",
  "以工具实际记录为准": "From recorded usage",
  "参考费用 · USD": "Estimated cost · USD",
  "模型价估算，不等于实际账单": "Estimated using model prices",
  "每日用量": "Daily usage",
  "活跃日历": "Activity calendar",
  "按所选时间显示，最长 52 周": "Selected dates, up to 52 weeks",
  "用量分布": "Usage breakdown",
  "项目与设备": "Projects and devices",
  "会话全历史 · 不受上方日期筛选影响": "Session history across all dates",
  "会话明细": "Sessions",
  "全历史 · 按需加载": "All dates · loaded on demand",
  "未识别项目": "Unknown project",
  "未定价": "Unpriced",
  "上一页": "Previous",
  "下一页": "Next",
  "尚无可归类的记录": "No records to group",
  "导入完成": "Import complete",
  "采集频率": "Collection frequency",
  "应用运行时自动采集": "Collect automatically while running",
  "间隔（分钟）": "Interval (minutes)",
  "采集工具": "Tools",
  "恢复默认选择": "Restore defaults",
  "查找工具": "Find tools",
  "发现本机数据路径": "Local data path found",
  "暂未发现默认路径": "Default path not found",
  "自定义数据目录": "Custom log folders",
  "尚未添加额外目录": "No extra folders added",
  "默认数据位置": "Default data locations",
  "添加目录": "Add folder",
  "自定义模型价格": "Custom model prices",
  "添加模型": "Add model",
  "自动导出": "Automatic export",
  "已采集快照": "Imported snapshots",
  "上次采集": "Last collection",
  "保存设置": "Save settings",
  "停用": "Turn off",
  "其中推理": "Reasoning",
  "统计时间": "Date range",
  "分组": "Group by",
  "会话分组": "Group sessions by",
  "初次读取完整历史可能需要几分钟。": "The first full collection may take a few minutes.",
  "单位为美元 / 百万 Token。模型名需与明细中的名称完全一致；留空不设定此项，填写 0 表示该项免费。": "Prices are in USD per million tokens. Use the model name from the usage results. Leave a price blank when unknown. Enter 0 if there is no charge.",
  "发现路径只表示文件或目录存在。实际读取取决于日志格式和权限，缺少记录时不显示用量。": "Collection depends on log format and access permissions. Usage stays blank when records are unavailable.",
  "同一会话按模型分别统计；展开查看项目、设备和生成速度。": "Sessions are grouped by model. Expand a row to see the project, device and token speed.",
  "启用后每次采集会更新 JSON 导出。选择你有权写入的目录。": "When enabled, each collection updates the JSON export in a folder you can write to.",
  "在工具默认目录之外，读取你指定的日志目录。": "Read logs from these folders as well as the tool's default folders.",
  "多": "More",
  "少": "Less",
  "导出文件夹": "Export folder",
  "导出额度 CSV": "Export quota CSV",
  "工具": "Tool",
  "文件过大。": "The file is too large.",
  "日志目录路径": "Log folder path",
  "显示全部": "Show all",
  "已更新公开价格": "Public prices updated",
  "更新公开价格（联网）": "Update public prices (online)",
  "正在更新公开价格…": "Updating public prices…",
  "本地保存用量汇总，不收集对话正文。日志删除后，已采集的用量仍会保留；重复采集与同一设备重复导入不会累加。费用不可定价时显示“未定价”。": "Usage totals stay on this computer and exclude message text. Collected usage is retained after log deletion. Repeated scans and imports are deduplicated. Unknown prices are marked as unpriced.",
  "本地统计与开源来源": "Local usage and open-source components",
  "本地采集仅保存 Token、模型与会话统计。导出内容包含项目名称、设备标识与用量元数据。": "Local collection stores token, model and session statistics. Exports include project names, device identifiers and usage metadata.",
  "每个工具最多添加 16 个自定义目录。": "You can add up to 16 custom folders per tool.",
  "每页最多 50 条，会话历史完整保留。": "Up to 50 records per page. Full session history is retained.",
  "没有可核验价格的模型显示未定价。": "Models without verified prices are marked as unpriced.",
  "缓存": "Cache",
  "缓存输入占比": "Cached share of input",
  "输入": "Input",
  "1 小时缓存写入": "1-hour cache write",
});

const usageRanges = [["today", "今天"], ["7d", "近 7 天"], ["30d", "近 30 天"], ["month", "本月"], ["all", "全部"]];
let usageRange = "30d";
let usageOffset = 0;
let usageDashboard = null;
let usageMessage = "";
let usageLoading = false;
let usageBusy = false;
let usageRequest = 0;
let dailyGrouping = "client";
let sessionGrouping = "project";
let usageDraft = null;

function tokenCount(value) {
  if (value === null || value === undefined) return "—";
  if (value >= 1e9) return (value / 1e9).toFixed(2) + "B";
  if (value >= 1e6) return (value / 1e6).toFixed(2) + "M";
  if (value >= 1e4) return (value / 1e3).toFixed(1) + "K";
  return number(value);
}

function estimatedCost(value) {
  return value === null || value === undefined || !Number.isFinite(value)
    ? tr("未定价")
    : new Intl.NumberFormat(inEnglish() ? "en" : "zh-CN", {
      style: "currency", currency: "USD", minimumFractionDigits: 2, maximumFractionDigits: 4,
    }).format(value);
}

function nameForClient(id) {
  const clients = {
    codex: "Codex", claude: "Claude Code", gemini: "Gemini CLI", copilot: "GitHub Copilot",
    opencode: "OpenCode", cursor: "Cursor", antigravity: "Antigravity", qwen: "Qwen Code", kimi: "Kimi Code",
  };
  return usageSources?.sources?.find((source) => source.id === id)?.name || clients[id] || id;
}

function segments(title, items, active, callback) {
  return `<div class="segments" role="group" aria-label="${t(title)}">${items.map(([id, label]) =>
    `<button type="button" data-action="${callback}" data-value="${text(id)}" aria-pressed="${id === active}">${t(label)}</button>`
  ).join("")}</div>`;
}

function renderUsage() {
  return `<div id="usage-view">${usageContent()}</div>`;
}

function displayUsage() {
  const content = document.querySelector("#usage-view");
  if (page === "analytics" && content) content.innerHTML = usageContent();
}

function usageContent() {
  const dashboard = usageDashboard || {};
  const days = dashboard.days || [];
  const sessions = dashboard.sessions || { rows: [], totalCount: 0 };
  const warnings = dashboard.warnings || [];
  const deviceCount = dashboard.devices?.length ?? dashboard.sessionSummary?.byDevice?.length;
  return `<div class="usage-layout">
    <section class="usage-controls">
      <div class="spread usage-main-controls"><div class="stacked"><h2>${t("本地用量")}</h2><p class="muted">${t("按工具日志统计，部分来源含估算值；保留已采集的历史。")}</p></div>
        <div class="cluster">
          ${button("采集设置", "usage-settings", { glyph: "settings" })}
          ${menu("导入与导出", "upload", [
            button("导出 CSV · 当前日期范围", "usage-export-csv"),
            button("导出 JSON · 全部历史与设备", "usage-export-json"),
            "<hr>",
            button("合并其他设备 JSON…", "usage-import-open"),
          ].join(""))}
          ${button(usageBusy ? "采集中" : "采集用量", "usage-scan", { glyph: "refresh", classes: "primary", disabled: usageBusy })}
        </div>
      </div>
      <div class="spread"><div>${segments("统计时间", usageRanges, usageRange, "usage-range")}</div>
        ${dashboard.lastScanAt ? `<span class="caption muted">${t("上次采集")} ${text(displayDate(dashboard.lastScanAt))}</span>` : ""}
      </div>
      <input type="file" id="usage-import" accept=".json,application/json" class="hidden">
    </section>
    ${usageMessage ? `<p class="panel info-row amber" role="status">${icon("info")}${t(usageMessage)}</p>` : ""}
    ${warnings.length ? `<details class="panel disclosure"><summary>${icon("info")}${t("采集说明")} · ${warningCount(warnings.length)}</summary><ul class="scan-warnings">${warnings.map((warning) => `<li>${t(warning)}</li>`).join("")}</ul></details>` : ""}
    ${usageMetrics(dashboard.total, days.length > 0)}
    ${days.length ? dailyTrend(days) + activityCalendar(days) + usageBreakdown(dashboard) : emptyPanel(
      usageBusy || usageLoading ? "正在读取本机用量记录" : "这个时间段还没有用量记录",
      "chart", "使用支持的 AI 工具后采集用量。自定义数据目录可在采集设置中配置。",
      usageBusy || usageLoading ? "" : button("立即采集", "usage-scan", { classes: "primary" }),
    )}
    ${sessions.totalCount ? sessionBreakdown(dashboard.sessionSummary || {}) + sessionDetails(sessions) : ""}
    ${dashboard.rows?.length ? snapshotUsage(dashboard.rows) : ""}
    <footer class="spread muted caption usage-footer">
      <p class="info-row">${icon("database")}${t("本地保存用量汇总，不收集对话正文。日志删除后，已采集的用量仍会保留；重复采集与同一设备重复导入不会累加。费用不可定价时显示“未定价”。")}</p>
      ${deviceCount !== undefined ? `<span>${text(countText(deviceCount, "台设备", "devices"))}</span>` : ""}
    </footer>
  </div>`;
}

function warningCount(count) {
  return text(countText(count, "项", "items"));
}

function usageMetrics(amounts = {}, present) {
  const value = (key) => present ? (amounts[key] ?? null) : null;
  const input = value("input");
  const output = value("output");
  const reasoning = value("reasoning");
  const totalOutput = output === null && reasoning === null ? null : (output || 0) + (reasoning || 0);
  const cache = value("cacheRead");
  const ratio = input !== null && cache !== null && input + cache > 0 ? cache / (input + cache) * 100 : null;
  return `<section class="metric-grid usage-metrics">
    ${metric("Token 总量", tokenCount(value("totalTokens")), "输入、输出、推理与缓存汇总", "chart")}
    ${metric("输入", tokenCount(input), "本期输入 Token", "left", "indigo")}
    ${metric("输出与推理", tokenCount(totalOutput), reasoning === null ? "—" : `${tr("其中推理")} ${tokenCount(reasoning)}`, "right", "teal")}
    ${metric("缓存读取", tokenCount(cache), ratio === null ? "未提供可计算的缓存比例" : `${tr("缓存输入占比")} ${ratio.toFixed(1)}%`, "cache", "amber")}
    ${metric("缓存写入", tokenCount(value("cacheWrite")), "以工具实际记录为准", "download", "purple")}
    ${metric("参考费用 · USD", estimatedCost(value("costUSD")), "模型价估算，不等于实际账单", "cost", "teal")}
  </section>`;
}

function dailyTotals(rows) {
  const days = new Map();
  for (const row of rows) {
    if (!/^\d{4}-\d{2}-\d{2}$/.test(row.day)) continue;
    const point = days.get(row.day) || { day: row.day, input: 0, output: 0, cached: 0, total: 0 };
    const amounts = row.amounts || {};
    point.input += amounts.input || 0;
    point.output += (amounts.output || 0) + (amounts.reasoning || 0);
    point.cached += (amounts.cacheRead || 0) + (amounts.cacheWrite || 0);
    point.total += amounts.totalTokens || 0;
    days.set(row.day, point);
  }
  return [...days.values()].sort((left, right) => left.day.localeCompare(right.day));
}

function dailyTrend(days) {
  const points = dailyTotals(days);
  const max = Math.max(1, ...points.map((point) => point.input + point.output + point.cached));
  const step = Math.ceil(points.length / 7);
  const bar = (value, tone) => `<span class="${tone}" style="--height:${value / max * 100}%"></span>`;
  const labels = points.map((point, index) => index % step === 0 ? point.day.slice(5) : "");
  return `<section class="panel usage-section">
    <div class="spread"><h3>${t("每日用量")}</h3><span class="caption muted">${text(countText(points.length, "个有记录的日期", "days with records"))}</span></div>
    <div class="trend">
      <div class="trend-y" aria-hidden="true">${[1, 0.75, 0.5, 0.25, 0].map((rate) => `<span>${text(tokenCount(Math.round(max * rate)))}</span>`).join("")}</div>
      <div class="trend-scroll"><div class="trend-grid" style="--point-count:${points.length}">
        ${points.map((point, index) => `<div class="trend-day" title="${text(`${point.day} · ${tokenCount(point.total)} Token`)}">
          <div class="trend-stack">${bar(point.input, "input-segment")}${bar(point.output, "output-segment")}${bar(point.cached, "cached-segment")}</div><span>${text(labels[index])}</span>
        </div>`).join("")}
      </div></div>
    </div>
    <div class="cluster legend"><span><i class="input-segment"></i>${t("输入")}</span><span><i class="output-segment"></i>${t("输出与推理")}</span><span><i class="cached-segment"></i>${t("缓存")}</span></div>
  </section>`;
}

function activityCalendar(rows) {
  const points = dailyTotals(rows);
  if (!points.length) return "";
  const byDay = new Map(points.map((point) => [point.day, point.total]));
  const dayMs = 86_400_000;
  const last = new Date(points.at(-1).day).valueOf();
  const earliest = Math.max(new Date(points[0].day).valueOf(), last - dayMs * 363);
  const start = earliest - ((new Date(earliest).getUTCDay() + 6) % 7) * dayMs;
  if (!Number.isFinite(start) || !Number.isFinite(last)) return "";
  const max = Math.max(1, ...points.map((point) => point.total));
  const cells = [];
  for (let time = start; time <= last; time += dayMs) {
    const day = new Date(time).toISOString().slice(0, 10);
    const value = byDay.get(day) || 0;
    const intensity = value > 0 ? Math.max(0.2, Math.log1p(value) / Math.log1p(max)) : 0.07;
    cells.push(`<span class="heat-cell" style="--intensity:${time < earliest ? 0 : intensity}" title="${text(`${day} · ${tokenCount(value)} Token`)}"></span>`);
  }
  const daysWithService = points.filter((item) => item.total > 0).length;
  return `<section class="panel usage-section">
    <div class="spread"><h3>${t("活跃日历")}</h3><span class="caption muted">${t("按所选时间显示，最长 52 周")}</span></div>
    <div class="heat-scroll"><div class="heat-grid">${cells.join("")}</div></div>
    <div class="spread caption-small muted"><div class="cluster heat-key">${t("少")}${[0.09, 0.22, 0.44, 0.66, 0.88].map((number) => `<span class="heat-cell" style="--intensity:${number}"></span>`).join("")}${t("多")}</div><span>${text(countText(daysWithService, "天有用量", "active days"))}</span></div>
  </section>`;
}

function breakdownRows(rows, formatter = (value) => value) {
  if (!rows?.length) return `<p class="muted">${t("尚无可归类的记录")}</p>`;
  const max = Math.max(1, ...rows.map((row) => row.amounts?.totalTokens || 0));
  function renderRows(group) {
    return group.map((row) => {
      const amount = row.amounts || {};
      const label = formatter(row.name || row.label);
      return `<div class="breakdown-row"><div class="breakdown-totals">
        <span title="${text(label)}">${text(label)}</span><strong>${text(tokenCount(amount.totalTokens))}</strong><span class="muted caption">${text(estimatedCost(amount.costUSD))}</span>
        </div><progress value="${amount.totalTokens || 0}" max="${max}" aria-label="${text(label)}"></progress></div>`;
    }).join("");
  }
  return renderRows(rows.slice(0, 8)) + (rows.length > 8
    ? `<details class="disclosure stacked"><summary class="caption">${t("显示全部")} ${warningCount(rows.length)}</summary>${renderRows(rows.slice(8))}</details>` : "");
}

function usageBreakdown(dashboard) {
  const groupByClient = dailyGrouping === "client";
  return `<section class="panel usage-section"><div class="spread">
    <div class="cluster"><h3>${t("用量分布")}</h3><span class="caption muted">${t(usageRanges.find(([id]) => id === usageRange)[1])}</span></div>
    ${segments("分组", [["client", "工具"], ["model", "模型"]], dailyGrouping, "daily-group")}
  </div>${breakdownRows(groupByClient ? dashboard.byClient : dashboard.byModel, groupByClient ? nameForClient : undefined)}</section>`;
}

function sessionBreakdown(summary) {
  return `<section class="panel usage-section"><div class="spread">
    <div class="stacked"><h3>${t("项目与设备")}</h3><p class="caption muted">${t("会话全历史 · 不受上方日期筛选影响")}</p></div>
    ${segments("会话分组", [["project", "项目"], ["device", "设备"]], sessionGrouping, "session-group")}
  </div>${breakdownRows(sessionGrouping === "project" ? summary.byProject : summary.byDevice)}</section>`;
}

function sessionDetail(item) {
  const amount = item.amounts || {};
  const definition = (label, value) => value ? `<div class="spread"><dt>${t(label)}</dt><dd>${text(value)}</dd></div>` : "";
  const measuredRate = item.timedTokens > 0 && item.timedDurationMS > 0
    ? (item.timedTokens / (item.timedDurationMS / 1000)).toFixed(1) + " Token/s" : null;
  return `<details class="session">
    <summary><span class="stacked"><strong>${t(item.projectLabel || "未识别项目")}</strong><span class="muted caption">${text(nameForClient(item.client))} · ${text(item.model)}</span></span>
      <span class="stacked"><strong>${text(tokenCount(amount.totalTokens))}</strong><span class="muted caption">${text(estimatedCost(amount.costUSD))}</span></span></summary>
    <dl class="session-detail muted caption">${definition("设备", item.deviceLabel || item.deviceID)}${definition("项目标识", item.projectKey)}${definition("会话", item.sessionID)}
    ${definition("首次活动", item.firstActive ? displayDate(item.firstActive) : "")}${definition("最近活动", item.lastActive ? displayDate(item.lastActive) : "")}
    ${definition("有计时记录的生成速度", measuredRate)}
    <div class="cluster">${[["输入", "input"], ["输出", "output"], ["推理", "reasoning"], ["缓存读取", "cacheRead"], ["缓存写入", "cacheWrite"]].map(([label, key]) => `<span>${t(label)} ${text(tokenCount(amount[key]))}</span>`).join("")}</div></dl>
  </details>`;
}

function sessionDetails(sessions) {
  const { rows, totalCount, offset = 0, pageSize = 50 } = sessions;
  const first = rows.length ? offset + 1 : 0;
  const last = offset + rows.length;
  return `<section class="panel usage-section">
    <div class="spread"><div class="cluster"><h3>${t("会话明细")}</h3><span class="caption muted">${t("全历史 · 按需加载")}</span></div><span class="caption muted">${first}–${last} / ${totalCount}</span></div>
    <p class="caption muted">${t("同一会话按模型分别统计；展开查看项目、设备和生成速度。")}</p>
    <div>${rows.map(sessionDetail).join("")}</div>
    <div class="spread"><span class="caption muted">${t("每页最多 50 条，会话历史完整保留。")}</span><div class="cluster">
      ${button("上一页", "usage-offset", { value: Math.max(0, offset - pageSize), disabled: offset === 0 || usageLoading })}
      ${button("下一页", "usage-offset", { value: offset + pageSize, disabled: last >= totalCount || usageLoading })}
    </div></div>
  </section>`;
}

function snapshotUsage(rows) {
  return `<details class="panel disclosure"><summary>${icon("time")}${t("已采集快照")}</summary><div class="table-scroll">
    <table><thead><tr>${["时间", "平台", "来源", "输入", "输出", "费用"].map((title) => `<th scope="col">${t(title)}</th>`).join("")}</tr></thead>
    <tbody>${rows.map((row) => `<tr><td>${text(displayDate(row.observedAt))}</td><td>${text(providerFor(row.provider)?.agent || row.provider)}</td>
      <td>${text(row.source)}</td><td>${text(number(row.inputTokens))}</td><td>${text(number(row.outputTokens))}</td><td>${text(row.cost == null ? "—" : money(row.cost, row.currency))}</td></tr>`).join("")}</tbody></table></div>
    <div class="cluster">${button("导出额度 CSV", "usage-snapshot-export", { value: "history" })}${button("导出用量 CSV", "usage-snapshot-export", { value: "usage" })}</div>
  </details>`;
}

async function loadUsage(quiet = false) {
  const request = ++usageRequest;
  if (!quiet) {
    usageLoading = true;
    displayUsage();
  }
  let redraw = !quiet;
  try {
    const result = await api(`/api/usage?range=${usageRange}&offset=${usageOffset}`);
    if (request === usageRequest) {
      redraw ||= JSON.stringify(result) !== JSON.stringify(usageDashboard);
      usageDashboard = result;
    }
  } catch (error) {
    if (request === usageRequest && !quiet) usageMessage = error.message;
  } finally {
    if (request === usageRequest) {
      usageLoading = false;
      if (redraw) displayUsage();
    }
  }
}

setInterval(() => {
  if (page !== "analytics" || document.hidden || dialog.open || usageLoading || usageBusy || operationCount) return;
  if (document.querySelector("#usage-view details[open]") || document.activeElement.closest("#usage-view")) return;
  void loadUsage(true);
}, 20_000);

action("usage-range", (button) => {
  if (usageRange === button.dataset.value) return;
  usageRange = button.dataset.value;
  usageDashboard = null;
  return loadUsage();
});
action("usage-offset", (button) => {
  usageOffset = Number(button.dataset.value);
  return loadUsage();
});
action("daily-group", (button) => {
  dailyGrouping = button.dataset.value;
  displayUsage();
});
action("session-group", (button) => {
  sessionGrouping = button.dataset.value;
  displayUsage();
});
action("usage-scan", async () => {
  usageBusy = true;
  usageMessage = "";
  displayUsage();
  try {
    await api("/api/usage/scan", {});
  } catch (error) {
    usageMessage = error.message;
  } finally {
    usageBusy = false;
    await loadUsage();
  }
});
action("usage-export-csv", () => downloadFile(`/api/export/local-usage.csv?range=${usageRange}`, "GaoCiYuan-usage.csv"));
action("usage-export-json", () => downloadFile("/api/export/local-usage.json", "GaoCiYuan-usage.json"));
action("usage-snapshot-export", (button) =>
  downloadFile(`/api/export/${button.dataset.value}.csv?range=${usageRange}`, `GaoCiYuan-${button.dataset.value}.csv`));
action("usage-import-open", () => document.querySelector("#usage-import")?.click());

document.addEventListener("change", async (event) => {
  if (event.target.id !== "usage-import") return;
  const file = event.target.files[0];
  event.target.value = "";
  if (!file) return;
  usageMessage = "";
  try {
    if (file.size > 64 * 1024 * 1024) throw new Error(tr("文件过大。"));
    await api("/api/usage/import", JSON.parse(await file.text()));
    usageMessage = "导入完成";
  } catch (error) {
    usageMessage = error.message;
  }
  await loadUsage();
});

function usageSettingsSection(title, controls, body) {
  return `<section class="panel settings-panel"><div class="spread"><h3>${t(title)}</h3>${controls || ""}</div>${body}</section>`;
}

function drawUsageSettings() {
  const { draft, search, clientID } = usageDraft;
  const paths = draft.engine.customPaths[clientID] || [];
  const clients = draft.sources.filter((entry) => entry.supported !== false && entry.supportsCustomPaths);
  const scroll = dialog.querySelector(".dialog-body")?.scrollTop || 0;
  openDialog(`${editorHeading("用量采集设置", "配置本机工具、数据目录和费用估算。")}
    <form id="usage-settings-form">
      <div class="dialog-body settings-body settings-sections">
        ${usageSettingsSection("采集频率", "", `
          ${switchInput("automaticallyScan", "应用运行时自动采集", draft.automaticallyScan)}
          ${settingsField("间隔（分钟）", `<input type="number" min="2" max="60" required name="refreshMinutes" value="${text(draft.refreshMinutes)}">`)}
          ${settingsDescription("初次读取完整历史可能需要几分钟。")}`)}
        ${usageSettingsSection("采集工具", `<div class="cluster"><span id="usage-source-count" class="caption muted">${sourceCount()}</span>${button("恢复默认选择", "sources-default")}</div>`, `
          <input id="source-search" type="search" value="${text(search)}" aria-label="${t("查找工具")}" placeholder="${t("查找工具")}">
          <div id="source-options" class="source-options">${sourceOptions()}</div>
          ${settingsDescription("发现路径只表示文件或目录存在。实际读取取决于日志格式和权限，缺少记录时不显示用量。")}`)}
        ${clients.length ? usageSettingsSection("自定义数据目录", `<select name="selectedClient" aria-label="${t("工具")}">${selectOptions(clients.map((item) => [item.id, item.name]), clientID)}</select>`, `
          ${settingsDescription("在工具默认目录之外，读取你指定的日志目录。")}
          <details class="disclosure"><summary class="muted">${t("默认数据位置")}</summary>
          ${(draft.sources.find((source) => source.id === clientID)?.paths || []).map((path) => `<code>${text(path)}</code>`).join("")}</details>
          ${paths.length ? paths.map((path, index) => `<div class="spread"><code>${text(path)}</code>${button("移除", "remove-source-path", { value: index })}</div>`).join("")
            : `<p class="muted">${t("尚未添加额外目录")}</p>`}
          <div class="cluster"><input name="sourcePath" aria-label="${t("日志目录路径")}" placeholder="C:\\…\\logs">${button("添加", "add-source-path")}${button("添加目录", "pick-source-path", { glyph: "folder" })}</div>`): ""}
        ${usageSettingsSection("自定义模型价格", button("添加模型", "add-price", { glyph: "plus" }), `
          ${settingsDescription("单位为美元 / 百万 Token。模型名需与明细中的名称完全一致；留空不设定此项，填写 0 表示该项免费。")}
          <div class="cluster">${button("更新公开价格（联网）", "update-prices", { glyph: "download" })}<p id="price-status" class="caption muted" role="status"></p></div>
          ${(draft.engine.modelPrices || []).map(priceEditor).join("")}
          ${!draft.engine.modelPrices?.length ? `<p class="muted">${t("没有可核验价格的模型显示未定价。")}</p>` : ""}`)}
        ${usageSettingsSection("自动导出", "", `
          ${settingsDescription("启用后每次采集会更新 JSON 导出。选择你有权写入的目录。")}
          <div class="cluster"><input name="automaticExportPath" value="${text(draft.automaticExportPath)}" aria-label="${t("导出文件夹")}" placeholder="C:\\…\\exports">${button("选择…", "pick-export-path", { glyph: "folder" })}${button("停用", "disable-autoexport")}</div>`)}
        ${usageSettingsSection("本地统计与开源来源", "", settingsDescription("本地采集仅保存 Token、模型与会话统计。导出内容包含项目名称、设备标识与用量元数据。"))}
      </div>
        <footer class="dialog-foot">${button("取消", "close-dialog")}<p id="sources-error" class="red caption" role="alert">${t(draft.error || "")}</p><button type="submit" class="primary"${draft.error ? " disabled" : ""}>${t("保存设置")}</button></footer>
    </form>`, "source-dialog");
  dialog.querySelector(".dialog-body").scrollTop = scroll;
  dialog.querySelector("form").addEventListener("submit", saveUsageSettings);
}

function sourceCount() {
  return text(inEnglish() ? `${usageDraft.draft.engine.enabledClientIDs.length} selected` : `已选择 ${usageDraft.draft.engine.enabledClientIDs.length} 项`);
}

function sourceOptions() {
  const { draft, search } = usageDraft;
  const selected = new Set(draft.engine.enabledClientIDs);
  const needle = search.trim().toLocaleLowerCase();
  return draft.sources.filter((item) => `${item.name} ${item.id}`.toLocaleLowerCase().includes(needle)).map((item) => {
    const supported = item.supported !== false;
    const status = !supported ? "该采集源暂不支持 Windows" : item.detected ? "发现本机数据路径" : "暂未发现默认路径";
    return `<div class="source-option">
      <label><input type="checkbox" name="source" value="${text(item.id)}"${selected.has(item.id) && supported ? " checked" : ""}${supported ? "" : " disabled"}>${t(item.name)}</label>
      <p class="caption-small ${item.detected ? "teal" : "muted"}">${icon("folder")}${t(status)}</p>
    </div>`;
  }).join("");
}

const priceFields = [["model", "模型"], ["inputPerMillion", "输入"], ["outputPerMillion", "输出"], ["cacheReadPerMillion", "缓存读取"], ["cacheWritePerMillion", "缓存写入"], ["cacheWrite1hPerMillion", "1 小时缓存写入"]];

function priceEditor(item, index) {
  return `<div class="price-row" data-price-row="${index}">${priceFields.map(([name, label]) => `<label><span class="caption muted">${t(label)}</span>
    <input name="${name}" value="${text(item[name])}" ${name === "model" ? 'type="text" required' : 'type="number" min="0" step="any"'}></label>`).join("")}${button("移除", "remove-price", { value: index })}</div>`;
}

async function saveUsageSettings(event) {
  event.preventDefault();
  const target = event.submitter;
  if (target) target.disabled = true;
  const { draft } = usageDraft;
  try {
    const result = await api("/api/usage/settings", {
      automaticallyScan: draft.automaticallyScan,
      refreshMinutes: draft.refreshMinutes,
      engine: draft.engine,
      automaticExportPath: draft.automaticExportPath?.trim() || null,
    });
    usageSources = result.result?.sources ? result.result : await api("/api/usage/settings");
    closeDialog();
    if (page === "catalog") document.querySelector("#source-cards").innerHTML = sourceCards();
  } catch (error) {
    showSourceError(error);
  } finally {
    if (target) target.disabled = false;
  }
}

function showSourceError(error) {
  const display = dialog.querySelector("#sources-error");
  if (display) display.textContent = error.message;
}

function addLocalPath(value) {
  const path = value.trim();
  if (!path) return;
  const { clientID, draft } = usageDraft;
  const current = draft.engine.customPaths[clientID] || [];
  if (current.length >= 16 && !current.includes(path)) throw new Error(tr("每个工具最多添加 16 个自定义目录。"));
  if (!current.includes(path)) draft.engine.customPaths[clientID] = [...current, path];
  if (!draft.engine.enabledClientIDs.includes(clientID)) draft.engine.enabledClientIDs.push(clientID);
  drawUsageSettings();
}

action("usage-settings", async (button) => {
  button.disabled = true;
  try {
    const draft = await api("/api/usage/settings");
    usageSources = draft;
    const client = draft.sources.find((item) => item.id === "codex" && item.supportsCustomPaths)
      || draft.sources.find((item) => item.supportsCustomPaths && item.supported !== false);
    usageDraft = { draft: structuredClone(draft), clientID: client?.id, search: "" };
    drawUsageSettings();
  } finally {
    button.disabled = false;
  }
});
action("sources-default", () => {
  const { draft } = usageDraft;
  draft.engine.enabledClientIDs = draft.defaultClientIDs || draft.sources.filter((item) => item.defaultEnabled).map((item) => item.id);
  drawUsageSettings();
});
action("add-source-path", () => {
  try {
    addLocalPath(dialog.querySelector('[name="sourcePath"]').value);
  } catch (error) { showSourceError(error); }
});
action("remove-source-path", (button) => {
  const { clientID, draft } = usageDraft;
  draft.engine.customPaths[clientID].splice(Number(button.dataset.value), 1);
  drawUsageSettings();
});
action("pick-source-path", async () => {
  try {
    const { result } = await api("/api/choose/directory", {});
    if (result?.path) addLocalPath(result.path);
  } catch (error) {
    showSourceError(error);
  }
});
action("pick-export-path", async () => {
  try {
    const { result } = await api("/api/choose/directory", {});
    if (result?.path) {
      usageDraft.draft.automaticExportPath = result.path;
      drawUsageSettings();
    }
  } catch (error) { showSourceError(error); }
});
action("disable-autoexport", () => {
  usageDraft.draft.automaticExportPath = null;
  drawUsageSettings();
});
action("add-price", () => {
  const engine = usageDraft.draft.engine;
  engine.modelPrices ||= [];
  if (engine.modelPrices.length >= 500) return;
  engine.modelPrices.push({ model: "" });
  drawUsageSettings();
});
action("remove-price", (button) => {
  usageDraft.draft.engine.modelPrices.splice(Number(button.dataset.value), 1);
  drawUsageSettings();
});
action("update-prices", async (button) => {
  const status = dialog.querySelector("#price-status");
  button.disabled = true;
  status.textContent = tr("正在更新公开价格…");
  try {
    const { result } = await api("/api/usage/prices", {});
    status.textContent = result?.message || tr("已更新公开价格");
  } catch (error) {
    status.textContent = error.message;
  } finally {
    button.disabled = false;
  }
});

document.addEventListener("input", (event) => {
  const input = event.target;
  if (!input.closest("#usage-settings-form")) return;
  if (input.id === "source-search") {
    usageDraft.search = input.value;
    dialog.querySelector("#source-options").innerHTML = sourceOptions();
  } else if (input.name === "automaticExportPath") {
    usageDraft.draft.automaticExportPath = input.value;
  } else if (input.name === "refreshMinutes") {
    usageDraft.draft.refreshMinutes = Number(input.value);
  } else {
    const row = input.closest("[data-price-row]");
    if (row) usageDraft.draft.engine.modelPrices[Number(row.dataset.priceRow)][input.name]
      = input.name === "model" ? input.value.trim() : input.value === "" ? null : Number(input.value);
  }
});

document.addEventListener("change", (event) => {
  const input = event.target;
  if (!input.closest("#usage-settings-form")) return;
  const { draft } = usageDraft;
  if (input.name === "source") {
    const selected = new Set(draft.engine.enabledClientIDs);
    if (input.checked) selected.add(input.value);
    else selected.delete(input.value);
    draft.engine.enabledClientIDs = [...selected];
    dialog.querySelector("#usage-source-count").textContent = sourceCount();
  } else if (input.name === "selectedClient") {
    usageDraft.clientID = input.value;
    drawUsageSettings();
  } else if (input.name === "automaticallyScan") {
    draft.automaticallyScan = input.checked;
  }
});
