import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import path from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const [cliPath, expectedVersion, evidencePath] = process.argv.slice(2);
assert(cliPath && expectedVersion && evidencePath, 'Pass the CLI executable, expected version and evidence directory.');
const workspace = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const build = path.join(workspace, 'build');
const evidence = path.resolve(evidencePath);
await mkdir(build, { recursive: true });
assert.equal(await realpath(build), await realpath(workspace) + path.sep + 'build');
await mkdir(evidence, { recursive: true });
const scratch = await mkdtemp(path.join(build, 'visual-smoke-'));
const dataDir = path.join(scratch, 'fixture data');
const profile = path.join(scratch, 'edge-profile');
const edgeExe = path.join(process.env['ProgramFiles(x86)'], 'Microsoft', 'Edge', 'Application', 'msedge.exe');

async function retry(test, message, timeout = 15000) {
  const deadline = Date.now() + timeout;
  let issue;
  while (Date.now() < deadline) {
    try {
      const value = await test();
      if (value) return value;
    } catch (error) { issue = error; }
    await delay(125);
  }
  throw new Error(message, { cause: issue });
}

async function stop(child) {
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  await Promise.race([once(child, 'exit'), delay(500)]);
  if (child.exitCode !== null || child.signalCode !== null) return;
  child.kill();
  await Promise.race([once(child, 'exit'), delay(3000)]);
}

async function reservePort() {
  const socket = createServer().listen(0, '127.0.0.1');
  await once(socket, 'listening');
  const { port } = socket.address();
  await new Promise(resolve => socket.close(resolve));
  return port;
}

