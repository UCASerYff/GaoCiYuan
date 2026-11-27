'use strict';

const token = document.querySelector('[name="gao-token"]').content;
const shell = document.querySelector('#shell');
const rail = document.querySelector('#rail');
const rings = document.querySelector('#rings');
const grip = document.querySelector('#grip');
const detail = document.querySelector('#detail');
const menu = document.querySelector('#menu');
const overflow = document.querySelector('#overflow');
const darkMode = matchMedia('(prefers-color-scheme: dark)');
const colours = new Set(['teal', 'iris', 'orange', 'coral', 'deepseek', 'workbuddy', 'secondary', 'amber']);
let state = null;
let visibleKey = '';
let lookingAt = '';
let closeTimer;
let sentSize = '';
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

function theme() {
  const appearance = state?.settings.appearance || 'system';
  document.documentElement.dataset.theme = appearance === 'system' ? (darkMode.matches ? 'dark' : 'light') : appearance;
}

function size() {
  const card = detail.hidden ? (menu.hidden ? null : menu) : detail;
  const payload = { width: Math.max(rail.offsetWidth, rail.scrollWidth + 2), height: Math.max(rail.offsetHeight, rail.scrollHeight + 2), detailWidth: card ? card.offsetWidth + 8 : 0,
    detailHeight: card ? Math.min(780, card.scrollHeight + 10) : 0 };
  if (shell.dataset.dock === 'top' && card) payload.detailHeight += 8;
  const key = JSON.stringify(payload);
  if (key !== sentSize) {
    sentSize = key;
    api('panel/size', payload).catch(() => { sentSize = ''; });
  }
}

function drawRing(ring) {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('class', 'ring');
  svg.setAttribute('viewBox', '0 0 36 36');
  svg.setAttribute('aria-hidden', 'true');
  function circle(radius, className, fill) {
    const shape = document.createElementNS(svg.namespaceURI, 'circle');
    for (const [key, value] of Object.entries({ cx: 18, cy: 18, r: radius, class: className, pathLength: 1 })) shape.setAttribute(key, value);
    if (fill != null) shape.setAttribute('stroke-dasharray', `${Math.max(0, Math.min(1, fill))} 1`);
    svg.append(shape);
  }
  circle(15, 'track');
  if (!ring.showsDash && ring.fill > 0) circle(15, 'progress', ring.fill);
  if (ring.windowElapsed > 0) circle(17.4, 'clock', ring.windowElapsed);
  return svg;
}

function itemFor(account) {
  const ring = account.ring;
  const item = node('button', '', 'item');
  item.type = 'button';
  item.title = `${account.name} ${ring.label}`;
  item.setAttribute('aria-label', item.title);
  item.dataset.id = account.id;
  item.style.setProperty('--arc', `var(--${colours.has(ring.color) ? ring.color : 'secondary'})`);
  item.style.opacity = ring.opacity ?? 1;
  const face = node('span', '', 'face');
  face.append(drawRing(ring));
  const icon = document.createElement('img');
  icon.alt = '';
  icon.src = `/brand/${account.provider === 'claude' ? 'claude-native-white-flower' : encodeURIComponent(account.provider)}.png`;
  icon.addEventListener('error', () => icon.replaceWith(node('b', account.name.charAt(0))));
  face.append(icon);
  item.append(face, node('span', ring.label, 'percent'));
  item.addEventListener('pointerenter', () => showDetails(account.id));
  item.addEventListener('focus', () => showDetails(account.id));
  item.addEventListener('click', () => openPage('overview', account.id));
  return item;
}

function openPage(page, account) {
  api('window/open', { page, account }).catch(() => {});
}

function closeDetails() {
  detail.hidden = true;
  menu.hidden = true;
  lookingAt = '';
  size();
}

