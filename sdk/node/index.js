'use strict';
// Embed the metacodes agent runtime (AgentCore C ABI) in Node.js.
// See README.md; the native bridge is src/addon.c.

const fs = require('node:fs');
const mcp = require('./mcp');
const { exportSnapshot, restoreSnapshot } = require('./checkpoint');
const { addonPath, candidateLibraryPaths } = require('./location');
const path = require('node:path');

const ABI_REVISION = 29;
const BUILTIN_TOOLS = [
  'ExecuteCode',
  'Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash', 'BashOutput', 'KillShell',
  'WebSearch', 'WebFetch', 'AskUserQuestion', 'ReadArtifact',
];
const DEFAULT_TOOLS = ['Read', 'Glob', 'Grep'];
const SHELL_TOOLS = ['Bash', 'BashOutput', 'KillShell'];
// The CLI agent loop's own default (src/core/agent_loop.zig Options.max_turns).
const DEFAULT_MAX_TURNS = 400;
const MAX_TURNS = 1000;
// Revision 28: RunOptionsV1.stream_retry_budget runs from 0 to this.
const MAX_STREAM_RETRY_BUDGET = 8;
const PROVIDERS = { anthropic: 1, openai: 2, gemini: 3 };
const PERMISSION_MODES = { default: 1, accept_edits: 2, auto: 3, dont_ask: 4, full_access: 5 };
const SHELL_POLICIES = { disabled: 1, sandboxed: 2, unrestricted: 3 };
const OPENAI_PROTOCOL_RESPONSES = 1;
const STOP_REASONS = {
  1: 'end_turn', 2: 'max_turns', 3: 'aborted', 4: 'tool_error', 5: 'api_error',
  6: 'tool_loop', 7: 'checkpoint_budget_exhausted', 8: 'checkpoint_resource_limit',
};
const API_KEY_ENV = {
  anthropic: ['ANTHROPIC_API_KEY'],
  openai: ['OPENAI_API_KEY'],
  gemini: ['GEMINI_API_KEY', 'GOOGLE_API_KEY'],
};
const HOST_OK = 0;
const HOST_FAILED = 1;
const UI_ANSWERED = 0;
const UI_UNAVAILABLE = 1;

let native = null;
let loadedLibrary = null;

function loadNative(explicit) {
  if (!native) {
    const addon = addonPath(ABI_REVISION);
    if (!fs.existsSync(addon)) {
      throw new Error(`metacodes: no native addon for ${process.platform}-${process.arch} at ${addon}`);
    }
    native = require(addon);
  }
  if (loadedLibrary) {
    if (explicit && path.resolve(explicit) !== loadedLibrary) {
      throw new Error(`metacodes: AgentCore is already loaded from ${loadedLibrary}`);
    }
    return native;
  }
  const tried = [];
  for (const candidate of candidateLibraryPaths(explicit)) {
    if (fs.existsSync(candidate)) {
      const rg = process.env.RG_BIN || bundledRipgrep(candidate);
      if (rg && !process.env.RG_BIN) process.env.RG_BIN = rg;
      if (native.abiRevision !== ABI_REVISION || native.load(candidate, rg || '') !== ABI_REVISION)
        throw new Error('AgentCore Node binding ABI revision mismatch');
      loadedLibrary = candidate;
      return native;
    }
    tried.push(candidate);
  }
  const error = new Error(
    'metacodes: AgentCore shared library not found. Set METACODES_AGENTCORE_LIB or install ' +
      `metacodes with its SDK. Tried: ${tried.join(', ')}`,
  );
  error.code = 'LIBRARY_NOT_FOUND';
  throw error;
}

function bundledRipgrep(libraryPath) {
  const rg = process.platform === 'win32' ? 'rg.exe' : 'rg';
  for (const candidate of [path.join(path.dirname(libraryPath), rg), path.join(path.dirname(libraryPath), '..', 'bin', rg)]) {
    if (fs.existsSync(candidate)) return candidate;
  }
  return null;
}

// JSON for a value a handler returned. A value JSON.stringify throws on (a
// BigInt, a cycle) or turns into undefined (a function, a symbol) is the
// handler's error: it must reach the rejection handler that completes the
// pending call, not escape as an unhandled rejection that kills the host or
// leaves AgentCore waiting for a call that never completes.
function toJson(value, what) {
  const text = JSON.stringify(value ?? null);
  if (typeof text !== 'string') throw new TypeError(`${what} is not JSON-serializable`);
  return text;
}

function decode(kind, json) {
  return native.project(kind, json, JSON.parse(json));
}

