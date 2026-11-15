const token = document.querySelector('meta[name="gao-token"]').content;
let state = null;
let page = "overview";
let usageRows = [];

const main = document.querySelector("#main");
const rail = document.querySelector("#rail");
const notice = document.querySelector("#notice");

document.querySelectorAll("nav button").forEach((button) => {
  button.addEventListener("click", () => {
    page = button.dataset.page;
    document.querySelectorAll("nav button").forEach((item) => item.classList.toggle("active", item === button));
    render();
  });
});

async function api(path, body) {
  const options = { headers: { "X-Gao-Token": token } };
  if (body !== undefined) {
    options.method = "POST";
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const response = await fetch(path, options);
  const payload = await response.json();
  if (!response.ok || payload.ok === false) throw new Error(payload.error || "请求失败");
  if (payload.state) state = payload.state;
  return payload;
}

function ringHTML(ring) {
  const face = ring || { fill: 0, label: "—", color: "secondary", opacity: 1, help: "" };
  const fill = face.showsDash ? 0 : face.fill || 0;
  return `<div class="ring-wrap" style="opacity:${face.opacity ?? 1}" title="${escapeAttr(face.help || "")}">
    <div class="ring ${face.color || "secondary"}" style="--fill:${fill}"><span>${escapeHTML(face.label || "—")}</span></div>
    <div class="ring-label">${escapeHTML(face.label || "—")}</div>
  </div>`;
}

function escapeHTML(value) {
  return String(value ?? "").replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
}
function escapeAttr(value) { return escapeHTML(value); }

function accounts() { return state?.accounts || []; }

function render() {
  document.body.dataset.appearance = resolvedAppearance();
  if (!state) { main.innerHTML = "<p>正在读取本机资料…</p>"; return; }
  notice.classList.toggle("hidden", !state.notice);
  notice.textContent = state.notice || "";
  if (state.status === "readonly") {
    main.innerHTML = `<section class="panel"><h2>资料库无法写入</h2><p>${escapeHTML(state.notice || "")}</p></section>`;
    rail.innerHTML = "";
    return;
  }
  if (page === "overview") renderOverview();
  else if (page === "agents") renderAgents();
  else if (page === "usage") renderUsage();
  else if (page === "catalog") renderCatalog();
  else renderSettings();
  renderRail();
}

function resolvedAppearance() {
  const choice = state?.settings?.appearance || "system";
  if (choice === "system") return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  return choice;
}

function renderOverview() {
  const rows = accounts();
  const counts = { needsAction: 0, syncPaused: 0, historical: 0, ok: 0 };
  rows.forEach((row) => { counts[row.health] = (counts[row.health] || 0) + 1; });
  main.innerHTML = `
    <section class="stats">
      <div class="card stat"><strong>${rows.length}</strong><span>Agent</span></div>
      <div class="card stat"><strong>${counts.needsAction || 0}</strong><span>需处理</span></div>
      <div class="card stat"><strong>${counts.syncPaused || 0}</strong><span>暂时无法同步</span></div>
      <div class="card stat"><strong>${counts.historical || 0}</strong><span>历史数据</span></div>
    </section>
    <div class="toolbar">
      <input id="q" placeholder="搜索名称或平台" value="${escapeAttr(sessionStorage.getItem("q") || "")}">
      <select id="health"><option value="">全部状态</option><option value="needsAction">需处理</option><option value="syncPaused">暂时无法同步</option><option value="historical">历史数据</option><option value="ok">正常</option></select>
    </div>
    <div class="grid">${rows.filter(matchFilter).map(cardHTML).join("") || `<div class="panel">还没有 Agent。到「平台接入」添加，或导入快照文件。</div>`}</div>`;
  bindFilters();
  bindCards();
}

function matchFilter(account) {
  const query = (document.querySelector("#q")?.value || sessionStorage.getItem("q") || "").trim().toLowerCase();
  const health = document.querySelector("#health")?.value || "";
  if (health && account.health !== health) return false;
  if (!query) return true;
  return `${account.name} ${account.provider} ${account.plan || ""}`.toLowerCase().includes(query);
}

function cardHTML(account) {
  const note = account.grokStatus || account.statusNote || account.error || "";
  return `<article class="card" data-id="${account.id}">
    <div class="account-head">${ringHTML(account.ring)}<div><strong>${escapeHTML(account.name)}</strong><div class="muted">${escapeHTML(account.provider)} · ${escapeHTML(account.connection)}</div></div></div>
    <p class="muted">${escapeHTML(note)}</p>
    <div class="actions">
      ${account.provider === "grok" && account.connection === "本机软件自动读取" ? `<button class="primary" data-grok="${account.id}">读取本机额度</button>` : `<button class="ghost" data-refresh="${account.id}">刷新</button>`}
    </div>
  </article>`;
}

function renderAgents() {
  main.innerHTML = `<h2 class="page-title">Agent 软件</h2><div class="grid">${accounts().map((account) => `<article class="card">
    <div class="account-head"><span class="mark">${escapeHTML(account.provider.slice(0, 1))}</span><div><strong>${escapeHTML(account.name)}</strong><div class="muted">${escapeHTML(account.connection)}</div></div>${ringHTML(account.ring)}</div>
    <p class="muted">${escapeHTML(account.plan || "未填写套餐")} · 悬浮条 ${account.showInRail ? "显示" : "隐藏"} · 凭据 ${account.hasCredential ? "已保存" : "未保存"}</p>
    <p class="muted">历史 ${ (account.history || []).length } 条。Grok Bot 的手动读数不进入历史。</p>
    <div class="actions">
      <button class="ghost" data-rail="${account.id}">${account.showInRail ? "移出悬浮条" : "放回悬浮条"}</button>
      <button class="ghost" data-delete="${account.id}">删除</button>
    </div>
    <details><summary>最近快照</summary><pre>${escapeHTML(JSON.stringify(account.snapshot || account.grokBotManualReading || {}, null, 2))}</pre></details>
  </article>`).join("") || `<div class="panel">还没有账户。</div>`}</div>`;
  main.querySelectorAll("[data-delete]").forEach((button) => button.onclick = async () => {
    await api("/api/accounts/delete", { id: button.dataset.delete });
    render();
  });
  main.querySelectorAll("[data-rail]").forEach((button) => button.onclick = async () => {
    const account = accounts().find((item) => item.id === button.dataset.rail);
    await api("/api/accounts/save", { ...publicAccount(account), showInRail: !account.showInRail });
    render();
  });
}

function publicAccount(account) {
  return {
    id: account.id, provider: account.provider, connection: account.connection, name: account.name,
    plan: account.plan, filePath: account.filePath, enabled: account.enabled, budget: account.budget,
    currency: account.currency, showInRail: account.showInRail, scopeID: account.scopeID, region: account.region,
  };
}

function renderCatalog() {
  api("/api/catalog").then((payload) => {
    const providers = payload.providers || [];
    main.innerHTML = `<h2 class="page-title">平台接入</h2>
      <div class="grid">${providers.map((item) => `<article class="card">
        <div class="account-head"><span class="mark">${escapeHTML(item.mark)}</span><strong>${escapeHTML(item.name)}</strong></div>
        <p>${escapeHTML(item.note)}</p>
        ${item.creatable ? `<form class="form" data-provider="${item.id}">
          <input name="name" value="${escapeAttr(item.defaultName)}">
          <select name="connection">${item.connections.map((connection) => `<option>${escapeHTML(connection)}</option>`).join("")}</select>
          <input name="filePath" placeholder="快照 JSON 路径（快照文件连接时填写）">
          <input name="secret" type="password" placeholder="凭据（只写入凭据管理器）" autocomplete="off">
          <button class="primary" type="submit">添加</button>
        </form>` : `<p class="muted">V4.13 起不再新增这一类账户。</p>`}
      </article>`).join("")}</div>`;
    main.querySelectorAll("form").forEach((form) => form.onsubmit = async (event) => {
      event.preventDefault();
      const data = Object.fromEntries(new FormData(form).entries());
      await api("/api/accounts/save", { provider: form.dataset.provider, ...data });
      page = "agents";
      document.querySelectorAll("nav button").forEach((item) => item.classList.toggle("active", item.dataset.page === "agents"));
      render();
    });
  }).catch((error) => { main.innerHTML = `<p>${escapeHTML(error.message)}</p>`; });
}

function renderUsage() {
  main.innerHTML = `<h2 class="page-title">用量分析</h2>
    <div class="toolbar">
      <select id="range"><option value="today">今天</option><option value="7d" selected>7 天</option><option value="30d">30 天</option><option value="month">本月</option><option value="all">全部</option></select>
      <input id="usage-provider" placeholder="provider，例如 claude">
      <button class="ghost" id="load-usage">查看</button>
      <a class="ghost" id="csv-history">导出额度 CSV</a>
      <a class="ghost" id="csv-usage">导出用量 CSV</a>
    </div>
    <p class="muted">这里只汇总已导入快照里的 Token、费用和额度窗口。没有读到的数字保持空白，不会写成 0。Mac 版的 Tokscale 本地日志扫描没有搬到 Windows。</p>
    <div class="panel"><table><thead><tr><th>时间</th><th>平台</th><th>来源</th><th>输入</th><th>输出</th><th>费用</th></tr></thead>
      <tbody>${usageRows.map((row) => `<tr><td>${escapeHTML(row.observedAt)}</td><td>${escapeHTML(row.provider)}</td><td>${escapeHTML(row.source)}</td><td>${row.inputTokens ?? "—"}</td><td>${row.outputTokens ?? "—"}</td><td>${row.cost ?? "—"} ${escapeHTML(row.currency || "")}</td></tr>`).join("") || `<tr><td colspan="6">这个范围内没有 Token 或费用记录。</td></tr>`}</tbody></table></div>
    <h3>额度历史</h3>
    <div class="panel" id="quota-history"></div>`;
  const range = () => document.querySelector("#range").value;
  const provider = () => document.querySelector("#usage-provider").value.trim();
  document.querySelector("#load-usage").onclick = loadUsage;
  document.querySelector("#csv-history").href = `/api/export/history.csv?range=${range()}&provider=${encodeURIComponent(provider())}`;
  document.querySelector("#csv-usage").href = `/api/export/usage.csv?range=${range()}&provider=${encodeURIComponent(provider())}`;
  document.querySelectorAll("#csv-history,#csv-usage").forEach((link) => {
    link.addEventListener("click", (event) => {
      event.preventDefault();
      const url = link.id === "csv-history"
        ? `/api/export/history.csv?range=${range()}&provider=${encodeURIComponent(provider())}`
        : `/api/export/usage.csv?range=${range()}&provider=${encodeURIComponent(provider())}`;
      fetch(url, { headers: { "X-Gao-Token": token } }).then((response) => response.blob()).then((blob) => {
        const object = URL.createObjectURL(blob);
        const anchor = document.createElement("a");
        anchor.href = object;
        anchor.download = link.id + ".csv";
        anchor.click();
        URL.revokeObjectURL(object);
      });
    });
  });
}

async function loadUsage() {
  const range = document.querySelector("#range").value;
  const provider = document.querySelector("#usage-provider").value.trim();
  const payload = await api(`/api/usage?range=${range}&provider=${encodeURIComponent(provider)}`);
  usageRows = payload.rows || [];
  renderUsage();
}

function renderSettings() {
  const library = state.library || {};
  const settings = state.settings || {};
  main.innerHTML = `<h2 class="page-title">设置</h2>
    <form class="panel form" id="settings-form">
      <label>外观 <select name="appearance"><option value="system">跟随系统</option><option value="light">浅色</option><option value="dark">深色</option></select></label>
      <label>语言 <select name="language"><option value="zh-Hans">简体中文</option><option value="en">English</option><option value="system">跟随系统</option></select></label>
      <label>时区 <input name="timeZone" value="${escapeAttr(settings.timeZone || "Asia/Shanghai")}"></label>
      <label>自动刷新快照文件 <input type="checkbox" name="autoRefresh" ${library.autoRefresh ? "checked" : ""}></label>
      <label>固定间隔 <input type="checkbox" name="refreshFixedInterval" ${settings.refreshFixedInterval ? "checked" : ""}></label>
      <label>间隔（分钟） <input name="refreshMinutes" type="number" min="1" max="60" value="${library.refreshMinutes ?? 5}"></label>
      <label>剩余额度提醒阈值 <input name="warningThreshold" type="number" min="5" max="50" value="${library.warningThreshold ?? 20}"></label>
      <label>悬浮条 <input type="checkbox" name="panelFloating" ${settings.panelFloating !== false ? "checked" : ""}></label>
      <p class="muted">资料目录 ${escapeHTML(state.dataDir)}。Grok Bot 快照 ${escapeHTML(state.grokbotPath)}。凭据后端 ${escapeHTML(state.credentialBackend)}。自动刷新不会读取 Grok Bot 快照。</p>
      <button class="primary" type="submit">保存</button>
    </form>`;
  const form = document.querySelector("#settings-form");
  form.appearance.value = settings.appearance || "system";
  form.language.value = settings.language || "zh-Hans";
  form.onsubmit = async (event) => {
    event.preventDefault();
    const data = Object.fromEntries(new FormData(form).entries());
    data.autoRefresh = form.autoRefresh.checked;
    data.refreshFixedInterval = form.refreshFixedInterval.checked;
    data.panelFloating = form.panelFloating.checked;
    data.refreshMinutes = Number(data.refreshMinutes);
    data.warningThreshold = Number(data.warningThreshold);
    await api("/api/settings", data);
    render();
  };
}

function renderRail() {
  if (state.settings && state.settings.panelFloating === false) { rail.classList.add("hidden"); return; }
  rail.classList.remove("hidden");
  const items = state.rail || [];
  rail.innerHTML = items.map((account) => `<button data-open="${account.id}" title="${escapeAttr(account.name)}">${ringHTML(account.ring)}</button>`).join("")
    + (state.railOverflow ? `<div class="muted">+${state.railOverflow}</div>` : "");
  rail.querySelectorAll("[data-open]").forEach((button) => button.onclick = () => {
    page = "agents";
    document.querySelectorAll("nav button").forEach((item) => item.classList.toggle("active", item.dataset.page === "agents"));
    render();
  });
}

function bindFilters() {
  const input = document.querySelector("#q");
  const health = document.querySelector("#health");
  if (!input) return;
  const apply = () => {
    sessionStorage.setItem("q", input.value);
    const grid = document.querySelector(".grid");
    if (!grid) return;
    const visible = accounts().filter(matchFilter);
    grid.innerHTML = visible.map(cardHTML).join("") || `<div class="panel">还没有 Agent。到「平台接入」添加，或导入快照文件。</div>`;
    bindCards();
  };
  input.oninput = apply;
  health.onchange = apply;
}

function bindCards() {
  main.querySelectorAll("[data-grok]").forEach((button) => button.onclick = async () => {
    button.disabled = true;
    button.textContent = "正在读取本机额度…";
    try { await api("/api/grokbot/read", { id: button.dataset.grok }); }
    finally { render(); }
  });
  main.querySelectorAll("[data-refresh]").forEach((button) => button.onclick = async () => {
    await api("/api/accounts/refresh", { id: button.dataset.refresh });
    render();
  });
}

async function boot() {
  if (!state || !state.persisted) {
    try { await api("/api/library/create", {}); } catch (error) { /* 已存在或只读时继续读取状态 */ }
  }
  const response = await fetch("/api/state", { headers: { "X-Gao-Token": token } });
  state = await response.json();
  render();
}
boot();