function showDetails(id) {
  clearTimeout(closeTimer);
  const account = state?.rail.find(item => item.id === id);
  if (!account || dragging) return;
  lookingAt = id;
  menu.hidden = true;
  detail.hidden = false;
  detail.replaceChildren(node('h2', account.name));
  if (account.plan) detail.append(node('p', account.plan));
  const snapshot = account.snapshot;
  if (account.ring.kind === 'grokbot') {
    detail.append(node('p', [account.ring.label, account.grokStatus].filter(Boolean).join('  ·  ')));
    const refresh = node('button', '读取本机额度');
    refresh.addEventListener('click', async () => {
      refresh.disabled = true;
      try {
        await api('grokbot/read', { id });
        await load();
      } catch (error) {
        detail.append(node('p', error.message));
      } finally { refresh.disabled = false; }
    });
    detail.append(refresh);
  } else if (snapshot) {
    for (const quota of snapshot.quotas || []) {
      if (typeof quota.usedPercent !== 'number' || quota.resetsAt && +new Date(quota.resetsAt) <= Date.now()) continue;
      const entry = node('div', '', 'reading');
      const line = node('div', '', 'line');
      const remaining = Math.max(0, Math.min(100, 100 - quota.usedPercent));
      line.append(node('span', quota.title), node('strong', `${Math.floor(remaining)}%`));
      const bar = node('div', '', 'bar');
      const fill = node('span');
      fill.style.width = `${remaining}%`;
      bar.append(fill);
      entry.append(line, bar);
      if (quota.resetsAt) entry.append(node('small', `重置 ${new Date(quota.resetsAt).toLocaleString()}`));
      detail.append(entry);
    }
    for (const balance of snapshot.balances || []) detail.append(node('p', `${balance.label || '余额'} ${balance.text || balance.value} ${balance.currency || ''}`));
    if (snapshot.observedAt) detail.append(node('p', `${snapshot.source || ''} · ${new Date(snapshot.observedAt).toLocaleString()}`));
  } else {
    detail.append(node('p', account.statusNote || '等待额度读数'));
  }
  if (account.error) detail.append(node('p', account.error));
  size();
}

async function load() {
  const incoming = await api('panel').catch(() => null);
  if (!incoming) return;
  const key = JSON.stringify(incoming);
  if (key === visibleKey) return;
  visibleKey = key;
  state = incoming;
  theme();
  shell.dataset.dock = state.settings.panelDock;
  rail.style.setProperty('--columns', state.settings.panelTwoColumns ? 2 : 1);
  rings.replaceChildren(...state.rail.map(itemFor));
  overflow.hidden = state.rail.length > 0 && !state.railOverflow;
  overflow.textContent = state.railOverflow ? `+${state.railOverflow}` : '搞词元';
  if (lookingAt && state.rail.some(item => item.id === lookingAt)) showDetails(lookingAt);
  else if (lookingAt) closeDetails();
  size();
}

shell.addEventListener('pointerleave', () => { if (!dragging) closeTimer = setTimeout(closeDetails, 190); });
shell.addEventListener('pointerenter', () => clearTimeout(closeTimer));
rail.addEventListener('contextmenu', event => {
  event.preventDefault();
  detail.hidden = true;
  menu.hidden = false;
  size();
});
menu.addEventListener('click', async event => {
  const action = event.target.dataset.action;
  if (!action) return;
  if (action === 'open') openPage('overview');
  if (action === 'settings') openPage('settings');
  if (action === 'hide') await api('settings', { panelFloating: false });
  if (action === 'columns') await api('settings', { panelTwoColumns: !state.settings.panelTwoColumns });
  closeDetails();
  await load();
});
overflow.addEventListener('click', () => openPage('overview'));
grip.addEventListener('pointerdown', async event => {
  if (event.button !== 0 || !window.pywebview?.api) return;
  grip.setPointerCapture(event.pointerId);
  dragging = true;
  closeDetails();
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
darkMode.addEventListener('change', theme);
load();
setInterval(load, 3000);
