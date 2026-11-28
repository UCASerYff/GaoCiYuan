'use strict';

const token = document.querySelector('[name="gao-token"]').content;
const shell = document.querySelector('#shell');
const rail = document.querySelector('#rail');
const railContent = document.querySelector('#rail-content');
const rings = document.querySelector('#rings');
const grip = document.querySelector('#grip');
const options = document.querySelector('#panel-options');
const detail = document.querySelector('#detail');
const menu = document.querySelector('#menu');
const empty = document.querySelector('#empty-rail');
const overflow = document.querySelector('#overflow');
const darkMode = matchMedia('(prefers-color-scheme: dark)');
const arcColours = new Set(['teal', 'iris', 'orange', 'coral', 'deepseek', 'workbuddy', 'secondary', 'amber']);
const numberFormat = new Intl.NumberFormat('zh-CN', { maximumFractionDigits: 2 });
const refreshModes = new Set(['connector', 'file']);
const pending = new Set();
const feedback = new Map();
const providerModes = new Map();

let state;
let lastPayload = '';
let lookingAt = '';
let focusID = '';
let focusRestoring = false;
let loadSequence = 0;
let sentSize = '';
let nextFrame;
let closeTimer;
let dragging = false;
let moving = false;

async function api(path, payload) {
  const response = await fetch('/api/' + path, {
    method: payload ? 'POST' : 'GET',
    headers: { 'X-Gao-Token': token, ...(payload ? { 'Content-Type': 'application/json' } : {}) },
    body: payload ? JSON.stringify(payload) : undefined,
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || '操作失败');
  return result;
}

function node(tag, text, className) {
  const element = document.createElement(tag);
  if (text) element.textContent = text;
  if (className) element.className = className;
  return element;
}

function actionButton(label, action, className) {
  const button = node('button', label, className);
  button.type = 'button';
  button.dataset.action = action;
  return button;
}

function theme() {
  const appearance = state?.settings.appearance || 'system';
  document.documentElement.dataset.theme = appearance === 'system' ? (darkMode.matches ? 'dark' : 'light') : appearance;
}

function requestSizing() {
  if (nextFrame !== undefined) return;
  nextFrame = requestAnimationFrame(() => {
    nextFrame = undefined;
    size();
  });
}

function size() {
  const top = shell.dataset.dock === 'top';
  shell.style.setProperty('--rail-width', rail.offsetWidth + 'px');
  shell.style.setProperty('--rail-height', rail.offsetHeight + 'px');
  const card = detail.hidden ? (menu.hidden ? null : menu) : detail;
  const gap = 8;
  const width = rail.offsetWidth + (top ? railContent.scrollWidth - railContent.clientWidth : 0);
  const height = rail.offsetHeight + (top ? 0 : railContent.scrollHeight - railContent.clientHeight);
  const desiredCardWidth = card ? parseInt(getComputedStyle(card).getPropertyValue('--card-width'), 10) : 0;
  const payload = {
    width: Math.min(1500, Math.max(36, width)),
    height: Math.min(1500, Math.max(36, height)),
    detailWidth: card ? desiredCardWidth + (top ? 0 : gap) : 0,
    detailHeight: card ? Math.min(760, Math.max(card.offsetHeight, card.scrollHeight + 2)) + (top ? gap : 0) : 0,
  };
  const key = JSON.stringify(payload);
  if (key === sentSize) return;
  sentSize = key;
  api('panel/size', payload).catch(() => { if (sentSize === key) sentSize = ''; });
}

function drawRing(ring) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'ring');
  svg.setAttribute('viewBox', '0 0 40 40');
  svg.setAttribute('aria-hidden', 'true');
  function circle(radius, className, fill) {
    const shape = document.createElementNS(svg.namespaceURI, 'circle');
    for (const [key, value] of Object.entries({ cx: 20, cy: 20, r: radius, class: className, pathLength: 1 })) shape.setAttribute(key, value);
    if (fill != null) shape.setAttribute('stroke-dasharray', Math.max(0, Math.min(1, fill)) + ' 1');
    svg.append(shape);
  }
  circle(16.6, 'track');
  if (!ring.showsDash && ring.fill > 0) circle(16.6, 'progress', ring.fill);
  if (!ring.stale && ring.windowElapsed > 0) circle(19, 'clock', ring.windowElapsed);
  return svg;
}