function encodeAnswer(answer) {
  if (typeof answer?.policy_generation !== 'bigint') return toJson(answer, 'onUiRequest answer');
  const { policy_generation: generation, ...fields } = answer;
  if (generation < 1n || generation > 0xffffffffffffffffn) throw new RangeError('invalid policy_generation');
  const json = toJson(fields, 'permission answer');
  if (!json.startsWith('{')) throw new TypeError('invalid permission answer');
  return `{"policy_generation":${generation}${json.length === 2 ? '}' : ',' + json.slice(1)}`;
}

function integer64(value, signed) {
  if (Number.isSafeInteger(value)) value = BigInt(value);
  if (typeof value !== 'bigint' || (signed ? BigInt.asIntN(64, value) : BigInt.asUintN(64, value)) !== value)
    throw new RangeError('expected a 64-bit integer');
  return value;
}

function copyProfile(profile) {
  if (profile == null) return [];
  if (!Array.isArray(profile) || profile.length > 64) throw new RangeError('promptProfile allows up to 64 sections');
  let total = 0;
  return Array.from(profile, ({ op, id, text = '', order = 0, interpolate = false }) => {
    const code = ['add', 'replace', 'remove'].indexOf(op) + 1;
    if (!code || typeof id !== 'string' || typeof text !== 'string' || typeof interpolate !== 'boolean')
      throw new TypeError('invalid promptProfile section');
    const size = Buffer.byteLength(text);
    total += size;
    if (size > 65536 || total > 262144) throw new RangeError('promptProfile exceeds the text byte limit');
    return { op: code, id: Buffer.from(id), text: Buffer.from(text), order: integer64(order, true), interpolate: Number(interpolate) };
  });
}

function copyCapabilities(entries = []) {
  if (!Array.isArray(entries) || entries.length > 256) throw new RangeError('modelCapabilities allows up to 256 models');
  return Array.from(entries, ({ model, imageInput, maxInputTokens = 0, maxTokens = 0 }) => {
    if (typeof model !== 'string' || (imageInput !== undefined && typeof imageInput !== 'boolean'))
      throw new TypeError('invalid model capability');
    for (const limit of [maxInputTokens, maxTokens]) {
      if (!Number.isInteger(limit) || limit < 0 || limit > 0xffffffff)
        throw new RangeError('model token limits must be unsigned 32-bit integers');
    }
    if (imageInput === undefined && !maxInputTokens && !maxTokens)
      throw new TypeError('model capability requires imageInput or a nonzero token limit');
    const imageCode = imageInput === undefined ? 0 : (imageInput ? 1 : 2);
    return { model: Buffer.from(model), imageInput: imageCode, maxInputTokens, maxTokens };
  });
}

function copyBudget(budget) {
  if (budget === undefined) return null;
  const fields = ['hardBytes', 'softBytes', 'inputCapBytes', 'providerRequestCapBytes', 'providerResultCapBytes',
    'toolResultCapBytes', 'mcpResultCapBytes', 'auditReserveBytes', 'terminalReserveBytes'];
  return Object.fromEntries(fields.map(key => [key, integer64(budget[key], false)]));
}

function copyTeam(team) {
  if (team == null) return null;
  const role = ['lead', 'member'].indexOf(team.role) + 1;
  if (!role) throw new TypeError('team role must be lead or member');
  const fields = { role };
  for (const key of ['teamName', 'memberName', 'leadSessionId', 'memberLease']) {
    const value = team[key] ?? '';
    if (typeof value !== 'string') throw new TypeError(`team.${key} must be a string`);
    fields[key] = Buffer.from(value);
  }
  return fields;
}

function copyInput(prompt) {
  if (prompt?.type === 'goal_continuation') return { kind: 4 };
  if (prompt?.type === 'skill') {
    const { skillId, catalogRevision, values = [] } = prompt;
    if (typeof skillId !== 'string' || typeof catalogRevision !== 'string' ||
        !Array.isArray(values) || values.length > 64 || !Array.from(values).every(v => typeof v === 'string'))
      throw new TypeError('invalid skill invocation');
    const argumentsJson = JSON.stringify({ values });
    if (Buffer.byteLength(argumentsJson) > 1048576) throw new RangeError('skill arguments exceed the byte limit');
    return { kind: 2, skillId, catalogRevision, argumentsJson };
  }
  if (!Array.isArray(prompt)) return String(prompt);
  if (!prompt.length || prompt.length > 64) throw new RangeError('multimodal input requires 1 to 64 parts');
  return Array.from(prompt, part => {
    if (part.type === 'text' && typeof part.text === 'string') return { kind: 1, text: part.text };
    if (part.type !== 'image' || typeof part.mediaType !== 'string' || typeof part.data !== 'string')
      throw new TypeError('invalid multimodal input part');
    if (Buffer.byteLength(part.data) > 5000000) throw new RangeError('image exceeds the base64 byte limit');
    return { kind: 2, mediaType: part.mediaType, data: part.data };
  });
}

