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
const [marketingVersion, buildNumber] = expectedVersion.split('+');
const testAntigravitySync = Number(marketingVersion) >= 4.15;
const testAntigravity = testAntigravitySync || (marketingVersion === '4.14' && Number(buildNumber) >= 7);
const legacyAntigravityID = '0c7814a8-4f46-4d73-93b8-e5e2747d2bef';
const legacyAntigravityConnection = 'Gemini App 中的 Antigravity';
const antigravityConnection = 'Antigravity 独立版 /usage 报告';

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

async function seedLegacyAntigravity() {
  const snapshot = { observedAt: instant(-0.05), source: 'Older macOS fixture',
    quotas: [quota('five', 'Gemini Models · 5 小时', 33, 1.5, 18000)], balances: [], costs: [] };
  await mkdir(dataDir, { recursive: true });
  await writeFile(path.join(dataDir, 'library.json'), JSON.stringify({
    schema: 1, autoRefresh: false, refreshMinutes: 5, warningThreshold: 20,
    accounts: [{ id: legacyAntigravityID, provider: 'gemini', kind: 'Agent', name: 'Gemini 旧账户',
      plan: '旧版套餐', enabled: true, connection: legacyAntigravityConnection, snapshot, history: [snapshot] }],
  }));
}

async function seed() {
  if (!testAntigravity) await api('/api/library/create', {});
  await api('/api/settings', { autoRefresh: false, language: 'zh-Hans', appearance: 'light' });
  const fixtures = [
    ['openai', 'Codex 工作区', 'Plus', -0.06, [quota('short', '5 小时窗口', 28, 1.8, 18000), quota('week', '每周额度', 52, 57, 604800)]],
    ['claude', 'Claude Code · 日常', 'Pro', -0.10, [quota('session', '5 小时窗口', 42, 2.7, 18000), quota('week', '每周额度', 23, 40, 604800)]],
    ['cursor', 'Cursor 项目开发', 'Pro', -0.11, [quota('month', '本月计划', 89, 29, 2592000)]],
    ['opencode', 'OpenCode Go', 'Go', -3, [quota('week', '每周额度', 57, 24, 604800)]],
  ];
  let codexID;
  for (const [provider, name, plan, age, quotas] of fixtures) {
    const filePath = path.join(scratch, `${provider}.json`);
    await writeFile(filePath, JSON.stringify({ observedAt: instant(age), quotas }));
    const saved = await api('/api/accounts/save', { provider, name, plan, filePath, connection: '自动读取快照文件' });
    if (provider === 'openai') codexID = saved.result.id;
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
  return codexID;
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
  if (testAntigravity) await seedLegacyAntigravity();
  app = spawn(path.resolve(cliPath), ['--data-dir', dataDir, '--no-refresh', '--serve', '--no-browser', '--port', new URL(baseURL).port],
    { windowsHide: true, stdio: ['ignore', 'ignore', 'inherit'] });
  token = await retry(async () => {
    const response = await fetch(baseURL, { signal: AbortSignal.timeout(2000) });
    return (await response.text()).match(/<meta name="gao-token" content="([A-Za-z0-9_-]+)">/)?.[1];
  }, 'Could not start the isolated application.');
  assert.equal((await api('/api/state')).version, expectedVersion);
  const codexID = await seed();

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
  const agentRoute = testAntigravity ? `agents?account=${codexID}` : 'agents';
  await capture('02-agents-light', agentRoute, 1160, 760);
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
    await capture('09-account-editor-dark-150', agentRoute, 760, 620, 1.5, '#agent-inspector [data-action="edit"]');
  }
  if (testAntigravity) {
    await devtools.send('Page.navigate', { url: `${baseURL}/#agents?account=${legacyAntigravityID}` });
    await retry(() => devtools.evaluate(`document.querySelector('#agent-inspector .account-card')?.id === 'inspecting-${legacyAntigravityID}'`),
      'Legacy Gemini details did not open.');
    const legacy = await devtools.evaluate(`(() => {
      const inspector = document.querySelector('#agent-inspector');
      return { text: inspector.innerText, liveControls: !!inspector.querySelector('[data-action="refresh"], [data-action="antigravity-import"]') };
    })()`);
    assert.match(legacy.text, /macOS 旧版连接/);
    assert.match(legacy.text, /Older macOS fixture/);
    assert.doesNotMatch(legacy.text, /实测额度/);
    assert.equal(legacy.liveControls, false);
    await devtools.evaluate(`document.querySelector('#agent-inspector [data-action="add-antigravity"]').click()`);
    const newAccountControls = await devtools.evaluate(`(() => ({
      choices: [...document.querySelector('#account-editor [name="connection"]').options].map(option => option.value),
      link: document.querySelector('#account-editor .antigravity-links a').href,
      liveTest: !!document.querySelector('#account-editor [data-action="test-account"]'),
    }))()`);
    assert.deepEqual(newAccountControls.choices, [antigravityConnection]);
    assert.match(newAccountControls.link, /^https:\/\/antigravity\.google\/docs\//);
    assert.equal(newAccountControls.liveTest, false);
    await devtools.evaluate(`document.querySelector('#account-editor [name="name"]').value = 'Antigravity 报告账户';
      document.querySelector('#account-editor button[type="submit"]').click()`);
    const standalone = await retry(async () => (await api('/api/state')).accounts.find(account => account.connection === antigravityConnection),
      'Could not create a separate standalone account.');
    assert.notEqual(standalone.id, legacyAntigravityID);
    const route = `agents?account=${standalone.id}`;
    await devtools.send('Page.navigate', { url: `${baseURL}/#${route}` });
    await retry(() => devtools.evaluate(`Boolean(document.querySelector('#agent-inspector [data-action="antigravity-import"]'))`),
      'Standalone import action was unavailable.');
    await devtools.evaluate(`document.querySelector('#agent-inspector [data-action="antigravity-import"]').click()`);
    assert.match(await devtools.evaluate(`document.querySelector('.antigravity-target').innerText`), /Antigravity 报告账户/);
    assert.match(await devtools.evaluate(`document.querySelector('#antigravity-import-warning').innerText`), /文件来源、所属账号与额度采集时间均未经验证/);
    assert.match(await devtools.evaluate(`document.querySelector('#antigravity-import-form [name="report"]').accept`), /\.json.*\.txt/);
    const fixture = path.join(scratch, 'report.txt');
    const secondSelection = path.join(scratch, 'second-report.txt');
    const report = 'Fixture owner: antigravity-fixture@example.invalid\nGemini Models\nFive Hour Limit Remaining: 75.5%\nClaude and GPT models\nWeekly Limit Remaining: 42%';
    await Promise.all([writeFile(fixture, report), writeFile(secondSelection, report)]);
    const isConfirmDisabled = () => devtools.evaluate(`document.querySelector('#antigravity-import-form button[type="submit"]').disabled`);
    const selectFile = async file => {
      const { root } = await devtools.send('DOM.getDocument');
      const { nodeId } = await devtools.send('DOM.querySelector', { nodeId: root.nodeId, selector: '#antigravity-import-form [name="report"]' });
      await devtools.send('DOM.setFileInputFiles', { nodeId, files: [file] });
    };
    await selectFile(fixture);
    assert.equal(await isConfirmDisabled(), true);
    await devtools.evaluate(`document.querySelector('#antigravity-import-form [name="confirmed"]').click()`);
    assert.equal(await isConfirmDisabled(), false);
    await selectFile(secondSelection);
    assert.equal(await isConfirmDisabled(), true);
    assert.deepEqual(await devtools.evaluate('window.gaociyuanExitState()'), { dirty: true, pending: false });
    assert.equal((await api('/api/state')).accounts.find(account => account.id === standalone.id).antigravityReport, null);
    await devtools.evaluate(`document.querySelector('#antigravity-import-form [name="confirmed"]').click();
      document.querySelector('#antigravity-import-form button[type="submit"]').click()`);
    await retry(() => devtools.evaluate(`!document.querySelector('#dialog').open && Boolean(document.querySelector('#agent-inspector .antigravity-report-quotas'))`),
      'The confirmed report did not render.');
    const display = await devtools.evaluate(`document.querySelector('#agent-inspector .account-reading').innerText`);
    assert.match(display, /历史报告 · 采集时间未验证/);
    assert.match(display, /报告导入时间/);
    assert.match(display, /导入方式 · Antigravity 独立版 \/usage 手动报告/);
    assert.match(display, /报告记录剩余 75\.5%/);
    assert.match(display, /报告记录剩余 42%/);
    assert.doesNotMatch(display, /实测额度|报告所列重置时间|antigravity-fixture@example\.invalid/);

    await devtools.evaluate(`document.querySelector('#agent-inspector [data-action="antigravity-import"]').click()`);
    const jsonFixture = path.resolve(workspace, '..', 'Tests', 'Fixtures', 'AntigravityCLIUsage.json');
    await selectFile(jsonFixture);
    assert.equal(await isConfirmDisabled(), true);
    await devtools.evaluate(`document.querySelector('#antigravity-import-form [name="confirmed"]').click();
      document.querySelector('#antigravity-import-form button[type="submit"]').click()`);
    await retry(() => devtools.evaluate(`!document.querySelector('#dialog').open && Boolean(document.querySelector('#agent-inspector .antigravity-report-quotas time'))`),
      'The standalone JSON quota and its reported reset did not render.');
    const jsonDisplay = await devtools.evaluate(`document.querySelector('#agent-inspector .account-reading').innerText`);
    assert.match(jsonDisplay, /导入方式 · Antigravity 独立 CLI · \/usage JSON（手动导入）/);
    assert.match(jsonDisplay, /报告记录剩余 62\.5%/);
    assert.match(jsonDisplay, /报告记录剩余 0%/);
    assert.match(jsonDisplay, /Gemini 4 Argon/);
    assert.match(jsonDisplay, /报告所列重置时间/);
    assert.doesNotMatch(jsonDisplay, /实测额度|等待新数据|Sanitized fixture/);
    const resets = await devtools.evaluate(`[...document.querySelectorAll('#agent-inspector .antigravity-report-quotas time')].map(item => Date.parse(item.dateTime)).sort()`);
    assert.deepEqual(resets, [
      Date.parse('2026-10-20T17:20:45.125Z'), Date.parse('2026-10-21T15:42:30Z'),
      Date.parse('2026-10-22T11:10:15+02:00'), Date.parse('2026-10-25T20:25:10Z'),
    ]);
    assert.equal(await devtools.evaluate(`document.querySelectorAll('#agent-inspector .antigravity-report-quotas li').length`), 4);
    const accounts = (await api('/api/state')).accounts;
    const preserved = accounts.find(account => account.id === legacyAntigravityID);
    assert.equal(preserved.connection, legacyAntigravityConnection);
    assert.equal(preserved.history.length, 1);
    assert.equal(accounts.find(account => account.id === standalone.id).snapshot, null);
    await capture('10-antigravity-history-dark-150', route, 760, 620, 1.5);
    if (testAntigravitySync) {
      await devtools.evaluate('document.querySelector(\'#agent-inspector [data-action="edit"]\').click()');
      const email = 'private-fixture@example.invalid';
      await devtools.evaluate(`document.querySelector('[name="antigravityEmail"]').value = ${JSON.stringify(email)};
        document.querySelector('#account-editor button[type="submit"]').click()`);
      const key = await retry(async () => {
        const linked = (await api('/api/state')).accounts.find(account => account.id === standalone.id);
        return linked.antigravityEmail === email && !linked.snapshot && linked.antigravityStatusAccount;
      }, 'Standalone account did not bind the fixture CLI email.');
      assert.match(key, /^[a-f0-9]{64}$/);
      await retry(() => devtools.evaluate('!document.querySelector("#dialog").open'), 'Antigravity editor did not save.');
      await devtools.evaluate('document.querySelector(\'#agent-inspector [data-action="edit"]\').click()');
      const configuration = await devtools.evaluate('JSON.parse(document.querySelector("#antigravity-setup-code").textContent)');
      assert.equal(configuration.statusLine.stack_with_default, true);
      assert.ok(configuration.statusLine.command.endsWith('--capture-antigravity-status --antigravity-account ' + key));
      assert.doesNotMatch(configuration.statusLine.command, /private-fixture@/);
      await devtools.evaluate('document.querySelector(\'#dialog [data-action="close-dialog"]\').click()');
      const push = spawn(path.resolve(cliPath), ['--data-dir', dataDir, '--capture-antigravity-status', '--antigravity-account', key],
        { windowsHide: true, signal: AbortSignal.timeout(12000), stdio: ['pipe', 'ignore', 'pipe'] });
      const pushed = once(push, 'close');
      push.stdin.end(JSON.stringify({
        product: 'antigravity', email, agent_state: 'idle',
        quota: { 'gemini-weekly': { remaining_fraction: .725, reset_time: instant(12) } },
      }));
      assert.equal((await pushed)[0], 0, 'Installed capture command did not accept the status line payload.');
      await api('/api/settings', { autoRefresh: true });
      assert.deepEqual((await api('/api/refresh-due', {})).result.ids.filter(id => id === standalone.id), [standalone.id]);
      const linked = (await api('/api/state')).accounts.find(account => account.id === standalone.id);
      assert.equal(linked.snapshot.source, 'Antigravity 独立 CLI 状态栏同步');
      assert.equal(linked.snapshot.quotas[0].usedPercent, 27.5);
      assert.equal(linked.antigravityReport.quotas.length, 4);
      await retry(() => devtools.evaluate(`document.querySelector('#agent-inspector .account-reading h3')?.textContent === '实测额度'`),
        'The open inspector did not refresh its measured Antigravity reading.', 28000);
      await capture('11-antigravity-statusline-dark-150', route, 760, 620, 1.5);
      assert.match(await devtools.evaluate('document.querySelector("#agent-inspector .account-reading").innerText'), /实测额度/);
    }
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