function providerIcon(account) {
  const icon = node('img');
  icon.alt = '';
  icon.className = 'provider-icon--' + account.provider;
  icon.src = '/brand/' + (account.provider === 'claude' ? 'claude-native-white-flower' : encodeURIComponent(account.provider)) + '.png';
  icon.addEventListener('error', () => icon.replaceWith(node('b', account.name.charAt(0))), { once: true });
  return icon;
}

function arc(ring) {
  return 'var(--' + (arcColours.has(ring.color) ? ring.color : 'secondary') + ')';
}

function accountConnection(account) {
  return providerModes.get(account?.provider)?.[account?.connection];
}

function openAccount(account) {
  if (!account) return;
  const connection = accountConnection(account);
  openPage(connection?.legacy || connection?.mode === 'antigravity-report' ? 'agents' : 'overview', account.id);
}

function itemFor(account) {
  const button = actionButton('', '', 'item');
  button.dataset.id = account.id;
  button.setAttribute('aria-controls', 'detail');
  const face = node('span', '', 'face');
  face.append(providerIcon(account));
  button.append(face, node('span', '', 'percent'));
  button.addEventListener('pointerenter', () => {
    if (menu.hidden && !detail.contains(document.activeElement)) showDetails(account.id);
  });
  button.addEventListener('focus', () => {
    focusID = account.id;
    updateTabOrder();
    if (!focusRestoring) showDetails(account.id);
  });
  button.addEventListener('click', () => {
    closeOverlays();
    openAccount(account);
  });
  button.addEventListener('keydown', moveFocus);
  return button;
}

function updateItem(button, account) {
  const connection = accountConnection(account);
  const legacy = connection?.legacy === true;
  const reportOnly = connection?.mode === 'antigravity-report' && !account.snapshot;
  const ring = legacy || reportOnly ? { label: '—', color: 'secondary', showsDash: true } : account.ring;
  const status = legacy ? 'macOS 旧版连接'
    : reportOnly ? (account.antigravityReport ? '历史报告 · 采集时间未验证' : '待导入报告')
    : ring.stale ? '历史读数' : (ring.showsDash ? '尚未获取额度' : '剩余 ' + ring.label);
  button.dataset.state = ring.stale ? 'stale' : (ring.showsDash ? 'empty' : 'current');
  button.title = account.name + ' · ' + status;
  button.setAttribute('aria-label', button.title);
  button.setAttribute('aria-expanded', String(lookingAt === account.id));
  button.style.setProperty('--arc', arc(ring));
  const face = button.querySelector('.face');
  face.querySelector('svg')?.remove();
  face.prepend(drawRing(ring));
  button.querySelector('.percent').textContent = ring.label;
}

function updateTabOrder() {
  for (const button of rings.children) button.tabIndex = button.dataset.id === focusID ? 0 : -1;
}

function drawRail() {
  const existing = new Map(Array.from(rings.children, button => [button.dataset.id, button]));
  for (const [index, account] of state.rail.entries()) {
    const item = existing.get(account.id) || itemFor(account);
    updateItem(item, account);
    if (rings.children[index] !== item) rings.insertBefore(item, rings.children[index] || null);
    existing.delete(account.id);
  }
  for (const removed of existing.values()) removed.remove();
  if (!state.rail.some(account => account.id === focusID)) focusID = state.rail[0]?.id || '';
  updateTabOrder();
  empty.hidden = state.rail.length > 0;
  overflow.hidden = !state.railOverflow;
  overflow.textContent = '+' + (state.railOverflow || 0);
  overflow.setAttribute('aria-label', '另有 ' + (state.railOverflow || 0) + ' 个账户，打开总览');
}