function copyContextBlocks(blocks) {
  if (!Array.isArray(blocks) || blocks.length > 32) throw new RangeError('contextBlocks allows up to 32 blocks');
  let total = 0;
  return Array.from(blocks, ({ label, text }) => {
    if (typeof label !== 'string' || typeof text !== 'string') throw new TypeError('context block label and text must be strings');
    const labelSize = Buffer.byteLength(label);
    const textSize = Buffer.byteLength(text);
    total += labelSize + textSize;
    if (labelSize > 64 || textSize > 65536 || total > 262144) throw new RangeError('contextBlocks exceeds the byte limit');
    return { label, text };
  });
}

// A rejection value can be anything, including one String() throws on
// (Object.create(null)); the text must never throw.
function errorText(error) {
  try {
    return `${error && error.name ? error.name : 'Error'}: ${error && error.message ? error.message : String(error)}`;
  } catch (_) {
    return 'Error: the handler rejected with a value that has no string form';
  }
}


/** Define a tool implemented in JavaScript. `handler(args, context)` may be async. */
function tool({ name, description, inputSchema, handler }) {
  if (!name || typeof handler !== 'function') throw new TypeError('tool needs a name and a handler');
  return {
    name,
    description: description || name,
    inputSchema: inputSchema || { type: 'object', properties: {} },
    handler,
  };
}

class UiRequest {
  constructor(kind, data) {
    this.kind = kind;
    this.data = data;
  }

  _permission(choice) {
    if (this.kind !== 'permission') throw new Error('not a permission request');
    const response = {
      permission: choice,
      request_id: this.data.request_id,
      policy_generation: this.data.policy_generation,
    };
    if (choice.endsWith('_session')) {
      if (!this.data.candidate) throw new Error('this request offers no session-scoped answer');
      response.rule_id = this.data.candidate.rule_id;
    }
    return response;
  }

  allowOnce() { return this._permission('allow_once'); }
  allowSession() { return this._permission('allow_session'); }
  denyOnce() { return this._permission('deny_once'); }
  denySession() { return this._permission('deny_session'); }

  /** Answer an ask_question request: one array of chosen labels per question. */
  answer(...values) {
    if (this.kind !== 'ask_question') throw new Error('not a question request');
    return { answers: values.map((chosen) => ({ values: [...chosen] })) };
  }
}

/** Rebuilds the final answer from output-segment events (see the ABI document). */
class RunState {
  constructor() {
    this.open = [];
    this.pending = new Map();
    this.finalText = '';
    this.segments = [];
    this.modelError = null;
    this.usage = { input_tokens: 0n, output_tokens: 0n, cache_read_input_tokens: 0n, cache_creation_input_tokens: 0n };
  }

  observe(tag, payload) {
    if (tag === 'output_segment_begin') {
      this.open = [];
    } else if (tag === 'text_chunk') {
      this.open.push(payload);
    } else if (tag === 'output_segment_end') {
      const text = this.open.join('');
      this.open = [];
      const group = payload.group ?? 0;
      this.segments.push({ disposition: payload.disposition, group, text });
      if (payload.disposition === 'continued') {
        if (!this.pending.has(group)) this.pending.set(group, []);
        this.pending.get(group).push(text);
      } else if (payload.disposition === 'final') {
        this.finalText = (this.pending.get(group) || []).join('') + text;
        this.pending.delete(group);
      }
    } else if (tag === 'model_error' && payload && typeof payload === 'object') {
      this.modelError = payload;
    } else if (tag === 'usage' && payload && typeof payload === 'object') {
      for (const key of Object.keys(this.usage)) this.usage[key] += payload[key] ?? 0n;
    }
  }
}

class AgentCoreError extends Error {
  constructor(operation, status, statusName, diagnostic) {
    super(`${operation} failed: ${statusName}${diagnostic ? `: ${diagnostic}` : ''}`);
    this.name = 'AgentCoreError';
    this.code = statusName;
    this.status = status;
    this.diagnostic = diagnostic || '';
  }
}

function copyGrants(policy) {
  if (!Array.isArray(policy) || policy.length > 1024)
    throw new TypeError('skillPolicy must be an array of granted skill IDs');
  return Array.from(policy, id => {
    if (typeof id !== 'string') throw new TypeError('each granted skill ID must be a string');
    return id;
  });
}

class Runtime {
  #catalogs = new Map();