const baseURL = `http://127.0.0.1:${await reservePort()}`;
let token;
async function api(endpoint, payload) {
  const response = await fetch(`${baseURL}${endpoint}`, {
    method: payload === undefined ? 'GET' : 'POST',
    headers: { 'X-Gao-Token': token, 'Content-Type': 'application/json' },
    ...(payload === undefined ? {} : { body: JSON.stringify(payload) }),
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`${endpoint} returned ${response.status}. ${await response.text()}`);
  return response.json();
}

const now = Date.now();
function instant(hours) { return new Date(now + hours * 3600000).toISOString(); }
function quota(id, title, usedPercent, resetHours, windowSeconds) {
  return { id, title, usedPercent, resetsAt: instant(resetHours), windowSeconds };
}

async function seed() {
  await api('/api/library/create', {});
  await api('/api/settings', { autoRefresh: false, language: 'zh-Hans', appearance: 'light' });
  const fixtures = [
    ['openai', 'Codex 工作区', 'Plus', -0.06, [quota('short', '5 小时窗口', 28, 1.8, 18000), quota('week', '每周额度', 52, 57, 604800)]],
    ['claude', 'Claude Code · 日常', 'Pro', -0.10, [quota('session', '5 小时窗口', 42, 2.7, 18000), quota('week', '每周额度', 23, 40, 604800)]],
    ['cursor', 'Cursor 项目开发', 'Pro', -0.11, [quota('month', '本月计划', 89, 29, 2592000)]],
    ['opencode', 'OpenCode Go', 'Go', -3, [quota('week', '每周额度', 57, 24, 604800)]],
  ];
  for (const [provider, name, plan, age, quotas] of fixtures) {
    const filePath = path.join(scratch, `${provider}.json`);
    await writeFile(filePath, JSON.stringify({ observedAt: instant(age), quotas }));
    await api('/api/accounts/save', { provider, name, plan, filePath, connection: '自动读取快照文件' });
  }
  const grok = await api('/api/accounts/save', { provider: 'grok', name: 'Grok Bot', plan: 'Premium', connection: '本机软件自动读取' });
  await writeFile(path.join(dataDir, 'grokbot-usage.json'), JSON.stringify({ schema: 1, source: 'grok-bot-usage-report', plan: 'Premium',
    capturedAt: instant(-0.1), weeklyPercentUsed: 19, sharedWithOtherApps: true, resetsAt: instant(29) }));
  const refreshed = await api('/api/accounts/refresh-all', {});
  assert.equal(refreshed.state.grokReads, 0);
  const manual = await api('/api/grokbot/read', { id: grok.result.id });
  assert.equal(manual.state.grokReads, 1);

  const logs = path.join(scratch, 'sessions');
  await mkdir(logs);
  const usage = [];
  for (let days = 6; days >= 0; days--) {
    const counts = { input_tokens: 350000 + days * 96000, cached_input_tokens: 88000 + days * 30200,
      output_tokens: 68000 + (6 % (days + 2)) * 36000, reasoning_output_tokens: 16000 + days * 3200 };
    usage.push({ type: 'session_meta', payload: { id: `design-fixture-${days}`, cwd: path.join(scratch, `project-${days}`) } });
    usage.push({ type: 'turn_context', payload: { model: days % 2 ? 'codex-fixture' : 'workspace-fixture' } });
    usage.push({ timestamp: instant(-24 * days - 1), type: 'event_msg', payload: { type: 'token_count',
      info: { total_token_usage: counts, last_token_usage: counts } } });
  }
  await writeFile(path.join(logs, 'rollout-design.jsonl'), usage.map(row => JSON.stringify(row)).join('\n') + '\n');
  await api('/api/usage/settings', {
    engine: { enabledClientIDs: ['codex'], customPaths: { codex: [logs] }, modelPrices: [
      { model: 'workspace-fixture', inputPerMillion: 2.25, outputPerMillion: 8, cacheReadPerMillion: 0.25 },
      { model: 'codex-fixture', inputPerMillion: 1.5, outputPerMillion: 7, cacheReadPerMillion: 0.2 },
    ] },
  });
  await api('/api/usage/scan', {});
  const dashboard = await api('/api/usage?range=7d');
  assert(dashboard.total.totalTokens > 500000);
}

class DevTools {
  constructor(socket) {
    this.socket = socket;
    this.nextID = 0;
    this.pending = new Map();
    this.errors = [];
    socket.addEventListener('message', ({ data }) => {
      const message = JSON.parse(data);
      if (message.method === 'Runtime.exceptionThrown') {
        this.errors.push(message.params.exceptionDetails.exception?.description ?? message.params.exceptionDetails.text);
      }
      const handle = this.pending.get(message.id);
      if (!handle) return;
      this.pending.delete(message.id);
      clearTimeout(handle.timer);
      if (message.error) handle.reject(new Error(message.error.message));
      else handle.resolve(message.result);
    });
  }

  send(method, params = {}) {
    const id = ++this.nextID;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timed out.`)); }, 12000);
      this.pending.set(id, { resolve, reject, timer });
      this.socket.send(JSON.stringify({ id, method, params }));
    });
  }

  async evaluate(expression) {
    const { result, exceptionDetails } = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (exceptionDetails) throw new Error(exceptionDetails.exception?.description ?? exceptionDetails.text);
    return result.value;
  }
}

let app;
let browser;
let socket;
try {
  app = spawn(path.resolve(cliPath), ['--data-dir', dataDir, '--no-refresh', '--serve', '--no-browser', '--port', new URL(baseURL).port],
    { windowsHide: true, stdio: ['ignore', 'ignore', 'inherit'] });
  token = await retry(async () => {
    const response = await fetch(baseURL, { signal: AbortSignal.timeout(2000) });
    return (await response.text()).match(/<meta name="gao-token" content="([A-Za-z0-9_-]+)">/)?.[1];
  }, 'Could not start the isolated application.');
  assert.equal((await api('/api/state')).version, expectedVersion);
  await seed();

  browser = spawn(edgeExe, ['--headless=new', '--disable-gpu', '--disable-background-networking', '--no-first-run', '--disable-extensions',
    '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'], { windowsHide: true, stdio: 'ignore' });
  const browserPort = await retry(async () => Number((await readFile(path.join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]), 'Edge did not start.');
  const target = await retry(async () => (await (await fetch(`http://127.0.0.1:${browserPort}/json/list`)).json()).find(item => item.type === 'page'), 'Edge has no page.');
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  const devtools = new DevTools(socket);
  await devtools.send('Page.enable');
  await devtools.send('Runtime.enable');

  async function capture(name, route, width, height, dpr = 1, clickSelector = null) {
    await devtools.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: dpr, mobile: false });
    await devtools.send('Page.navigate', { url: `${baseURL}/#${route}` });
    await retry(() => devtools.evaluate(`location.hash === ${JSON.stringify(`#${route}`)} && document.querySelector('#main[aria-busy="false"]')?.textContent.trim().length > 30`), `Page ${route} did not render.`);
    if (route === 'analytics') {
      await retry(() => devtools.evaluate(`document.querySelector('#usage-view')?.innerText.includes('workspace-fixture')`), 'The analytics fixtures did not render.');
    }
    if (clickSelector) {
      await retry(() => devtools.evaluate(`Boolean(document.querySelector(${JSON.stringify(clickSelector)}))`), `Missing control ${clickSelector}.`);
      await devtools.evaluate(`document.querySelector(${JSON.stringify(clickSelector)}).click()`);
      await delay(350);
    }
    await devtools.evaluate('document.fonts.ready.then(() => true)');
    await delay(180);
    const layout = await devtools.evaluate('({ width: innerWidth, scroll: document.documentElement.scrollWidth, ratio: devicePixelRatio })');
    assert.equal(layout.ratio, dpr);
    assert(layout.scroll <= layout.width, `${route} overflowed by ${layout.scroll - layout.width}px at ${width}px.`);
    const { data } = await devtools.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    await writeFile(path.join(evidence, `${name}.png`), Buffer.from(data, 'base64'));
    console.log(`${name}: ${width}×${height} @ ${dpr}`);
  }

  await capture('01-overview-light', 'overview', 1160, 760);
  await capture('02-agents-light', 'agents', 1160, 760);
  await capture('03-analytics-light', 'analytics', 1160, 840);
  await capture('04-catalog-light', 'catalog', 1160, 760);
  await capture('05-settings-light', 'settings', 1160, 760);
  if (expectedVersion !== '4.13+2') {
    await api('/api/settings', { appearance: 'dark' });
    await devtools.send('Page.navigate', { url: 'about:blank' });
    await capture('06-overview-dark-150', 'overview', 760, 600, 1.5);
    assert.equal(await devtools.evaluate('document.documentElement.dataset.appearance'), 'dark');
    await capture('07-analytics-dark-150', 'analytics', 760, 600, 1.5);
    await capture('08-settings-dark-150', 'settings', 760, 620, 1.5, '[data-action="settings-tab"][data-value="data"]');
    await capture('09-account-editor-dark-150', 'agents', 760, 620, 1.5, '#agent-inspector [data-action="edit"]');
  }
  assert.deepEqual(devtools.errors, []);
} finally {
  if (socket?.readyState === WebSocket.OPEN) {
    const closed = once(socket, 'close');
    socket.send(JSON.stringify({ id: 0, method: 'Browser.close' }));
    await Promise.race([closed, delay(2000)]);
    socket.close();
  }
  if (token) await api('/api/shutdown', {}).catch(() => {});
  await Promise.all([stop(browser), stop(app)]);
  await rm(scratch, { recursive: true, force: true, maxRetries: 8, retryDelay: 200 });
}