function moveFocus(event) {
  const directions = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
  const direction = directions[event.key];
  if (!direction) return;
  const [x, y] = direction;
  const origin = event.currentTarget.getBoundingClientRect();
  let target;
  let closest = Infinity;
  for (const item of rings.children) {
    if (item === event.currentTarget) continue;
    const rect = item.getBoundingClientRect();
    const dx = rect.left - origin.left;
    const dy = rect.top - origin.top;
    const forward = dx * x + dy * y;
    const across = dx * y - dy * x;
    if (forward <= 1 || Math.abs(across) >= forward) continue;
    const distance = forward + Math.abs(across) * 3;
    if (distance < closest) {
      closest = distance;
      target = item;
    }
  }
  if (target) {
    event.preventDefault();
    target.focus();
  }
}

function openPage(page, account) {
  api('window/open', { page, account }).catch(() => {});
}

function restoreFocus(element) {
  if (!element) return;
  focusRestoring = true;
  element.focus({ preventScroll: true });
  focusRestoring = false;
}

function closeOverlays(restore = false) {
  const menuWasOpen = !menu.hidden;
  const detailID = lookingAt;
  detail.hidden = true;
  menu.hidden = true;
  options.setAttribute('aria-expanded', 'false');
  lookingAt = '';
  for (const button of rings.children) button.setAttribute('aria-expanded', 'false');
  if (restore) restoreFocus(menuWasOpen ? options : Array.from(rings.children).find(item => item.dataset.id === detailID));
  requestSizing();
}

function openMenu(focus = false) {
  clearTimeout(closeTimer);
  closeOverlays();
  menu.hidden = false;
  options.setAttribute('aria-expanded', 'true');
  menu.querySelector('[data-action="columns"]').textContent = state?.settings.panelTwoColumns ? '切换为单列' : '切换为双列';
  if (focus) menu.querySelector('button').focus({ preventScroll: true });
  requestSizing();
}