  constructor({ tools = DEFAULT_TOOLS, hostTools = [], library, preview = false,
    enableTeams = false, mcpServers = [], mcpCatalogLimits } = {}) {
    if (typeof preview !== 'boolean') throw new TypeError('preview must be a boolean');
    if (preview) tools = [...new Set([...tools, 'ExecuteCode'])];
    const unknown = tools.filter((name) => !BUILTIN_TOOLS.includes(name));
    if (unknown.length) throw new Error(`unknown built-in tools: ${unknown.join(', ')}`);
    this._native = loadNative(library);
    this.tools = [...tools];
    this.hostTools = [...hostTools];
    this.sessions = new Set();
    this._restores = 0;
    if ((tools.includes('Glob') || tools.includes('Grep')) && !process.env.RG_BIN) {
      const rg = bundledRipgrep(loadedLibrary);
      if (rg) process.env.RG_BIN = rg;
    }
    const specs = this.hostTools.map((hostTool) => ({
      name: hostTool.name,
      description: hostTool.description,
      schema: JSON.stringify(hostTool.inputSchema),
    }));
    if (typeof enableTeams !== 'boolean') throw new TypeError('enableTeams must be a boolean');
    const limits = mcpCatalogLimits == null ? null : Object.fromEntries(
      ['maxServers', 'maxNamespaceBytes', 'maxIssues'].map(key => [key, integer64(mcpCatalogLimits[key], false)]));
    this._mcpJobs = 0;
    this._handle = this._native.runtimeCreate(this.tools, specs, preview,
      { enableTeams, servers: mcp.servers(mcpServers, this._native), limits });
  }

  async applyMcpConfiguration({ desiredRevision, servers }) {
    this._mcpJobs++;
    try {
      return await this._native.applyMcp(this._handle, { desiredRevision: integer64(desiredRevision, false),
        servers: mcp.servers(servers, this._native) });
    } finally { this._mcpJobs--; }
  }

  async refreshMcp() {
    this._mcpJobs++;
    try { return await this._native.refreshMcp(this._handle); } finally { this._mcpJobs--; }
  }

  async describeMcp() {
    this._mcpJobs++;
    try { return decode(6, await this._native.describeMcp(this._handle)); } finally { this._mcpJobs--; }
  }

  resolveWorkspaceSkillCatalog({ workspace = '.', workspaceHome = workspace, workspaceEpoch = '',
    additionalSources = [], defaultUserSourcePriority = 0, defaultWorkspaceSourcePriority = 0 } = {}) {
    function priority(value = 0) {
      if (!Number.isInteger(value) || value < -2147483648 || value > 2147483647)
        throw new RangeError('skill source priority must fit int32');
      return value;
    }
    if (!Array.isArray(additionalSources) || additionalSources.length > 64) throw new RangeError('additionalSources allows up to 64 sources');
    if (typeof workspaceEpoch !== 'string') throw new TypeError('workspaceEpoch must be a string');
    const query = {
      workspace: Buffer.from(path.resolve(workspace)), workspaceHome: Buffer.from(path.resolve(workspaceHome)),
      workspaceEpoch: Buffer.from(workspaceEpoch), defaultUserSourcePriority: priority(defaultUserSourcePriority),
      defaultWorkspaceSourcePriority: priority(defaultWorkspaceSourcePriority),
      sources: Array.from(additionalSources, source => {
        const scope = ['user', 'workspace'].indexOf(source.scope) + 1;
        if (!scope || typeof source.sourceInstanceId !== 'string') throw new TypeError('invalid skill source');
        return { scope, root: Buffer.from(path.resolve(source.root)), id: Buffer.from(source.sourceInstanceId),
          priority: priority(source.priority) };
      }),
    };
    const { handle, json } = this._native.resolveCatalog(this._handle, query);
    try {
      const catalog = decode(5, json);
      this.#catalogs.set(catalog, handle);
      return catalog;
    } catch (error) { this._native.releaseCatalog(handle); throw error; }
  }

  _catalogHandle(catalog) {
    const handle = this.#catalogs.get(catalog);
    if (!handle) throw new Error('skill catalog was released or belongs to another runtime');
    return handle;
  }

  releaseCatalog(catalog) {
    this._native.releaseCatalog(this._catalogHandle(catalog));
    this.#catalogs.delete(catalog);
  }

  /** Create a Session; see README.md for the options. */
  session(model, options = {}) {
    const session = new Session(this, model, options);
    this.sessions.add(session);
    return session;
  }

  async restoreSession(directory, options = {}) {
    if (!this._handle) throw new Error('runtime is closed');
    const host = { ...options, workspace: path.resolve(options.workspace || '.') };
    host.workspaceHome = path.resolve(options.workspaceHome || host.workspace);
    this._restores++;
    try {
      const session = await restoreSnapshot(this._native, directory, host.workspaceHome, read => new Session(this, '', host, read));
      this.sessions.add(session);
      return session;
    } finally { this._restores--; }
  }

