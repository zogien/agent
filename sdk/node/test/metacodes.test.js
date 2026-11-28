'use strict';
// End-to-end tests of the Node package against the real AgentCore library and
// the addon in prebuilds/. Without them the suite skips, unless
// METACODES_NODE_SDK_REQUIRE_LIB=1, which CI sets so a missing build fails.

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { Worker } = require('node:worker_threads');
const { execFileSync, spawn } = require('node:child_process');
const { once } = require('node:events');
const { createHash } = require('node:crypto');

const sdkName = process.env.AGENT_SDK_TEST_INSTALLED ? '@zogien/agent-sdk' : '..';
const metacodes = require(sdkName);
const { startMockProvider } = require('./mock_provider');

const addon = path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`, 'metacodes.node');
const available = !!process.env.AGENT_SDK_TEST_INSTALLED || (fs.existsSync(addon) && metacodes.candidateLibraryPaths().some((candidate) => fs.existsSync(candidate)));
const skip = !available && process.env.METACODES_NODE_SDK_REQUIRE_LIB !== '1'
  ? 'addon or AgentCore library not built; see README.md'
  : false;

function workspace(t) {
  const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'metacodes-node-')));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

async function withProvider(t, script) {
  const provider = await startMockProvider(script);
  t.after(() => provider.close());
  return provider;
}

function open(t, runtimeOptions, provider, root, sessionOptions = {}) {
  const runtime = new metacodes.Runtime(runtimeOptions);
  t.after(() => runtime.close());
  const session = runtime.session('mock-model', {
    baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root, ...sessionOptions,
  });
  return { runtime, session };
}

function stdioMock(t) {
  const mock = process.env.METACODES_MOCK_MCP_SERVER || path.resolve(__dirname, '../../../zig-out/bin',
    process.platform === 'win32' ? 'mock_mcp_server.exe' : 'mock_mcp_server');
  if (!fs.existsSync(mock) && !process.env.METACODES_MOCK_MCP_SERVER) {
    if (process.env.AGENT_SDK_TEST_INSTALLED) return t.skip('the stdio harness is built in the source suite');
    execFileSync(process.env.ZIG || 'zig', ['build', 'test:harness', '-Doptimize=ReleaseSafe'],
      { cwd: path.resolve(__dirname, '../../..'), stdio: 'inherit' });
  }
  fs.accessSync(mock);
  return mock;
}

async function discoverStdio(server) {
  const runtime = new metacodes.Runtime({ tools: [], mcpServers: [{
    namespace: 'fixture', negotiationPolicy: 'legacy_2025_06_only',
    serverBindingIdentity: 'ab'.repeat(32), configurationFingerprint: 'cd'.repeat(32), ...server,
  }] });
  try {
    const generation = await runtime.refreshMcp();
    const snapshot = await runtime.describeMcp();
    assert.equal(snapshot.catalog_generation, generation);
    assert.deepEqual(snapshot.issues, []);
    assert.equal(snapshot.servers.length, 1);
    const names = snapshot.tools.map(tool => tool.canonical_name);
    assert.equal(names.length, 9);
    assert.ok(names.includes('echo'));
    return names;
  } finally {
    runtime.close();
  }
}

test('stdio catalog discovery returns the same tools with and without a server ping', { skip }, async t => {
  const command = stdioMock(t);
  if (!command) return;
  const args = ['--version', '2025-06-18'];
  const control = await discoverStdio({ command, args });
  assert.deepEqual(await discoverStdio({ command, args: [...args, '--ping'] }), control);
});

const windowsStdio = { skip: process.platform !== 'win32' ? 'requires Windows cmd.exe' : skip };

function batchDirectory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mcp launcher & '));
  t.after(() => fs.promises.rm(dir, { recursive: true, force: true, maxRetries: 10, retryDelay: 50 }));
  return dir;
}

test('Windows MCP stdio discovers tools through an explicit .cmd launcher', windowsStdio, async t => {
  const mock = stdioMock(t);
  if (!mock) return;
  const command = path.join(batchDirectory(t), 'fixture ^ %MCP_WORD%!.cmd');
  fs.writeFileSync(command, '@"%MCP_MOCK%" %*\r\n');
  await discoverStdio({ command, args: ['--version', '2025-06-18'], env: { ...process.env, MCP_MOCK: mock, MCP_WORD: 'expanded' } });
});

test('Windows MCP stdio resolves an extensionless launcher through PATH and PATHEXT', windowsStdio, async t => {
  const mock = stdioMock(t);
  if (!mock) return;
  const dir = batchDirectory(t);
  fs.writeFileSync(path.join(dir, 'mcp-test.cmd'), '@"%MCP_MOCK%" %*\r\n');
  fs.writeFileSync(path.join(dir, 'mcp-test.bat'), '@exit /b 7\r\n');
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(path|pathext)$/i.test(key)));
  await discoverStdio({ command: 'mcp-test', args: ['--version', '2025-06-18'],
    env: { ...env, Path: '"' + dir + '"', PathExt: '.CMD;.BAT', MCP_MOCK: mock } });
});

test('Windows MCP stdio forwards literal .bat arguments without executing extra commands', windowsStdio, async t => {
  const mock = stdioMock(t);
  if (!mock) return;
  const dir = batchDirectory(t);
  const cwd = path.join(dir, 'cwd');
  fs.mkdirSync(cwd);
  const command = path.join(dir, 'record.bat');
  fs.writeFileSync(command, '@"%MCP_NODE%" "%~dp0record.cjs" %*\r\n@"%MCP_MOCK%" --version 2025-06-18\r\n');
  const log = path.join(dir, 'argv.jsonl');
  fs.writeFileSync(path.join(dir, 'record.cjs'),
    "require('node:fs').appendFileSync(process.env.MCP_LOG, JSON.stringify(process.argv.slice(2)) + '\\n');");
  const args = ['', 'two words', 'a"b', 'left&right', 'left|right', 'in<file', 'out>file',
    'a^b', '%MCP_WORD%', '!MCP_WORD!', 'backslash\\"quote', 'trailing\\', '"& | < > ^ % !"'];
  await discoverStdio({ command, cwd, args, env: { ...process.env, MCP_NODE: process.execPath, MCP_MOCK: mock,
    MCP_LOG: log, MCP_WORD: 'expanded' } });
  assert.deepEqual(fs.readFileSync(log, 'utf8').trimEnd().split('\n').map(line => JSON.parse(line)), [args]);
  assert.deepEqual(fs.readdirSync(cwd), []);
});

test('stdio matches the pending response after interleaved frames during discovery and tool calls', { skip }, async t => {
  function serve() {
    const send = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
    let pending;
    require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
      const { id, method, result } = JSON.parse(line);
      if (id === undefined) return;
      if (method === 'initialize') {
        send({ id, result: { protocolVersion: '2025-06-18', capabilities: { tools: {} }, serverInfo: { name: 'test', version: '1' } } });
      } else if (method === 'tools/list' || method === 'tools/call') {
        const pingId = method === 'tools/list' ? String(id) : '9007199254740993';
        pending = { id, method, pingId };
        process.stdout.write('{"jsonrpc":"2.0","method":"ping","id":' + pingId + '}\n');
      } else {
        if (method || line.match(/"id"\s*:\s*(\d+)/)?.[1] !== pending.pingId || JSON.stringify(result) !== '{}') process.exit(1);
        send({ method: 'notifications/progress', params: { progressToken: 'test', progress: 1 } });
        send({ id: pending.id + 1, error: { code: -32603, message: 'unrelated response' } });
        if (pending.method === 'tools/list') {
          send({ result: { tools: [{ name: 'echo', inputSchema: { type: 'object' } }] }, id: pending.id });
        } else {
          send({ result: { content: [{ type: 'text', text: '"{\\}'.repeat(2 * 1024 * 1024) }] }, id: pending.id + 1 });
          process.stdout.write('{"jsonrpc":"2.0","result":{"content":[{"type":"text","text":"matched tool response"}]},' +
            ' '.repeat(8 * 1024 * 1024) + '"id":' + pending.id + '}\n');
        }
        pending = null;
      }
    });
  }
  const identity = 'ab'.repeat(32);
  const step = ['tool', '', {}];
  const provider = await withProvider(t, [step, ['echo']]);
  const runtime = new metacodes.Runtime({ tools: [], mcpServers: [{
    namespace: 'fixture', command: process.execPath, args: ['-e', '(' + serve.toString() + ')()'],
    negotiationPolicy: 'legacy_2025_06_only', serverBindingIdentity: identity, configurationFingerprint: 'cd'.repeat(32),
  }] });
  t.after(() => runtime.close());
  await runtime.refreshMcp();
  assert.deepEqual((await runtime.describeMcp()).issues, []);
  const session = runtime.session('mock-model', { apiKey: 'test', baseUrl: provider.baseUrl, workspace: workspace(t),
    permissionMode: 'full_access', mcpSelection: [{ serverBindingIdentity: identity, toolName: 'echo' }] });
  step[1] = session.describe().mcp.tools[0].model_name;
  assert.match((await session.run('call echo')).text, /matched tool response/);
});

test('MCP refresh discovers the live stdio catalog and selections control actual calls', { skip }, async t => {
  const mock = stdioMock(t);
  if (!mock) return;
  const root = workspace(t);
  const flag = path.join(root, 'paginate');
  const launcher = `const args = ['--version', '2025-06-18'];
    if (require('fs').existsSync(process.argv[2])) args.push('--paginate');
    process.exit(require('child_process').spawnSync(process.argv[1], args, {stdio:'inherit'}).status ?? 1);`;
  const id = 'ab'.repeat(32);
  const server = { namespace: 'fixture', command: process.execPath, args: ['-e', launcher, mock, flag],
    negotiationPolicy: 'legacy_2025_06_only', serverBindingIdentity: id, configurationFingerprint: 'cd'.repeat(32),
    env: { ...process.env, MCP_FIXTURE_VALUE: 'arrived-at-mock' } };
  const runtime = new metacodes.Runtime({ tools: [], mcpServers: [server],
    mcpCatalogLimits: { maxServers: 1, maxIssues: 8, maxNamespaceBytes: 12 } });
  t.after(() => runtime.close());
  await assert.rejects(runtime.describeMcp(), { code: 'MCP_NOT_REFRESHED' });
  const refresh = runtime.refreshMcp();
  assert.throws(() => runtime.close(), /in progress/);
  const first = await refresh;
  const catalog = await runtime.describeMcp();
  assert.equal(catalog.catalog_generation, first);
  assert.equal(catalog.servers[0].server_binding_identity, id);
  assert.ok(catalog.tools.some(tool => tool.canonical_name === 'env'));
  assert.equal(typeof catalog.servers[0].ttl_remaining_ms, 'bigint');
  const step = ['tool', '', { name: 'MCP_FIXTURE_VALUE' }];
  const provider = await withProvider(t, [step, ['echo'], ['text', 'unselected']]);
  const session = runtime.session('mock-model', { apiKey: 'test', baseUrl: provider.baseUrl, workspace: root,
    permissionMode: 'full_access', mcpSelection: [{ serverBindingIdentity: id, toolName: 'env' }] });
  step[1] = session.describe().mcp.tools[0].model_name;
  assert.match((await session.run('get the fixture value')).text, /env:MCP_FIXTURE_VALUE=arrived-at-mock/);
  assert.ok(provider.requests[0].tools.some(tool => tool.name === step[1]));
  session.updateMcpSelection([]);
  await session.run('now without the tool');
  assert.ok(!(provider.requests[2].tools || []).some(tool => tool.name === step[1]));
  fs.writeFileSync(flag, '');
  const generation = await runtime.refreshMcp();
  assert.ok(generation > first);
  const updated = await runtime.describeMcp();
  assert.deepEqual(updated.tools.map(tool => tool.canonical_name).sort(), ['echo', 'page.two']);
  assert.throws(() => session.updateMcpSelection([{ serverBindingIdentity: id, toolName: 'env' }]), { code: 'INVALID_MCP_SELECTION' });
  const revision = 9007199254740993n;
  const report = await runtime.applyMcpConfiguration({ desiredRevision: revision, servers: [] });
  assert.equal(report.disposition, 'applied');
  assert.equal(report.activeRevision, revision);
  assert.deepEqual((await runtime.describeMcp()).tools, []);
  const applied = await runtime.applyMcpConfiguration({ desiredRevision: revision + 1n, servers: [server] });
  assert.equal(applied.disposition, 'applied');
  assert.equal((await runtime.describeMcp()).servers[0].namespace, 'fixture');
  await assert.rejects(runtime.applyMcpConfiguration({ desiredRevision: revision + 2n, servers: [server, server] }),
    { code: 'RESOURCE_LIMIT' });
  const rejected = await runtime.applyMcpConfiguration({ desiredRevision: revision + 3n, servers: [
    { ...server, command: path.join(root, 'missing-server'), configurationFingerprint: '01'.repeat(32) },
  ] });
  assert.equal(rejected.disposition, 'rejected');
  assert.equal(rejected.activeRevision, applied.activeRevision);
  assert.deepEqual((await runtime.describeMcp()).tools, updated.tools);
});

test('a host connector streams tool results from the HTTP MCP fixture', { skip }, async t => {
  const python = process.env.METACODES_TEST_PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
  const fixture = process.env.METACODES_MOCK_MCP_HTTP || path.resolve(__dirname, '../../../tests/_harness/mock_mcp_http_server.py');
  const child = spawn(python, [fixture], { stdio: ['pipe', 'pipe', 'inherit'] });
  const exited = once(child, 'exit');
  t.after(async () => { child.stdin.end(); await exited; });
  const [port] = await once(child.stdout, 'data');
  const endpoint = `http://127.0.0.1:${port.toString().trim()}/keepalive`;
  const id = 'ef'.repeat(32);
  const request = (body, { signal }) => fetch(endpoint, { method: 'POST', body, signal,
    headers: { 'Content-Type': 'application/json', 'MCP-Protocol-Version': '2025-11-25' } });
  const server = { namespace: 'remote', transport: 'streamable_http', serverBindingIdentity: id,
    configurationFingerprint: id, negotiationPolicy: 'legacy_only', open: () => ({
      async request(frame, options) {
        const response = await request(frame, options);
        const body = await response.text();
        const event = body.split('\n').find(line => line.startsWith('data: '));
        return { httpStatus: response.status, body: event ? event.slice(6) : body };
      },
      async notify(frame, options) { await (await request(frame, options)).arrayBuffer(); },
      async *requestToolStream(frame, options) {
        const response = await request(frame, options);
        for await (const bytes of response.body) yield bytes;
      },
      close() {},
    }) };
  const runtime = new metacodes.Runtime({ tools: [], mcpServers: [server] });
  t.after(() => runtime.close());
  await runtime.refreshMcp();
  const catalog = await runtime.describeMcp();
  assert.deepEqual(catalog.tools.map(tool => tool.canonical_name), ['kept']);
  const step = ['tool', '', {}];
  const provider = await withProvider(t, [step, ['echo']]);
  const session = runtime.session('mock-model', { apiKey: 'test', baseUrl: provider.baseUrl, workspace: workspace(t),
    permissionMode: 'full_access', mcpSelection: [{ serverBindingIdentity: id, toolName: 'kept' }] });
  step[1] = session.describe().mcp.tools[0].model_name;
  assert.match((await session.run('call the remote tool')).text, /kept-call/);
});