function formatDate(value) {
  const date = new Date(value);
  if (!value || !Number.isFinite(+date)) return null;
  const options = { month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' };
  try {
    return new Intl.DateTimeFormat('zh-CN', { ...options, timeZone: state?.settings.timeZone }).format(date);
  } catch {
    return new Intl.DateTimeFormat('zh-CN', options).format(date);
  }
}

function timeLine(label, value, className) {
  const line = node('p', '', className);
  const printed = formatDate(value);
  if (!printed) {
    line.textContent = label;
    return line;
  }
  const time = node('time', printed);
  time.dateTime = value;
  line.append(label + ' ', time);
  return line;
}

function meter(percent) {
  const bar = node('div', '', 'progress-bar');
  bar.setAttribute('aria-hidden', 'true');
  const fill = node('span');
  fill.style.width = percent + '%';
  bar.append(fill);
  return bar;
}

function hero(title, value, meaning, tone, percent, resetAt) {
  const card = node('div', '', 'quota-hero');
  card.style.setProperty('--metric', tone);
  const amount = node('div', '', 'quota-amount');
  amount.append(node('strong', value), node('span', meaning, 'quota-unit'));
  card.append(node('div', title, 'quota-heading'), amount);
  if (percent !== undefined) {
    card.append(meter(percent), timeLine(resetAt ? '重置' : '平台未提供重置时间', resetAt, 'reset-line'));
  }
  return card;
}

function remaining(quota) {
  return Math.max(0, Math.min(100, 100 - quota.usedPercent));
}

function readableQuota(quota, now) {
  return Number.isFinite(quota.usedPercent) && (!quota.resetsAt || +new Date(quota.resetsAt) > now);
}

function quotaRow(quota, stale) {
  const entry = node('div');
  const line = node('div', '', 'reading-line');
  const value = remaining(quota);
  if (stale) entry.style.setProperty('--metric', 'var(--secondary)');
  line.append(node('span', quota.title), node('strong', Math.floor(value) + '%'));
  entry.append(line, meter(value), timeLine(quota.resetsAt ? '重置' : '平台未提供重置时间', quota.resetsAt, 'reset-line'));
  return entry;
}

function blank(title, message) {
  const result = node('div', '', 'empty-detail');
  result.append(node('strong', title));
  if (message) result.append(node('p', message));
  return result;
}

function renderGrok(account, area) {
  const reading = account.grokBotManualReading;
  const ring = account.ring;
  if (ring.showsDash || !Number.isFinite(ring.remainingPercent)) {
    area.append(blank('尚未读取本机额度', account.grokStatus || '可手动读取本机额度记录。'));
    return;
  }
  area.append(hero('本周额度', ring.label, '剩余', arc(ring), ring.remainingPercent, reading?.resetsAt));
  const context = [];
  if (Number.isFinite(ring.usedPercent)) context.push('已用 ' + numberFormat.format(ring.usedPercent) + '%');
  if (reading?.sharedWithOtherApps) context.push('与套餐内其他应用共享');
  if (context.length) area.append(node('p', context.join(' · '), 'notice'));
  const source = node('div', '', 'reading-source');
  source.append(node('p', '来源 · Grok Bot 本机额度记录'));
  if (reading?.capturedAt) source.append(timeLine('采集于', reading.capturedAt));
  if (ring.stale && account.grokStatus) source.append(node('p', account.grokStatus));
  area.append(source);
}

function measureRows(snapshot, omitFirstBalance) {
  const values = [
    ...(snapshot.creditBalances || []).map(item => ({ title: item.title, value: item.value, unit: item.unit })),
    ...(snapshot.balances || []).slice(omitFirstBalance ? 1 : 0).map(item => ({ title: '余额', value: item.value, unit: item.currency })),
    ...(snapshot.costs || []).map(item => ({ title: '统计期费用', value: item.value, unit: item.currency })),
  ].filter(item => Number.isFinite(item.value));
  const list = node('div', '', 'measure-list');
  for (const item of values) {
    const line = node('div', '', 'measure-line');
    line.append(node('span', item.title), node('strong', [numberFormat.format(item.value), item.unit].filter(Boolean).join(' ')));
    list.append(line);
  }
  return list;
}

function renderSnapshot(account, area) {
  const snapshot = account.snapshot;
  if (!snapshot) {
    const status = account.statusNote;
    area.append(blank('尚未获取额度', status && !/^尚未获取.*(?:用量|额度)/.test(status) ? status : ''));
    return;
  }
  const quotas = (snapshot.quotas || []).filter(quota => readableQuota(quota, Date.now()));
  const ring = account.ring;
  const stale = Boolean(ring.stale || account.stale);
  let usedBalance = false;
  if (quotas.length) {
    const lead = quotas.reduce((a, b) => a.usedPercent >= b.usedPercent ? a : b);
    const value = remaining(lead);
    area.append(hero(lead.title, Math.floor(value) + '%', '剩余', stale ? 'var(--secondary)' : arc(ring), value, lead.resetsAt));
    if (quotas.length > 1) {
      const list = node('div', '', 'readings');
      for (const quota of quotas) if (quota !== lead) list.append(quotaRow(quota, stale));
      area.append(list);
    }
  } else if (!ring.showsDash && (ring.kind === 'dsh' || ring.kind === 'workbuddy')) {
    area.append(hero(ring.kind === 'dsh' ? '钱包余额' : '积分余额', ring.label, '剩余', arc(ring)));
    usedBalance = true;
  } else if (snapshot.quotas?.length) {
    area.append(blank('额度窗口已重置', '等待平台返回下一周期的读数。'));
  }
  const measures = measureRows(snapshot, usedBalance);
  if (measures.childElementCount) area.append(measures);
  if (!area.childElementCount) area.append(blank('本次采集未返回额度'));
  if (snapshot.source || snapshot.observedAt) {
    const source = node('div', '', 'reading-source');
    if (snapshot.source) source.append(node('p', '来源 · ' + snapshot.source));
    if (snapshot.observedAt) source.append(timeLine('采集于', snapshot.observedAt));
    area.append(source);
  }
}

function renderDetails(account) {
  const previousAction = detail.contains(document.activeElement) ? document.activeElement.dataset.action : '';
  const ring = account.ring;
  const header = node('header', '', 'detail-header');
  const mark = node('span', '', 'provider-mark');
  mark.append(providerIcon(account));
  const names = node('div');
  const title = node('h2', account.name, 'detail-title');
  title.id = 'detail-title';
  names.append(title);
  const meta = node('div', '', 'account-meta');
  const plan = account.plan || account.grokBotManualReading?.plan;
  if (plan) meta.append(node('span', plan, 'plan'));
  if (ring.stale || account.stale) meta.append(node('span', '历史读数', 'status status--stale'));
  else if (ring.kind === 'grokbot' && !ring.showsDash) meta.append(node('span', '手动快照', 'status'));
  if (meta.childElementCount) names.append(meta);
  const collapse = actionButton('×', 'close', 'close-detail');
  collapse.setAttribute('aria-label', '关闭额度详情');
  header.append(mark, names, collapse);
  const area = node('div');
  const grok = ring.kind === 'grokbot';
  const connection = accountConnection(account);
  if (connection?.legacy) {
    area.append(blank('macOS 旧版连接', '原账户和历史资料已保留，可在账户明细查看。'));
  } else if (connection?.mode === 'antigravity-report' && !account.snapshot) {
    area.append(blank(account.antigravityReport ? '历史报告 · 采集时间未验证' : '待导入报告', '可在账户明细导入或查看历史报告。'));
  } else if (grok) renderGrok(account, area);
  else renderSnapshot(account, area);

  if (account.statusNote && (grok ? Boolean(account.grokBotManualReading && account.statusNote !== account.grokStatus) : Boolean(account.snapshot))) {
    area.append(node('p', account.statusNote, 'notice'));
  }
  const problem = feedback.get(account.id) || account.error;
  if (problem) {
    const message = node('p', problem, 'notice notice--error');
    message.setAttribute('role', 'status');
    area.append(message);
  }

  const actions = node('div', '', 'detail-actions');
  if (grok || refreshModes.has(connection?.mode)) {
    const running = pending.has(account.id);
    const refresh = actionButton(running ? (grok ? '正在读取…' : '刷新中…') : (grok ? '读取本机额度' : '刷新额度'),
      grok ? 'manual-read' : 'refresh', 'primary-action');
    refresh.disabled = running || account.enabled === false;
    actions.append(refresh);
  }
  actions.append(actionButton('查看账户', 'account', 'secondary-action'));
  detail.replaceChildren(header, area, actions);
  if (previousAction) restoreFocus(detail.querySelector('[data-action="' + previousAction + '"]:not(:disabled)'));
  requestSizing();
}

function showDetails(id) {
  clearTimeout(closeTimer);
  const account = state?.rail.find(item => item.id === id);
  if (!account || dragging || (lookingAt === id && !detail.hidden)) return;
  lookingAt = id;
  menu.hidden = true;
  options.setAttribute('aria-expanded', 'false');
  detail.hidden = false;
  for (const button of rings.children) button.setAttribute('aria-expanded', String(button.dataset.id === id));
  renderDetails(account);
}

async function refreshAccount(action, id, trigger) {
  if (pending.has(id)) return;
  const returnFocus = trigger === document.activeElement;
  pending.add(id);
  feedback.delete(id);
  renderDetails(state.rail.find(account => account.id === id));
  try {
    await api(action === 'manual-read' ? 'grokbot/read' : 'accounts/refresh', { id });
    await load();
  } catch (error) {
    feedback.set(id, error.message);
  } finally {
    pending.delete(id);
    const current = state?.rail.find(account => account.id === id);
    if (lookingAt === id && current && !detail.hidden) {
      renderDetails(current);
      if (returnFocus) restoreFocus(detail.querySelector('[data-action="' + action + '"]:not(:disabled)'));
    }
  }
}

async function load() {
  const sequence = ++loadSequence;
  const incoming = await api('panel').catch(() => null);
  if (sequence !== loadSequence || !incoming) return;
  const signature = JSON.stringify(incoming);
  if (signature === lastPayload) {
    requestSizing();
    return;
  }
  lastPayload = signature;
  state = incoming;
  theme();
  shell.dataset.dock = state.settings.panelDock;
  rail.style.setProperty('--columns', state.settings.panelTwoColumns ? 2 : 1);
  drawRail();
  const current = state.rail.find(account => account.id === lookingAt);
  if (current) renderDetails(current);
  else if (lookingAt) closeOverlays();
  requestSizing();
}

shell.addEventListener('pointerleave', () => {
  if (!dragging) closeTimer = setTimeout(() => {
    if (!shell.contains(document.activeElement) || !document.activeElement.matches(':focus-visible')) closeOverlays();
  }, 190);
});
shell.addEventListener('pointerenter', () => clearTimeout(closeTimer));
shell.addEventListener('focusout', () => {
  setTimeout(() => {
    if (!shell.contains(document.activeElement) && !shell.matches(':hover') && !dragging) closeOverlays();
  }, 0);
});
shell.addEventListener('keydown', event => {
  if (event.key === 'Escape' && (!detail.hidden || !menu.hidden)) {
    event.preventDefault();
    closeOverlays(true);
  }
});
rail.addEventListener('contextmenu', event => {
  event.preventDefault();
  openMenu(event.button === 0);
});
options.addEventListener('click', event => {
  if (menu.hidden) openMenu(event.detail === 0);
  else closeOverlays(true);
});
menu.addEventListener('click', async event => {
  const action = event.target.closest('button')?.dataset.action;
  if (!action) return;
  if (action === 'open') openPage('overview');
  if (action === 'settings') openPage('settings');
  try {
    if (action === 'hide') await api('settings', { panelFloating: false });
    if (action === 'columns' && state) await api('settings', { panelTwoColumns: !state.settings.panelTwoColumns });
  } finally {
    closeOverlays(true);
    await load();
  }
});
detail.addEventListener('click', event => {
  const button = event.target.closest('button');
  const action = button?.dataset.action;
  if (action === 'close') closeOverlays(true);
  if (action === 'account') {
    openAccount(state?.rail.find(item => item.id === lookingAt));
    closeOverlays();
  }
  if (action === 'manual-read' || action === 'refresh') refreshAccount(action, lookingAt, button);
});
overflow.addEventListener('click', () => openPage('overview'));
empty.addEventListener('click', () => openPage('catalog'));

grip.addEventListener('pointerdown', async event => {
  if (event.button !== 0 || !window.pywebview?.api) return;
  grip.setPointerCapture(event.pointerId);
  dragging = true;
  closeOverlays();
  await window.pywebview.api.drag_start();
});
grip.addEventListener('pointermove', async () => {
  if (!dragging || moving) return;
  moving = true;
  try { await window.pywebview.api.drag_move(); }
  finally { moving = false; }
});
async function endDrag() {
  if (!dragging) return;
  dragging = false;
  await window.pywebview.api.drag_end();
  await load();
}
grip.addEventListener('pointerup', endDrag);
grip.addEventListener('lostpointercapture', endDrag);

new ResizeObserver(requestSizing).observe(rail);
new ResizeObserver(requestSizing).observe(detail);
window.addEventListener('resize', requestSizing);
darkMode.addEventListener('change', theme);
api('catalog').then(catalog => {
  for (const item of catalog.providers || []) providerModes.set(item.id, item.connectionDetails);
  if (state) drawRail();
  const account = state?.rail.find(item => item.id === lookingAt);
  if (account) renderDetails(account);
}).catch(() => {});
theme();
load();
setInterval(load, 3000);