  close() {
    if (!this._handle) return;
    if (this._restores) throw new Error('session restore in progress');
    if (this._mcpJobs) throw new Error('MCP operation in progress');
    for (const session of [...this.sessions]) session.close();
    for (const catalog of this.#catalogs.keys()) this.releaseCatalog(catalog);
    this._native.runtimeDestroy(this._handle);
    this._handle = null;
  }
}

class Session {
  constructor(runtime, model, options = {}, readCheckpoint) {
    const {
      provider = 'anthropic',
      apiKey,
      baseUrl = '',
      workspace = '.',
      workspaceHome = '',
      tools,
      permissionMode = 'default',
      shell = 'disabled',
      openaiProtocol,
      allow = [],
      ask = [],
      deny = [],
      onEvent,
      onUiRequest,
    } = options;
    if (!(provider in PROVIDERS)) throw new Error(`provider must be one of ${Object.keys(PROVIDERS).join(', ')}`);
    if (!(permissionMode in PERMISSION_MODES)) throw new Error(`permissionMode must be one of ${Object.keys(PERMISSION_MODES).join(', ')}`);
    if (!(shell in SHELL_POLICIES)) throw new Error(`shell must be one of ${Object.keys(SHELL_POLICIES).join(', ')}`);
    let protocol = 0;
    if (openaiProtocol === 'responses') {
      if (provider !== 'openai') throw new Error("openaiProtocol applies to provider 'openai' only");
      protocol = OPENAI_PROTOCOL_RESPONSES;
    } else if (openaiProtocol && openaiProtocol !== 'chat_completions') {
      throw new Error('openaiProtocol must be chat_completions or responses');
    }
    let key = apiKey;
    if (key === undefined) {
      for (const name of [...API_KEY_ENV[provider], 'METACODES_API_KEY']) {
        if (process.env[name]) { key = process.env[name]; break; }
      }
    }
    let selected = tools;
    if (!selected) {
      selected = [...runtime.tools, ...runtime.hostTools.map((hostTool) => hostTool.name)];
      if (shell === 'disabled') selected = selected.filter((name) => !SHELL_TOOLS.includes(name));
    }
    this.runtime = runtime;
    this.model = model;
    this._native = runtime._native;
    this._onEvent = onEvent;
    this._onUiRequest = onUiRequest;
    this._nextRunId = 1n;
    this._nextCompactId = 1n;
    this._compact = null;
    this._nextInputId = 1n;
    this._active = null;
    this._workspaceHome = path.resolve(workspaceHome || workspace);
    this._exporting = false;
    this.restoreReport = null;
    const journal = ['ephemeral', 'durable_workspace'].indexOf(options.runJournalMode ?? 'ephemeral');
    if (journal < 0) throw new TypeError('invalid runJournalMode');
    if (readCheckpoint && options.promptProfile != null) throw new TypeError('restore uses the checkpoint prompt profile');
    const { skillCatalog, skillPolicy } = options;
    const bindSkills = skillCatalog !== undefined || skillPolicy !== undefined;
    const config = {
      mcpSelection: options.mcpSelection === undefined ? null : mcp.selection(options.mcpSelection),
      team: copyTeam(options.team),
      grants: bindSkills ? copyGrants(skillPolicy) : null,
      catalog: bindSkills ? runtime._catalogHandle(skillCatalog) : null,
      promptProfile: copyProfile(options.promptProfile),
      modelCapabilities: copyCapabilities(options.modelCapabilities),
      durableBudget: copyBudget(options.durableBudget),
      runJournalMode: journal,
      provider: PROVIDERS[provider],
      protocol,
      permissionMode: PERMISSION_MODES[permissionMode],
      shell: SHELL_POLICIES[shell],
      apiKey: key || '',
      baseUrl,
      workspaceRoot: path.resolve(workspace),
      workspaceHome: workspaceHome ? path.resolve(workspaceHome) : '',
      model,
      tools: selected,
      allow,
      ask,
      deny,
    };
    const dispatch = (...args) => this._dispatch(...args);
    this._handle = readCheckpoint
      ? this._native.sessionCreate(runtime._handle, config, dispatch, readCheckpoint)
      : this._native.sessionCreate(runtime._handle, config, dispatch);
    if (readCheckpoint) {
      try {
        this.restoreReport = decode(3, config.restoreReport);
        const description = this.describe();
        this.model = description.model;
        this._nextRunId = description.last_run_id + 1n;
        this._nextCompactId = description.last_compact_id + 1n;
      } catch (error) { this.close(); throw error; }
    }
  }