test('a Worker can terminate during MCP discovery', { skip, timeout: 10000 }, async () => {
  const worker = new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const { Runtime } = require(workerData);
    const runtime = new Runtime({ tools: [], mcpServers: [{ namespace: 'wait', transport: 'streamable_http',
      serverBindingIdentity: 'ab'.repeat(32), configurationFingerprint: 'cd'.repeat(32), timeoutMs: 60000,
      open() { parentPort.postMessage('opening'); return new Promise(() => {}); } }] });
    runtime.refreshMcp();
  `, { eval: true, workerData: require.resolve(sdkName) });
  try { await once(worker, 'message'); } finally { await worker.terminate(); }
});

test('a team member sees the roster and its lead drains the reply once', { skip }, async t => {
  const root = workspace(t);
  const provider = await withProvider(t, [['tool', 'TeamCreate', { name: 'crew' }],
    ['tool', 'SpawnTeammate', { name: 'solver', prompt: 'solve' }], ['text', 'delegated'],
    ['tool', 'SendMessage', { to: 'team-lead', message: 'computed 42', summary: 'done' }], ['text', 'idle']]);
  const options = { workspaceHome: root, workspace: root, baseUrl: provider.baseUrl, apiKey: 'test', permissionMode: 'full_access' };
  const { runtime, session: lead } = open(t, { tools: [], enableTeams: true }, provider, root,
    { ...options, tools: ['TeamCreate', 'SpawnTeammate'], team: { role: 'lead' } });
  await lead.run('create a team and delegate');
  assert.equal(lead.describeTeam().pending_spawns[0].name, 'solver');
  const member = runtime.session('mock-model', { ...options, tools: ['SendMessage'], team: { role: 'member',
    teamName: 'crew', memberName: 'solver', leadSessionId: lead.describe().session_id, memberLease: '12'.repeat(12) } });
  const roster = member.describeTeam();
  assert.equal(roster.role, 'member');
  assert.ok(roster.members.some(entry => entry.name === 'solver'));
  assert.equal(member.pollTeam(), null);
  await member.run('report your result');
  assert.match(lead.pollTeam(), /computed 42/);
  assert.equal(lead.pollTeam(), null);
});

test('preview must be enabled before a preview tool enters the native runtime', { skip }, async (t) => {
  assert.throws(() => new metacodes.Runtime({ tools: ['ExecuteCode'] }), /PreviewFeatureDisabled/);
  const provider = await withProvider(t, [
    ['tool', 'ExecuteCode', { code: '40 + 2' }],
    ['echo'],
  ]);
  const { session } = open(t, { tools: [], preview: true }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('compute with preview');
  assert.match(result.text, /"value":42/);
  assert.ok(provider.requests[0].tools.some((tool) => tool.name === 'ExecuteCode'));
});

test('a text run returns the final answer, events and usage', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'hello from the mock']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  const result = await session.run('say hello', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  assert.equal(result.text, 'hello from the mock');
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.turns, 1);
  assert.equal(result.usage.input_tokens, 11n);
  assert.ok(tags.includes('text_chunk'));
  assert.ok(tags.includes('output_segment_end'));
  assert.match(JSON.stringify(provider.requests[0].messages), /say hello/);
});

test('context blocks reach the provider and wide protocol fields retain every bit', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ok']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const blocks = [{ label: 'Document', text: '原始内容' }];
  const runId = 9007199254740993n;
  session._nextRunId = runId;
  const events = [];
  const run = session.run('go', { contextBlocks: blocks, onEvent: event => events.push(event) });
  blocks[0].text = '调用后替换';
  assert.equal((await run).runId, runId);
  assert.equal(session.describe().last_run_id, runId);
  assert.ok(events.some(event => event.run_state?.run_id === runId));
  assert.match(JSON.stringify(provider.requests[0]), /原始内容/);
  assert.doesNotMatch(JSON.stringify(provider.requests[0]), /调用后替换/);
  await assert.rejects(session.run('go', { contextBlocks: [{ label: 'a', text: '字'.repeat(22000) }] }), RangeError);
  assert.equal(provider.requests.length, 1);
});

test('run and stream apply time context to the current user record', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ok'], ['text', 'ok']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  for (const options of [
    { timeContext: 'utc_offset', utcOffsetMinutes: -841 }, { timeContext: 'utc_offset', utcOffsetMinutes: 841 },
    { timeContext: 'off', utcOffsetMinutes: 1 }, { utcOffsetMinutes: -1 }, { timeContext: 'local' },
    { timeContext: 'utc_offset', utcOffsetMinutes: 0.5 }, { timeContext: 'utc_offset', utcOffsetMinutes: 2 ** 32 },
  ]) await assert.rejects(session.run('invalid', options));
  await session.stream('no date', { timeContext: 'off' }).result;
  assert.doesNotMatch(JSON.stringify(provider.requests[0]), /# currentDate/);
  const day = () => new Date(Date.now() - 840 * 60000).toISOString().slice(0, 10);
  const before = day();
  await session.run('offset date', { timeContext: 'utc_offset', utcOffsetMinutes: -840 });
  const user = JSON.stringify(provider.requests[1].messages.at(-1));
  assert.match(user, /# currentDate/);
  assert.match(user, /UTC-14:00/);
  assert.ok([before, day()].some(date => user.includes(date)));
  assert.equal(provider.requests.length, 2);
});

test('a session retains its skill catalog and enforces replacement grants', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ran'], ['text', 'streamed']]);
  const root = workspace(t);
  for (const [source, body] of [['.agents', 'default'], ['extra', 'selected']]) {
    const dir = path.join(root, source, 'skills', 'review');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'SKILL.md'),
      '---\nname: Review\ndescription: Review a target\narguments: [target]\n---\n' + body + ' review for $target');
  }
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const catalog = runtime.resolveWorkspaceSkillCatalog({ workspace: root, workspaceEpoch: 'first',
    defaultWorkspaceSourcePriority: -1, additionalSources: [
      { scope: 'workspace', root: path.join(root, 'extra', 'skills'), sourceInstanceId: 'host.extra' },
    ] });
  assert.equal(catalog.skills.length, 1);
  const [skill] = catalog.skills;
  assert.equal(skill.source.source_instance_id, 'host.extra');
  const options = { workspace: root, apiKey: 'test', baseUrl: provider.baseUrl, skillCatalog: catalog };
  const otherRuntime = new metacodes.Runtime({ tools: [] });
  t.after(() => otherRuntime.close());
  assert.throws(() => otherRuntime.session('mock-model', { ...options, skillPolicy: [] }), /another runtime/);
  assert.throws(() => runtime.session('mock-model', options), /skillPolicy/);
  const session = runtime.session('mock-model', { ...options, skillPolicy: [skill.skill_id] });
  const input = { skillId: skill.skill_id, catalogRevision: catalog.catalog_revision, values: ['the changes'] };
  await session.runSkill(input);
  assert.match(JSON.stringify(provider.requests[0].messages), /selected review for the changes/);
  session.bindPolicy(catalog, []);
  assert.throws(() => session.bindPolicy(catalog, ['unknown-id']));
  await assert.rejects(session.runSkill(input), { code: 'SKILL_POLICY_VIOLATION' });
  session.bindPolicy(catalog, [skill.skill_id]);
  runtime.releaseCatalog(catalog);
  assert.throws(() => session.bindPolicy(catalog, []), /released/);
  assert.throws(() => runtime.releaseCatalog(catalog), /released/);
  assert.throws(() => runtime.session('mock-model', { ...options, skillPolicy: [] }), /released/);
  session.bindPolicy(null, []);
  await assert.rejects(session.runSkill(input), { code: 'SKILL_POLICY_VIOLATION' });
  session.bindPolicy(null, [skill.skill_id]);
  assert.equal((await session.stream({ type: 'skill', ...input }).result).text, 'streamed');
  assert.equal(provider.requests.length, 2);
});

test('goals preserve exact budgets, generate continuation input and survive restore', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'progress']]);
  const { runtime, session } = open(t, { tools: [] }, provider, workspace(t));
  const budget = 9007199254740993n;
  assert.equal(session.getGoal(), null);
  session.setGoal('initial', budget);
  const goal = session.getGoal();
  assert.equal(goal.objective, 'initial');
  assert.equal(goal.token_budget, budget);
  assert.deepEqual(session.describe().goal, goal);
  assert.throws(() => session.updateGoal({ objective: 'invalid budget', tokenBudget: 1n << 64n }), RangeError);
  assert.deepEqual(session.getGoal(), goal);
  session.updateGoal({ objective: 'Review <changes>', tokenBudget: budget + 2n });
  const events = [];
  await session.continueGoal({ onEvent: e => events.push(e) });
  assert.match(JSON.stringify(provider.requests[0].messages), /<objective>[\s\S]*Review &lt;changes&gt;[\s\S]*<\/objective>/);
  const charged = session.getGoal();
  assert.equal(charged.id, goal.id);
  assert.equal(charged.token_budget, budget + 2n);
  assert.ok(charged.tokens_used > 0n);
  assert.equal(typeof charged.updated_at_ms, 'bigint');
  assert.deepEqual(events.filter(e => e.goal_updated).at(-1).goal_updated, charged);
  session.updateGoal({ action: 'pause' });
  const paused = session.describe().goal;
  assert.equal(paused.status, 'paused');
  await assert.rejects(session.stream({ type: 'goal_continuation' }).result, { code: 'GOAL_CONFLICT' });
  assert.equal(provider.requests.length, 1);
  const snapshot = path.join(workspace(t), 'snapshot');
  await session.exportCheckpoint(snapshot);
  session.close();
  const restored = await runtime.restoreSession(snapshot, { workspace: workspace(t), baseUrl: provider.baseUrl, apiKey: 'test' });
  assert.deepEqual(restored.getGoal(), paused);
  restored.clearGoal();
  assert.equal(restored.describe().goal, null);
});

test('checkpoint restores history, Run identity and readable tool artifacts in a fresh workspace', { skip }, async (t) => {
  const bytes = 'x'.repeat(180000) + 'portable-result';
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const provider = await withProvider(t, [
    ['tool', 'large', {}], ['text', 'remember this response'],
    ['tool', 'ReadArtifact', { artifact_id: 'sha256:' + sha256, offset: 180000, limit: 15 }], ['echo'],
  ]);
  const large = metacodes.tool({ name: 'large', handler: () => bytes });
  const config = { tools: ['ReadArtifact'], hostTools: [large] };
  const { session, runtime } = open(t, config, provider, workspace(t), { permissionMode: 'full_access' });
  const id = session.describe().session_id;
  session._nextRunId = 9007199254740993n;
  await session.run('first conversation turn');
  assert.match(JSON.stringify(provider.requests[1].messages), new RegExp(sha256));
  const snapshot = path.join(workspace(t), 'snapshot');
  const exported = session.exportCheckpoint(snapshot);
  await assert.rejects(session.run('busy'), /export/);
  assert.deepEqual(await exported, { missingArtifacts: [] });
  await assert.rejects(session.exportCheckpoint(snapshot), /already exists/);
  runtime.close();
  const fresh = new metacodes.Runtime(config);
  t.after(() => fresh.close());
  const options = { workspace: workspace(t), apiKey: 'new-key', baseUrl: provider.baseUrl, permissionMode: 'full_access' };
  const restored = await fresh.restoreSession(snapshot, options);
  assert.equal(restored.restoreReport.session_id, id);
  const run = await restored.run('read the saved artifact');
  assert.match(run.text, /"data":"portable-result"/);
  assert.equal(run.runId, 9007199254740994n);
  assert.match(JSON.stringify(provider.requests[2].messages), /remember this response/);
  const file = path.join(snapshot, 'blobs', sha256 + '.blob');
  fs.writeFileSync(file, 'tampered');
  await assert.rejects(fresh.restoreSession(snapshot, options), /integrity/);
});

test('checkpoint export reports an artifact the session references but no longer stores', { skip }, async (t) => {
  const bytes = 'y'.repeat(180000) + 'vanished-result';
  const sha256 = createHash('sha256').update(bytes).digest('hex');
  const provider = await withProvider(t, [['tool', 'large', {}], ['text', 'kept a reference']]);
  const large = metacodes.tool({ name: 'large', handler: () => bytes });
  const root = workspace(t);
  const { session } = open(t, { tools: ['ReadArtifact'], hostTools: [large] }, provider, root, { permissionMode: 'full_access' });
  await session.run('make a large result');
  const id = session.describe().session_id;
  fs.rmSync(path.join(root, '.metacodes', 'agentcore', 'sessions', id, 'tool-results', 'sha256', sha256 + '.blob'));
  const snapshot = path.join(workspace(t), 'snapshot');
  assert.deepEqual(await session.exportCheckpoint(snapshot), { missingArtifacts: ['sha256:' + sha256] });
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(snapshot, 'manifest.json'))).blobs, []);
});

test('checkpoint export ignores artifact receipts quoted in conversation text', { skip }, async (t) => {
  const example = JSON.stringify({
    schema_version: 'metacodes.tool-result-projection.v1', projection: 'artifact', artifact_id: 'sha256:' + 'a'.repeat(64),
  });
  const provider = await withProvider(t, [['text', example]]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  assert.equal((await session.run(example)).toolCalls, 0);
  assert.deepEqual(await session.exportCheckpoint(path.join(workspace(t), 'snapshot')), { missingArtifacts: [] });
});

test('a model failure reaches the result and a later success clears it', { skip }, async (t) => {
  const provider = await withProvider(t, [
    ['status', 402, { 'x-request-id': 'req-node-1' }, { error: { code: 'insufficient_balance', message: 'Balance too low' } }],
    ['text', 'fine now'],
  ]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  const failed = await session.run('fails', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  assert.equal(failed.stopReason, 'api_error');
  assert.equal(failed.modelError.category, 'payment_required');
  assert.equal(failed.modelError.code, 'insufficient_balance');
  assert.equal(failed.modelError.message, 'Balance too low');
  assert.equal(failed.modelError.http_status, 402);
  assert.equal(failed.modelError.request_id, 'req-node-1');
  assert.equal(failed.modelError.retry, 'not_retryable');
  assert.equal(tags.filter((tag) => tag === 'model_error').length, 1);
  assert.equal(tags[tags.length - 1], 'run_state');
  const recovered = await session.run('succeeds');
  assert.equal(recovered.stopReason, 'end_turn');
  assert.equal(recovered.modelError, null);
});

test('a stream cut after thinking is sent again under the budget (Revision 28)', { skip }, async (t) => {
  // Issue #452: thinking, then the body ends with no stop reason.
  const provider = await withProvider(t, [['thinking_cut', 'private reasoning'], ['text', 'recovered']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const events = [];
  const result = await session.run('think', { streamRetryBudget: 1, onEvent: (event) => events.push(event) });
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(result.text, 'recovered');
  assert.equal(result.modelError, null);
  assert.equal(provider.requests.length, 2);
  assert.deepEqual(provider.requests[1], provider.requests[0]);
  const payloads = (tag) => events.filter((event) => tag in event).map((event) => event[tag]);
  assert.deepEqual(payloads('thinking_discarded'), [{ index: 0, turn: 1, group: 0, bytes: 17n }]);
  // One failed stream of at most three: the first attempt, the request's own
  // re-issue (#461) and the budget's one, after the short backoff.
  assert.deepEqual(payloads('retry_notice'), [{ attempt: 1, max: 3, delay_ms: 500n }]);
  assert.deepEqual(result.segments.map((segment) => segment.disposition), ['discarded', 'final']);
});

test('without a budget a request cut twice after thinking ends the Run', { skip }, async (t) => {
  // Issue #461: every request has one re-issue of its own; the second cut of
  // the same request ends the Run.
  const provider = await withProvider(t, [
    ['thinking_cut', 'private reasoning'],
    ['thinking_cut', 'private reasoning'],
    ['text', 'never sent'],
  ]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const events = [];
  const result = await session.run('think', { onEvent: (event) => events.push(event) });
  assert.equal(result.stopReason, 'api_error');
  assert.equal(provider.requests.length, 2);
  assert.deepEqual(provider.requests[1], provider.requests[0]);
  const payloads = (tag) => events.filter((event) => tag in event).map((event) => event[tag]);
  assert.deepEqual(payloads('thinking_discarded'), [{ index: 0, turn: 1, group: 0, bytes: 17n }]);
  assert.deepEqual(payloads('retry_notice'), [{ attempt: 1, max: 2, delay_ms: 500n }]);
  assert.equal(result.modelError.attempts, 2);
  await assert.rejects(session.run('think', { streamRetryBudget: 9 }), RangeError);
  assert.equal(provider.requests.length, 2);
});

test('every event of a Run arrives before its Promise settles', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'ordered']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const tags = [];
  await session.run('go', { onEvent: (event) => tags.push(Object.keys(event)[0]) });
  const last = tags.at(-1);
  assert.equal(last, 'run_state');
});

test('an async JavaScript tool result reaches the model', { skip }, async (t) => {
  const calls = [];
  const add = metacodes.tool({
    name: 'add',
    description: 'Add two integers.',
    inputSchema: { type: 'object', properties: { a: { type: 'integer' }, b: { type: 'integer' } }, required: ['a', 'b'] },
    handler: async ({ a, b }) => {
      calls.push([a, b]);
      await new Promise((resolve) => setTimeout(resolve, 10));
      return String(a + b);
    },
  });
  const provider = await withProvider(t, [['tool', 'add', { a: 2, b: 3 }], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [add] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('add 2 and 3');
  assert.deepEqual(calls, [[2, 3]]);
  assert.equal(result.text, 'saw: 5');
  assert.equal(result.toolCalls, 1);
  assert.ok(provider.requests[0].tools.some((advertised) => advertised.name === 'add'));
});

test('a throwing tool becomes a model-visible error', { skip }, async (t) => {
  const broken = metacodes.tool({ name: 'broken', handler: () => { throw new Error('disk on fire'); } });
  const provider = await withProvider(t, [['tool', 'broken', {}], ['echo']]);
  const { session } = open(t, { tools: [], hostTools: [broken] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('try it');
  assert.match(result.text, /disk on fire/);
  assert.equal(result.stopReason, 'end_turn');
});

test('the built-in Read tool reads the workspace', { skip }, async (t) => {
  const root = workspace(t);
  fs.writeFileSync(path.join(root, 'notes.txt'), 'the secret is 42\n');
  const provider = await withProvider(t, [['tool', 'Read', { file_path: 'notes.txt' }], ['echo']]);
  const { session } = open(t, { tools: ['Read'] }, provider, root);
  const result = await session.run('read notes.txt');
  assert.match(result.text, /the secret is 42/);
});

test('Runtime points RG_BIN at the ripgrep staged beside the library', { skip }, (t) => {
  const saved = process.env.RG_BIN;
  delete process.env.RG_BIN;
  t.after(() => { if (saved === undefined) delete process.env.RG_BIN; else process.env.RG_BIN = saved; });
  const runtime = new metacodes.Runtime({ tools: ['Grep'] });
  t.after(() => runtime.close());
  const bin = metacodes.resolve ? metacodes.resolve().binDir : path.join(__dirname, '..', 'prebuilds', `${process.platform}-${process.arch}`);
  const staged = path.join(bin, process.platform === 'win32' ? 'rg.exe' : 'rg');
  if (!fs.existsSync(staged)) return t.skip('no ripgrep staged');
  assert.ok(process.env.RG_BIN && fs.realpathSync(process.env.RG_BIN) === fs.realpathSync(staged));
});

test('a permission request reaches the handler and a deny holds', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const requests = [];
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['echo']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: (request) => { requests.push(request); return request.denyOnce(); },
  });
  const result = await session.run('write a file');
  assert.equal(requests.length, 1);
  assert.equal(requests[0].kind, 'permission');
  assert.equal(requests[0].data.tool.name, 'Write');
  assert.equal(fs.existsSync(target), false);
  assert.equal(result.stopReason, 'end_turn');
});

test('an async allow lets the write happen', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'written' }], ['text', 'done']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: async (request) => request.allowOnce(),
  });
  const result = await session.run('write a file');
  assert.equal(fs.readFileSync(target, 'utf8'), 'written');
  assert.equal(result.text, 'done');
});

test('without a handler the write is not allowed', { skip }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [['tool', 'Write', { file_path: target, content: 'x' }], ['text', 'ok']]);
  const { session } = open(t, { tools: ['Write'] }, provider, root);
  await session.run('write a file');
  assert.equal(fs.existsSync(target), false);
});

test('stream yields events and then the result', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'streamed']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const stream = session.stream('go');
  const tags = [];
  for await (const event of stream) tags.push(Object.keys(event)[0]);
  assert.ok(tags.includes('text_chunk'));
  assert.equal((await stream.result).text, 'streamed');
});

test('a throwing listener rejects the Run and the session survives', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'answer'], ['text', 'answer']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  await assert.rejects(session.run('one', { onEvent: () => { throw new TypeError('listener bug'); } }), /listener bug/);
  const result = await session.run('two');
  assert.equal(result.text, 'answer');
});

test('a second concurrent run on one session is refused', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'first'], ['text', 'second']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const first = session.run('one');
  await assert.rejects(session.run('two'), /already active/);
  assert.equal((await first).text, 'first');
});

test('two sessions run concurrently', { skip }, async (t) => {
  const provider = await withProvider(t, [['text', 'same'], ['text', 'same']]);
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const root = workspace(t);
  const options = { baseUrl: provider.baseUrl, apiKey: 'test-key', workspace: root };
  const [a, b] = await Promise.all([
    runtime.session('mock-model', options).run('a'),
    runtime.session('mock-model', options).run('b'),
  ]);
  assert.equal(a.text, 'same');
  assert.equal(b.text, 'same');
});

test('a shell tool requires a shell policy', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const runtime = new metacodes.Runtime({ tools: ['Bash'] });
  t.after(() => runtime.close());
  assert.throws(
    () => runtime.session('mock-model', { baseUrl: provider.baseUrl, apiKey: 'k', workspace: workspace(t), tools: ['Bash'] }),
    (error) => error.code === 'INVALID_ARGUMENT',
  );
});

test('describe and setModel', { skip }, async (t) => {
  const provider = await withProvider(t, []);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  assert.equal(session.describe().model, 'mock-model');
  session.setModel('mock-model-2');
  assert.equal(session.describe().model, 'mock-model-2');
});

test('unknown built-in tools are rejected', { skip }, () => {
  assert.throws(() => new metacodes.Runtime({ tools: ['Telepathy'] }), /unknown built-in tools/);
});

// A regression of the tests below hangs instead of failing (AgentCore waits
// for a call that never completes), so each carries a timeout.
const TIMEOUT = 30_000;

// -- results a handler cannot serialize ------------------------------------

test('a tool result JSON.stringify throws on is a model-visible error, not a crash', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'big', {}], ['echo']]);
  const big = metacodes.tool({ name: 'big', description: 'Returns a BigInt.', handler: () => ({ n: 1n }) });
  const { session } = open(t, { tools: [], hostTools: [big] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /TypeError/);
  assert.equal(result.stopReason, 'end_turn');
});

test('a tool result JSON.stringify drops is a model-visible error', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'fn', {}], ['echo']]);
  const fn = metacodes.tool({ name: 'fn', description: 'Returns a function.', handler: () => () => 1 });
  const { session } = open(t, { tools: [], hostTools: [fn] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /fn result is not JSON-serializable/);
});

test('a UI answer JSON.stringify throws on rejects the Run and the session survives', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const target = path.join(root, 'out.txt');
  const provider = await withProvider(t, [
    ['tool', 'Write', { file_path: target, content: 'x' }], ['text', 'unused'], ['text', 'second'],
  ]);
  const { session } = open(t, { tools: ['Write'] }, provider, root, { onUiRequest: () => ({ bad: 1n }) });
  await assert.rejects(session.run('write'), TypeError);
  assert.equal(fs.existsSync(target), false);
  const again = await session.run('hi');
  assert.equal(again.text, 'second');
});

test('a handler rejecting with a value that has no string form still answers the call', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'odd', {}], ['echo']]);
  const odd = metacodes.tool({ name: 'odd', description: 'Throws a bare object.', handler: () => { throw Object.create(null); } });
  const { session } = open(t, { tools: [], hostTools: [odd] }, provider, workspace(t), { permissionMode: 'full_access' });
  const result = await session.run('go');
  assert.match(result.text, /Error/);
  assert.equal(result.stopReason, 'end_turn');
});

// -- an active Run: submit, abort, close -----------------------------------

function blockingTool() {
  let release;
  let started;
  const startedPromise = new Promise((resolve) => { started = resolve; });
  const released = new Promise((resolve) => { release = resolve; });
  const wait = metacodes.tool({
    name: 'wait',
    description: 'Waits for the test.',
    // Capped so a broken test fails instead of holding the suite.
    // unref(): the cap must not keep the test process alive after the suite.
    handler: async () => {
      started();
      await Promise.race([released, new Promise((resolve) => setTimeout(resolve, 10_000).unref())]);
      return 'waited';
    },
  });
  return { wait, started: startedPromise, release };
}

test('submit hands the active Run more input', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'done']]);
  const { wait, started, release } = blockingTool();
  const { session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  session.submit('and mention the weather');
  release();
  const result = await run;
  assert.equal(result.inputAccepted, 1);
  assert.equal(result.inputAdopted, 1);
  assert.match(JSON.stringify(provider.requests[1].messages), /and mention the weather/);
});

test('updateCredential from a tool changes the next request', { skip, timeout: TIMEOUT }, async (t) => {
  let session;
  const rotate = metacodes.tool({
    name: 'rotate',
    description: 'Rotates the provider key.',
    handler: async () => {
      session.updateCredential('rotated-key');
      return 'rotated';
    },
  });
  const provider = await withProvider(t, [['tool', 'rotate', {}], ['text', 'done'], ['text', 'again']]);
  ({ session } = open(t, { tools: [], hostTools: [rotate] }, provider, workspace(t), { permissionMode: 'full_access', apiKey: 'first-key' }));
  const result = await session.run('rotate the key');
  assert.equal(result.text, 'done');
  assert.throws(() => session.updateCredential('bad key'), (error) => !String(error.message).includes('bad key'));
  await session.run('once more');
  // The Run's first request used the creation key; the turn after the tool,
  // and the next Run after the refused update, the rotated one.
  assert.deepEqual(provider.authorizations, ['Bearer first-key', 'Bearer rotated-key', 'Bearer rotated-key']);
});

test('abort stops the active Run', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'never asked']]);
  const { wait, started, release } = blockingTool();
  const { session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  session.abort();
  release();
  const result = await run;
  assert.equal(result.stopReason, 'aborted');
  assert.equal(provider.requests.length, 1);
});

test('abort targets its Run and wakes an unresolved host call', { skip, timeout: TIMEOUT }, async (t) => {
  let started;
  const pending = new Promise(resolve => { started = resolve; });
  let finish;
  const wait = metacodes.tool({ name: 'wait', handler: (_, context) => {
    started(context);
    return new Promise(resolve => { finish = resolve; });
  } });
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'next']]);
  const { session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const sessionId = session.describe().session_id;
  const stream = session.stream('start', { contextBlocks: [{ label: 'host', text: 'call context' }] });
  const context = await pending;
  assert.equal(context.sessionId, sessionId);
  assert.equal(context.runId, 1n);
  assert.equal(context.callId, 1n);
  const cancelled = stream.abort();
  assert.equal(context.signal.aborted, true);
  assert.deepEqual(await cancelled, { status: 'cancelled' });
  assert.equal((await stream.result).stopReason, 'aborted');
  const next = session.run('again');
  finish('late answer');
  assert.deepEqual(await stream.abort(), { status: 'already_finished' });
  assert.equal((await next).text, 'next');
});

test('abort immediately after starting a Run reaches admission', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['text', 'ok']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  const stream = session.stream('go');
  assert.deepEqual(await stream.abort(), { status: 'cancelled' });
  assert.equal((await stream.result).stopReason, 'aborted');
});

test('a host tool can await cancellation of its own Run', { skip, timeout: TIMEOUT }, async (t) => {
  let observed;
  const finished = new Promise(resolve => { observed = resolve; });
  const cancel = metacodes.tool({ name: 'cancel', async handler(_, context) {
    const result = await session.abort();
    observed([result.status, context.signal.aborted]);
  } });
  const provider = await withProvider(t, [['tool', 'cancel', {}]]);
  const { session } = open(t, { tools: [], hostTools: [cancel] }, provider, workspace(t), { permissionMode: 'full_access' });
  assert.equal((await session.run('cancel from tool')).stopReason, 'aborted');
  assert.deepEqual(await finished, ['cancelled', true]);
});

test('terminating Workers with pending host callbacks leaves the process usable', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['tool', 'wait', {}], ['text', 'still alive']]);
  const workers = Array.from({ length: 2 }, () => new Worker(`
    const { parentPort, workerData } = require('node:worker_threads');
    const { Runtime, tool } = require(workerData.sdk);
    const wait = tool({ name: 'wait', handler() {
      parentPort.postMessage('waiting');
      return new Promise(() => {});
    } });
    new Runtime({ tools: [], hostTools: [wait] }).session('mock-model', workerData.options).run('go');
  `, { eval: true, workerData: { sdk: require.resolve(sdkName), options: {
    baseUrl: provider.baseUrl, workspace: workspace(t), apiKey: 'test', permissionMode: 'full_access',
  } } }));
  t.after(() => Promise.all(workers.map(w => w.terminate())));
  await Promise.all(workers.map(w => once(w, 'message')));
  assert.deepEqual(await Promise.all(workers.map(w => w.terminate())), [1, 1]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  assert.equal((await session.run('go')).text, 'still alive');
});

test('close during a Run is refused and keeps the handle', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['tool', 'wait', {}], ['text', 'done']]);
  const { wait, started, release } = blockingTool();
  const { runtime, session } = open(t, { tools: [], hostTools: [wait] }, provider, workspace(t), { permissionMode: 'full_access' });
  const run = session.run('start');
  await started;
  assert.throws(() => session.close());
  assert.ok(session._handle);
  release();
  assert.equal((await run).text, 'done');
  session.close();
  assert.equal(session._handle, null);
  assert.equal(runtime.sessions.has(session), false);
});

// -- permissions ---------------------------------------------------------

function writeScript(root, ...names) {
  return [...names.map((name) => ['tool', 'Write', { file_path: path.join(root, name), content: name }]), ['text', 'done']];
}

test('a checkpoint lock left by an exited writer does not block a retry, but a live writer does', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['echo']]);
  const { session } = open(t, {}, provider, workspace(t));
  const parent = workspace(t);
  const crashed = path.join(parent, 'crashed');
  fs.writeFileSync(crashed + '.lock', '');
  assert.deepEqual(await session.exportCheckpoint(crashed), { missingArtifacts: [] });
  assert.equal(fs.existsSync(crashed + '.lock'), false);

  const held = path.join(parent, 'held');
  const holder = spawn(process.execPath, ['-e', `
    const { Runtime } = require(${JSON.stringify(require.resolve(sdkName))});
    new Runtime({ tools: [] })._native.lockPath(${JSON.stringify(held + '.lock')});
    process.stdout.write('locked\\n');
    setInterval(() => {}, 1000);
  `], { stdio: ['ignore', 'pipe', 'inherit'] });
  t.after(() => holder.kill('SIGKILL'));
  const [ready] = await once(holder.stdout, 'data');
  assert.equal(String(ready).trim(), 'locked');
  await assert.rejects(session.exportCheckpoint(held), /locked by another writer/);
  assert.equal(fs.existsSync(held), false);
  holder.kill('SIGKILL');
  await once(holder, 'exit');
  assert.deepEqual(await session.exportCheckpoint(held), { missingArtifacts: [] });

  const id = session.describe().session_id;
  const home = workspace(t);
  const sessions = path.join(home, '.metacodes', 'agentcore', 'sessions');
  fs.mkdirSync(sessions, { recursive: true });
  fs.writeFileSync(path.join(sessions, id + '.restore.lock'), '');
  const fresh = new metacodes.Runtime();
  t.after(() => fresh.close());
  const restored = await fresh.restoreSession(held, { workspace: home, baseUrl: provider.baseUrl, apiKey: 'test-key' });
  assert.equal(restored.restoreReport.session_id, id);
  assert.equal(fs.existsSync(path.join(sessions, id + '.restore.lock')), false);
});

test('allow and deny rules decide without asking', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const asked = [];
  const onUiRequest = (request) => { asked.push(request); return request.allowOnce(); };
  const denied = await withProvider(t, writeScript(root, 'denied.txt'));
  await open(t, { tools: ['Write'] }, denied, root, { deny: ['Write'], onUiRequest }).session.run('write');
  const allowed = await withProvider(t, writeScript(root, 'allowed.txt'));
  await open(t, { tools: ['Write'] }, allowed, root, { allow: ['Write'], onUiRequest }).session.run('write');
  assert.equal(fs.existsSync(path.join(root, 'denied.txt')), false);
  assert.equal(fs.existsSync(path.join(root, 'allowed.txt')), true);
  assert.deepEqual(asked, []);
});

test('replacement rules govern the next tool decision', { skip }, async t => {
  const root = workspace(t);
  const provider = await withProvider(t, ['allowed', 'denied', 'asked'].flatMap(name => writeScript(root, name)));
  let questions = 0;
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: request => { questions++; return request.allowOnce(); },
  });
  for (const action of ['allow', 'deny', 'ask']) {
    session.updatePermissionRules({ [action]: ['Write'] });
    await session.run('write');
  }
  assert.equal(questions, 1);
  assert.equal(fs.existsSync(path.join(root, 'allowed')), true);
  assert.equal(fs.existsSync(path.join(root, 'denied')), false);
  assert.equal(fs.existsSync(path.join(root, 'asked')), true);
});

test('prompt edits survive replacement and checkpoint restore', { skip }, async t => {
  const provider = await withProvider(t, []);
  const profile = text => [{ op: 'replace', id: 'metacodes:identity', text }];
  const { runtime, session } = open(t, { tools: [] }, provider, workspace(t), { promptProfile: profile('first identity') });
  await session.run('one');
  assert.match(JSON.stringify(provider.requests[0].system), /first identity/);
  session.setPromptProfile(profile('second identity'));
  for (const edits of [Array(65).fill(profile('x')[0]), profile('界'.repeat(21846)), Array(5).fill(profile('x'.repeat(65536))[0])])
    assert.throws(() => session.setPromptProfile(edits), RangeError);
  await session.run('two');
  assert.match(JSON.stringify(provider.requests[1].system), /second identity/);
  assert.doesNotMatch(JSON.stringify(provider.requests[1].system), /first identity/);
  const snapshot = path.join(workspace(t), 'checkpoint');
  await session.exportCheckpoint(snapshot);
  session.close();
  const restored = await runtime.restoreSession(snapshot, { workspace: workspace(t), baseUrl: provider.baseUrl, apiKey: 'k' });
  await restored.run('three');
  assert.match(JSON.stringify(provider.requests[2].system), /second identity/);
  restored.setPromptProfile(null);
  await restored.run('four');
  assert.doesNotMatch(JSON.stringify(provider.requests[3].system), /second identity/);
});

test('model changes and checkpoint restore use the current host token limits', { skip }, async t => {
  const provider = await withProvider(t, []);
  const root = workspace(t);
  const options = { workspace: root, baseUrl: provider.baseUrl, apiKey: 'k' };
  const { runtime, session } = open(t, { tools: [] }, provider, root, {
    modelCapabilities: [{ model: 'other', maxInputTokens: 900000, maxTokens: 52000 }],
  });
  for (const fields of [{}, { maxTokens: 2 ** 32 }, { maxInputTokens: -1 }, { maxTokens: 0.5 }]) {
    assert.throws(() => runtime.session('other', { ...options, modelCapabilities: [{ model: 'other', ...fields }] }));
  }
  assert.equal(session.describe().max_input_tokens, 200000);
  session.setModel('other');
  assert.equal(session.describe().max_input_tokens, 900000);
  await session.run('one');
  assert.equal(provider.requests[0].max_tokens, 52000);
  const snapshot = path.join(workspace(t), 'checkpoint');
  await session.exportCheckpoint(snapshot);
  session.close();
  const restored = await runtime.restoreSession(snapshot, { ...options,
    modelCapabilities: [{ model: 'OTHER', maxTokens: 43000 }],
  });
  assert.equal(restored.describe().max_input_tokens, 200000);
  await restored.run('two');
  assert.equal(provider.requests[1].max_tokens, 43000);
});

test('ordered image parts and current host options apply on create and restore', { skip }, async t => {
  const provider = await withProvider(t, []);
  const modelCapabilities = [{ model: 'mock-model', imageInput: true }];
  const options = { modelCapabilities, runJournalMode: 'durable_workspace', workspaceHome: workspace(t) };
  const { runtime, session } = open(t, { tools: [] }, provider, workspace(t), options);
  const image = { type: 'image', mediaType: 'image/png', data: 'UE5HREFUQQ==' };
  const parts = [{ type: 'text', text: 'before' }, image, { type: 'text', text: 'after' }];
  for (const invalid of [[], Array(65).fill(parts[0]), [{ ...image, data: 'A'.repeat(5000001) }]])
    await assert.rejects(session.run(invalid), RangeError);
  await session.stream(parts).result;
  const content = provider.requests[0].messages.at(-1).content;
  assert.deepEqual(content.slice(-3), [parts[0],
    { type: 'image', source: { type: 'base64', media_type: 'image/png', data: image.data } }, parts[2]]);
  const journal = path.join('.metacodes', 'agentcore', 'sessions', session.describe().session_id, 'tool-observations.jsonl');
  assert.match(fs.readFileSync(path.join(options.workspaceHome, journal), 'utf8'), /provider_attempt/);
  const snapshot = path.join(workspace(t), 'checkpoint');
  await session.exportCheckpoint(snapshot);
  session.close();
  const home = workspace(t);
  const restored = await runtime.restoreSession(snapshot, { ...options, workspaceHome: home, workspace: workspace(t),
    apiKey: 'k', baseUrl: provider.baseUrl, modelCapabilities: [{ model: 'mock-model', imageInput: false }],
    durableBudget: { hardBytes: 64 << 20, softBytes: 48 << 20, inputCapBytes: 1024n, providerRequestCapBytes: 16 << 20,
      providerResultCapBytes: 4 << 20, toolResultCapBytes: 2 << 20, mcpResultCapBytes: 2 << 20,
      auditReserveBytes: 4096, terminalReserveBytes: 1024 },
  });
  await assert.rejects(restored.run(parts), { code: 'IMAGE_INPUT_UNSUPPORTED' });
  await assert.rejects(restored.run('x'.repeat(2048)), { code: 'CHECKPOINT_BUDGET_REQUIRED' });
  assert.equal(provider.requests.length, 1);
  restored.rewindToUserMessage(1);
  assert.equal((await restored.run('continue')).stopReason, 'end_turn');
  assert.match(fs.readFileSync(path.join(home, journal), 'utf8'), /provider_attempt/);
});

const HISTORY_RUNS = 12;

async function compactableSession(t, summary) {
  const provider = await withProvider(t, [...Array(HISTORY_RUNS).fill(['text', 'answer']), summary, ['text', 'continued']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  await session.run('A'.repeat(8192));
  for (let i = 1; i < HISTORY_RUNS; i++) await session.run('recent context');
  return { session, provider };
}

test('compact summarizes prior messages on a worker thread', { skip, timeout: TIMEOUT }, async t => {
  const { session, provider } = await compactableSession(t, ['text', 'short summary']);
  const result = await session.compact();
  assert.equal(result.outcome, 'compacted');
  assert.ok(result.beforeContextTokens > result.afterContextTokens && result.afterContextTokens > 0n);
  for (const count of [result.beforeContextTokens, result.afterContextTokens, ...Object.values(result.usage)])
    assert.equal(typeof count, 'bigint');
  assert.ok(result.usage.input_tokens > 0n && result.usage.output_tokens > 0n);
  assert.match(JSON.stringify(provider.requests[HISTORY_RUNS].messages), /A{128}/);
  await session.run('next');
  assert.ok(provider.requests.at(-1).messages.length < provider.requests[HISTORY_RUNS - 1].messages.length);
  assert.match(JSON.stringify(provider.requests.at(-1).messages), /short summary/);
  assert.doesNotMatch(JSON.stringify(provider.requests.at(-1).messages), /A{128}/);
});

test('abortCompact cancels a pending summary while JS remains responsive', { skip, timeout: TIMEOUT }, async t => {
  let received, release;
  const started = new Promise(resolve => { received = resolve; });
  const held = new Promise(resolve => { release = resolve; });
  const { session } = await compactableSession(t, ['hold', 'late summary', () => { received(); return held; }]);
  const pending = session.compact();
  try {
    await started;
    assert.throws(() => session.close(), { code: 'BUSY' });
    await assert.rejects(session.run('busy'), /compaction/);
    await session.abortCompact();
  } finally { release(); }
  assert.equal((await pending).outcome, 'aborted');
  assert.equal((await session.run('next')).text, 'continued');
});

test('setPermissionMode applies to the next Run', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const provider = await withProvider(t, [...writeScript(root, 'first.txt'), ...writeScript(root, 'second.txt')]);
  const { session } = open(t, { tools: ['Write'] }, provider, root);
  await session.run('write one');
  session.setPermissionMode('full_access');
  await session.run('write two');
  assert.equal(fs.existsSync(path.join(root, 'first.txt')), false);
  assert.equal(fs.existsSync(path.join(root, 'second.txt')), true);
});

test('rewindToUserMessage reruns an edited message', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['text', 'first answer'], ['text', 'second answer'], ['text', 'edited answer']]);
  const { session } = open(t, { tools: [] }, provider, workspace(t));
  await session.run('alpha-prompt');
  const position = session.describe().conversation.message_count + 1n;
  await session.run('beta-prompt');
  assert.equal(session.describe().conversation.message_count, 4n);
  // An assistant reply and a position past the end are refused with their
  // own codes and change nothing.
  assert.throws(() => session.rewindToUserMessage(2), { code: 'NOT_USER_MESSAGE' });
  assert.throws(() => session.rewindToUserMessage(9), { code: 'MESSAGE_POSITION_OUT_OF_RANGE' });
  assert.throws(() => session.rewindToUserMessage(0), TypeError);
  assert.equal(session.describe().conversation.message_count, 4n);
  assert.equal(provider.requests.length, 2);
  session.rewindToUserMessage(position);
  assert.equal(session.describe().conversation.message_count, 2n);
  const result = await session.run('gamma-edited');
  assert.equal(result.text, 'edited answer');
  const rerun = JSON.stringify(provider.requests[2].messages);
  assert.match(rerun, /alpha-prompt/);
  assert.match(rerun, /gamma-edited/);
  assert.doesNotMatch(rerun, /beta-prompt/);
  assert.doesNotMatch(rerun, /second answer/);
});

test('allowSession is asked once per target', { skip, timeout: TIMEOUT }, async (t) => {
  const root = workspace(t);
  const asked = [];
  const provider = await withProvider(t, writeScript(root, 'a.txt', 'a.txt', 'b.txt'));
  const { session } = open(t, { tools: ['Write'] }, provider, root, {
    onUiRequest: (request) => { asked.push(request.data.candidate.target); return request.allowSession(); },
  });
  await session.run('write three times');
  assert.deepEqual(asked.map(value => path.normalize(value)), [path.join(root, 'a.txt'), path.join(root, 'b.txt')]);
});

test('an ask_question answer reaches the model', { skip, timeout: TIMEOUT }, async (t) => {
  const question = {
    question: 'Which colour?', header: 'Colour', multiSelect: false,
    options: [{ label: 'Red', description: 'warm' }, { label: 'Blue', description: 'cool' }],
  };
  const provider = await withProvider(t, [['tool', 'AskUserQuestion', { questions: [question] }], ['echo']]);
  const kinds = [];
  const { session } = open(t, { tools: ['AskUserQuestion'] }, provider, workspace(t), {
    onUiRequest: (request) => { kinds.push(request.kind); return request.answer(['Blue']); },
  });
  const result = await session.run('ask me');
  assert.deepEqual(kinds, ['ask_question']);
  assert.match(result.text, /Blue/);
});

// -- providers -----------------------------------------------------------

test('the openai provider speaks chat completions', { skip, timeout: TIMEOUT }, async (t) => {
  const provider = await withProvider(t, [['text', 'hello over chat completions']]);
  const runtime = new metacodes.Runtime({ tools: [] });
  t.after(() => runtime.close());
  const session = runtime.session('mock-model', {
    provider: 'openai', baseUrl: provider.openaiUrl, apiKey: 'test-key', workspace: workspace(t),
  });
  const result = await session.run('say hello');
  assert.equal(result.text, 'hello over chat completions');
  assert.equal(result.stopReason, 'end_turn');
  assert.match(JSON.stringify(provider.requests[0].messages), /say hello/);
});