  _dispatch(kind, a, b, index, runId, sessionId) {
    if (kind === 'event') this._event(a);
    else if (kind === 'compact') {
      const { resolve, reject } = this._compact;
      this._compact = null;
      if (a.status) reject(new AgentCoreError('session.compact', a.status, a.statusName, a.diagnostic));
      else resolve({ outcome: ['compacted', 'no_change', 'degraded', 'aborted'][a.outcomeCode - 1],
        beforeContextTokens: a.beforeContextTokens, afterContextTokens: a.afterContextTokens, usage: a.usage });
    } else if (kind === 'done') this._done(a);
    else if (kind === 'ui' || kind === 'tool') {
      const active = this._active;
      if (!active || active.runId !== runId || active.cancel) return;
      const controller = new AbortController();
      active.calls.set(a, controller);
      const finish = (status, text) => {
        if (!active.calls.delete(a) || this._active !== active || !this._handle) return;
        this._native.completeCall(this._handle, a, status, text);
      };
      if (kind === 'ui') return this._uiRequest(finish, b, active);
      const hostTool = this.runtime.hostTools[index];
      Promise.resolve()
        .then(() => hostTool.handler(JSON.parse(b || '{}'), { sessionId, runId, callId: a, signal: controller.signal }))
        .then(value => typeof value === 'string' ? value : toJson(value, hostTool.name + ' result'))
        .then(text => finish(HOST_OK, text), error => finish(HOST_FAILED, errorText(error)));
    }
  }

  _event(json) {
    const active = this._active;
    let event;
    try {
      event = decode(0, json);
    } catch (error) {
      if (active && !active.error) active.error = error;
      this.abort();
      return;
    }
    const keys = Object.keys(event);
    if (active && keys.length === 1) active.state.observe(keys[0], event[keys[0]]);
    for (const listener of [this._onEvent, active && active.onEvent]) {
      if (!listener) continue;
      try {
        listener(event);
      } catch (error) {
        // A broken listener must not poison the Session: stop the Run and
        // reject its Promise once AgentCore has returned.
        if (active && !active.error) active.error = error;
        this.abort();
      }
    }
  }

  _uiRequest(finish, json, active) {
    if (!this._onUiRequest) return finish(UI_UNAVAILABLE, '');
    let request;
    try {
      const data = decode(1, json);
      request = 'ask_question' in data
        ? new UiRequest('ask_question', { questions: data.ask_question })
        : new UiRequest('permission', data.permission || data);
    } catch (error) {
      return finish(UI_UNAVAILABLE, '');
    }
    Promise.resolve()
      .then(() => this._onUiRequest(request))
      .then((answer) => (answer == null ? null : encodeAnswer(answer)))
      .then(
        (text) => (text == null ? finish(UI_UNAVAILABLE, '') : finish(UI_ANSWERED, text)),
        (error) => {
          if (this._active === active && !active.cancel && !active.error) active.error = error;
          finish(UI_UNAVAILABLE, '');
        },
      )
      .catch(() => finish(UI_UNAVAILABLE, ''));
  }

  _done(outcome) {
    const active = this._active;
    this._active = null;
    if (!active) return;
    active.calls.clear();
    if (active.finishCancel) {
      const result = outcome.status ? { status: 'failed', diagnostic: outcome.diagnostic || outcome.statusName }
        : { status: outcome.stopReasonCode === 3 ? 'cancelled' : 'already_finished' };
      active.finishCancel(result);
    }
    if (active.error) return active.reject(active.error);
    if (outcome.status !== 0) {
      return active.reject(new AgentCoreError('session.run_input', outcome.status, outcome.statusName, outcome.diagnostic));
    }
    active.resolve({
      runId: active.runId,
      text: active.state.finalText,
      stopReason: STOP_REASONS[outcome.stopReasonCode] || String(outcome.stopReasonCode),
      turns: outcome.turns,
      toolCalls: outcome.toolCalls,
      usage: active.state.usage,
      segments: active.state.segments,
      inputAccepted: outcome.inputAccepted,
      inputAdopted: outcome.inputAdopted,
      modelError: active.state.modelError,
    });
  }

  /**
   * Run one prompt to completion. Every request is sent once more by itself
   * when its stream breaks off without an answer before any tool call started;
   * `streamRetryBudget` (0 to 8, default 0) is how many more times the Run may
   * send a request again after that. Each retry of an attempt that showed
   * output ends its segment `discarded`, takes back its thinking with a
   * `thinking_discarded` event and is announced by `retry_notice`.
   * @returns {Promise<{runId: bigint, text: string, stopReason: string, turns: number, toolCalls: number, usage: object, segments: object[]}>}
   */
  run(prompt, { maxTurns, streamRetryBudget = 0, onEvent, contextBlocks = [], timeContext = 'system', utcOffsetMinutes = 0 } = {}) {
    if (!this._handle) return Promise.reject(new Error('session is closed'));
    if (this._exporting) return Promise.reject(new Error('checkpoint export in progress'));
    if (this._compact) return Promise.reject(new Error('compaction in progress'));
    if (this._active) return Promise.reject(new Error('a Run is already active on this session'));
    const turns = maxTurns === undefined ? DEFAULT_MAX_TURNS : Number(maxTurns);
    if (!Number.isInteger(turns) || turns < 1 || turns > MAX_TURNS) {
      return Promise.reject(new RangeError(`maxTurns must be between 1 and ${MAX_TURNS}`));
    }
    const budget = Number(streamRetryBudget);
    if (!Number.isInteger(budget) || budget < 0 || budget > MAX_STREAM_RETRY_BUDGET) {
      return Promise.reject(new RangeError(`streamRetryBudget must be between 0 and ${MAX_STREAM_RETRY_BUDGET}`));
    }
    return new Promise((resolve, reject) => {
      const timeCode = ['system', 'utc_offset', 'off'].indexOf(timeContext);
      if (timeCode < 0) throw new TypeError('invalid timeContext');
      const runId = this._nextRunId++;
      this._active = { runId, state: new RunState(), onEvent, resolve, reject, error: null, calls: new Map() };
      try {
        this._native.sessionRun(this._handle, runId, copyInput(prompt), {
          turns, budget, timeCode, utcOffsetMinutes, blocks: copyContextBlocks(contextBlocks),
        });
      } catch (error) {
        this._active = null;
        reject(error);
      }
    });
  }

  /** Run `prompt` and iterate over its events; `stream.result` resolves to the RunResult. */
  stream(prompt, options = {}) {
    const queue = [];
    let wake = null;
    let finished = false;
    let failure = null;
    const push = (event) => {
      queue.push(event);
      if (wake) { wake(); wake = null; }
    };
    const previous = this._active;
    const result = this.run(prompt, { ...options, onEvent: push }).then(
      (value) => { finished = true; if (wake) wake(); return value; },
      (error) => { finished = true; failure = error; if (wake) wake(); throw error; },
    );
    const active = this._active !== previous ? this._active : null;
    result.catch(() => {});
    return {
      result,
      abort: () => this._abort(active),
      async *[Symbol.asyncIterator]() {
        while (true) {
          if (queue.length) { yield queue.shift(); continue; }
          if (finished) break;
          await new Promise((resolve) => { wake = resolve; });
        }
        if (failure) throw failure;
      },
    };
  }

  abort() {
    return this._abort(this._active);
  }

  _abort(active) {
    if (!active || this._active !== active) return Promise.resolve({ status: 'already_finished' });
    if (active.cancel) return active.cancel;
    try {
      this._native.sessionAbort(this._handle, active.runId);
    } catch (error) {
      return Promise.resolve({ status: 'failed', diagnostic: error.message });
    }
    active.cancel = new Promise(resolve => { active.finishCancel = resolve; });
    for (const controller of active.calls.values()) controller.abort();
    active.calls.clear();
    return active.cancel;
  }

  /** Hand the active Run more user text; returns its acceptance sequence. */
  submit(text) {
    if (!this._active) throw new Error('no active Run');
    return this._native.sessionSubmit(this._handle, this._active.runId, this._nextInputId++, String(text));
  }

  /**
   * Replace the provider credential in place (AgentCore Revision 25). Every
   * request sent afterwards uses it: the next turn of a Run already going, a
   * retry, a compaction, a Skill, a request still waiting for a connection. A
   * request already sent keeps the old key. Callable from this Session's own tool and
   * UI handlers. 1 to 16384 bytes of printable ASCII; anything else throws and
   * keeps the previous key.
   */
  updateCredential(apiKey) {
    this._native.sessionUpdateCredential(this._handle, String(apiKey));
  }

  describe() {
    const description = decode(2, this._native.sessionDescribe(this._handle));
    description.goal = this.getGoal();
    return description;
  }

  getGoal() {
    return decode(4, this._native.getGoal(this._handle)).goal;
  }

  updateMcpSelection(selectors) {
    this._requireIdle();
    this._native.updateMcpSelection(this._handle, mcp.selection(selectors));
  }

  describeTeam() {
    return JSON.parse(this._native.describeTeam(this._handle)).team;
  }

  pollTeam() {
    return JSON.parse(this._native.pollTeam(this._handle)).input;
  }

  setGoal(objective, tokenBudget = 0n) {
    this._requireIdle();
    if (typeof objective !== 'string') throw new TypeError('objective must be a string');
    this._native.setGoal(this._handle, { objective: Buffer.from(objective), tokenBudget: integer64(tokenBudget, false) });
  }

  updateGoal({ objective, tokenBudget, action }) {
    this._requireIdle();
    const fields = (objective !== undefined ? 1 : 0) | (tokenBudget !== undefined ? 2 : 0) | (action !== undefined ? 4 : 0);
    const actionCode = ['pause', 'activate', 'complete', 'block'].indexOf(action) + 1;
    if (!fields || (objective !== undefined && typeof objective !== 'string') || (action !== undefined && !actionCode))
      throw new TypeError('invalid goal update');
    this._native.updateGoal(this._handle, { fields, objective: Buffer.from(objective ?? ''),
      tokenBudget: integer64(tokenBudget === undefined ? 0n : tokenBudget, false), action: actionCode });
  }

  clearGoal() {
    this._requireIdle();
    this._native.clearGoal(this._handle);
  }

  continueGoal(options) {
    return this.run({ type: 'goal_continuation' }, options);
  }

  runSkill(input, options) {
    return this.run({ ...input, type: 'skill' }, options);
  }

  bindPolicy(catalog, grantedSkillIds) {
    this._requireIdle();
    const grants = copyGrants(grantedSkillIds);
    this._native.bindPolicy(this._handle, { grants, catalog: catalog === null ? null : this.runtime._catalogHandle(catalog) });
  }

  async exportCheckpoint(directory) {
    if (!this._handle || this._active || this._compact || this._exporting) throw new Error('checkpoint export requires an idle session');
    this._exporting = true;
    try { return await exportSnapshot(this, directory); }
    finally { this._exporting = false; }
  }

  _requireIdle() {
    if (!this._handle) throw new Error('session is closed');
    if (this._active || this._compact || this._exporting) throw new Error('operation requires an idle session');
  }

  setPromptProfile(profile) {
    this._requireIdle();
    this._native.sessionSetPromptProfile(this._handle, copyProfile(profile));
  }

  updatePermissionRules({ allow = [], ask = [], deny = [] }) {
    this._requireIdle();
    this._native.sessionUpdatePermissionRules(this._handle, { allow, ask, deny });
  }

  async compact() {
    this._requireIdle();
    const id = this._nextCompactId++;
    return new Promise((resolve, reject) => {
      this._compact = { id, resolve, reject };
      try { this._native.sessionCompact(this._handle, id); }
      catch (error) { this._compact = null; reject(error); }
    });
  }

  async abortCompact() {
    const operation = this._compact;
    while (operation && operation === this._compact) {
      try { this._native.sessionAbortCompact(this._handle, operation.id); return; }
      catch (error) {
        if (error.code === 'TOO_LATE') return;
        if (error.code !== 'INVALID_ARGUMENT') throw error;
      }
      await new Promise(resolve => setTimeout(resolve, 1));
    }
  }

  setModel(model) {
    if (this._compact) throw new Error('compaction in progress');
    if (this._exporting) throw new Error('checkpoint export in progress');
    this._native.sessionSetModel(this._handle, model);
    this.model = model;
  }

  setPermissionMode(mode) {
    if (this._compact) throw new Error('compaction in progress');
    if (this._exporting) throw new Error('checkpoint export in progress');
    if (!(mode in PERMISSION_MODES)) throw new Error(`permissionMode must be one of ${Object.keys(PERMISSION_MODES).join(', ')}`);
    this._native.sessionSetPermissionMode(this._handle, PERMISSION_MODES[mode]);
  }

  /**
   * Drop the user message at `position` and everything after it (AgentCore
   * Revision 27): the next Run takes its place, after exactly the context that
   * preceded it. `position` counts the full history from 1, as
   * `describe().conversation.message_count` counts, so a Run's own message is
   * `message_count + 1` read just before it. Only the Conversation changes;
   * files and other effects of the dropped turns stay. A refused position
   * throws with code `NOT_USER_MESSAGE`, `MESSAGE_POSITION_OUT_OF_RANGE` or
   * `MESSAGE_POSITION_COMPACTED` and changes nothing.
   */
  rewindToUserMessage(position) {
    if (this._compact) throw new Error('compaction in progress');
    if (this._exporting) throw new Error('checkpoint export in progress');
    if (Number.isSafeInteger(position)) position = BigInt(position);
    if (typeof position !== 'bigint' || position < 1n) throw new TypeError('position must be a positive integer');
    this._native.sessionRewindToUserMessage(this._handle, position);
  }

  close() {
    if (!this._handle) return;
    if (this._exporting) throw new Error('checkpoint export in progress');
    this._native.sessionDestroy(this._handle);
    this._handle = null;
    this.runtime.sessions.delete(this);
  }
}

module.exports = {
  ABI_REVISION,
  AgentCoreError,
  BUILTIN_TOOLS,
  DEFAULT_TOOLS,
  Runtime,
  Session,
  UiRequest,
  candidateLibraryPaths,
  tool,
};
