'use strict';

const { spawn } = require('node:child_process');
const { once } = require('node:events');
const { mkdtemp, open, rm, unlink } = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');

const MAX_FRAME = 8388608;
const MAX_TOOL_FRAME = 129 * 1024 * 1024;
const toolResponseHeader = /^\s*\{\s*(?:"jsonrpc"\s*:\s*"2\.0"\s*,\s*)?"id"\s*:\s*(\d+)\s*,\s*"(?:result|error)"\s*:/;
const policies = ['auto', 'modern_only', 'legacy_only', 'legacy_2025_06_only'];
const eras = ['2026-07-28', '2025-11-25', '2025-06-18'];
const outcomes = ['response', 'timeout', 'network_error', 'auth_error', 'server_error', 'child_exit', 'cancelled', 'indeterminate', 'fatal'];

function identity(hex) {
  if (typeof hex !== 'string' || !/^[a-f\d]{64}$/i.test(hex) || /^0+$/.test(hex))
    throw new TypeError('MCP identity and fingerprint must be nonzero 32-byte hex strings');
  return Buffer.from(hex, 'hex');
}

function encodedId(body, id) {
  if (typeof id !== 'number' || Number.isSafeInteger(id)) return JSON.stringify(id);
  const tokens = /"(?:[^"\\]|\\.)*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g;
  return JSON.parse(body.toString().replace(tokens, token => token.startsWith('"') ? token : JSON.stringify(token))).id;
}

function selection(selectors) {
  if (!Array.isArray(selectors) || selectors.length > 1024) throw new RangeError('invalid MCP selection');
  return Array.from(selectors, ({ serverBindingIdentity, toolName }) => {
    if (typeof toolName !== 'string') throw new TypeError('toolName must be a string');
    return { identity: identity(serverBindingIdentity), name: Buffer.from(toolName) };
  });
}

async function* routeLargeToolFrame(chunks, line, handleInterleaved, requestId) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'mcp-stdio-'));
  const filename = path.join(directory, 'frame');
  try {
    const envelope = Buffer.allocUnsafe(MAX_FRAME);
    let length = 0, envelopeLength = 0, depth = 0, quoted = false, escaped = false;
    async function append(chunk) {
      length += chunk.length;
      if (length > MAX_TOOL_FRAME) throw new RangeError('MCP tool frame too large');
      const text = chunk.toString('latin1');
      for (let i = 0; i < text.length; i++) {
        const char = text[i];
        const outside = depth < 2;
        if (!quoted && (char === ' ' || char === '\t' || char === '\r')) continue;
        if (quoted) {
          if (escaped) escaped = false;
          else if (char === '\\') escaped = true;
          else if (char === '"') quoted = false;
        } else if (char === '"') quoted = true;
        else if (char === '{' || char === '[') depth++;
        else if (char === '}' || char === ']') depth--;
        if (outside || depth < 2) {
          if (envelopeLength === MAX_FRAME) throw new RangeError('MCP control frame too large');
          envelope[envelopeLength++] = chunk[i];
        }
      }
      await file.writeFile(chunk);
    }
    const file = await open(filename, 'wx+', 0o600);
    try {
      if (process.platform !== 'win32') await unlink(filename);
      for (const chunk of chunks) await append(chunk);
      for await (const chunk of line) await append(chunk);
      if (await handleInterleaved(envelope.subarray(0, envelopeLength), requestId)) return false;
      yield* file.createReadStream({ start: 0 });
      return true;
    } finally {
      await file.close();
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function stdio({ command, args = [], cwd, env }) {
  if (typeof command !== 'string' || !command || !Array.isArray(args) || args.some(arg => typeof arg !== 'string'))
    throw new TypeError('MCP stdio requires a command and string arguments');
  const argv = [...args];
  const environment = env && { ...env };
  return async function open() {
    const child = spawn(command, argv, { cwd, env: environment, stdio: ['pipe', 'pipe', 'ignore'], windowsHide: true });
    child.stdin.on('error', () => {});
    try { await once(child, 'spawn'); } catch (cause) {
      throw Object.assign(new Error('MCP server failed to start', { cause }), { code: 'child_exit' });
    }
    const stdout = child.stdout[Symbol.asyncIterator]();
    let tail = Buffer.alloc(0);
    let toolStream;
    const send = frame => new Promise((resolve, reject) => child.stdin.write(frame + '\n', error => error ? reject(error) : resolve()));
    async function* readLine() {
      for (;;) {
        if (!tail.length) {
          const next = await stdout.next();
          if (next.done) throw Object.assign(new Error('MCP server closed stdout'), { code: 'child_exit' });
          tail = next.value;
        }
        const newline = tail.indexOf(10);
        const chunk = newline < 0 ? tail : tail.subarray(0, newline);
        tail = newline < 0 ? Buffer.alloc(0) : tail.subarray(newline + 1);
        if (chunk.length) yield chunk;
        if (newline >= 0) return;
      }
    }
    async function handleInterleaved(body, requestId) {
      let message;
      try { message = JSON.parse(body); } catch { return false; }
      if (message?.jsonrpc !== '2.0') return false;
      if (message.id != null && typeof message.id !== 'number' && typeof message.id !== 'string') return false;
      const id = encodedId(body, message.id);
      if (typeof message.method !== 'string') return message.id != null && id !== requestId;
      if (message.id != null) {
        const reply = message.method === 'ping' ? '"result":{}' : '"error":{"code":-32601,"message":"Method not found"}';
        await send('{"jsonrpc":"2.0","id":' + id + ',' + reply + '}');
      }
      return true;
    }
    async function* exchange(frame, stream) {
      const requestId = encodedId(frame, JSON.parse(frame).id);
      await send(frame);
      frames: for (;;) {
        const chunks = [];
        let size = 0;
        const line = readLine();
        let discard = false;
        for await (const chunk of line) {
          if (discard) continue;
          if (stream && size < 256) {
            const prefix = size ? Buffer.concat([...chunks, chunk], Math.min(256, size + chunk.length)) : chunk;
            const header = toolResponseHeader.exec(prefix.toString('latin1', 0, 256));
            if (header) {
              if (header[1] !== requestId) {
                discard = true;
                continue;
              }
              yield* chunks;
              yield chunk;
              yield* line;
              return;
            }
          }
          size += chunk.length;
          chunks.push(chunk);
          if (size > MAX_FRAME) {
            if (!stream) throw new RangeError('MCP control frame too large');
            if (yield* routeLargeToolFrame(chunks, line, handleInterleaved, requestId)) return;
            continue frames;
          }
        }
        if (discard) continue;
        const body = Buffer.concat(chunks, size);
        if (await handleInterleaved(body, requestId)) continue;
        yield body;
        return;
      }
    }
    return {
      async request(frame) {
        for await (const body of exchange(frame, false)) return { body };
      },
      requestToolStream(frame) {
        toolStream = exchange(frame, true);
        return toolStream;
      },
      notify: send,
      async close() {
        child.stdin.destroy();
        child.stdout.destroy();
        child.kill('SIGKILL');
        await toolStream?.return();
      },
    };
  };
}

async function* toolChunks(stream) {
  for await (const bytes of stream) {
    if (!(bytes instanceof Uint8Array)) throw new TypeError('MCP tool stream must yield bytes');
    for (let offset = 0; offset < bytes.length; offset += 65536) yield bytes.subarray(offset, offset + 65536);
  }
}

function dispatcher(open, native) {
  const connections = new Map();
  return async function dispatch(op, id, frame, purpose, era, timeoutMs, ticket) {
    let state = connections.get(id);
    if (op === 'close') {
      connections.delete(id);
      state?.controller?.abort();
      try { await (await state?.connection)?.close(); } catch {}
      return;
    }
    let body, httpStatus = 0, done = true;
    let status = 0;
    try {
      if (op === 'open') {
        state = {};
        connections.set(id, state);
        state.connection = Promise.resolve(open({ purpose: purpose === 1 ? 'probe' : 'actual', era: eras[era - 1], timeoutMs }));
        await state.connection;
      } else {
        const connection = await state.connection;
        if (op !== 'next') state.controller = new AbortController();
        const options = { timeoutMs, signal: state.controller.signal };
        if (op === 'notify') await connection.notify(frame, options);
        else if (op === 'request') {
          const result = await connection.request(frame, options);
          body = result.body;
          httpStatus = result.httpStatus ?? 0;
        } else {
          if (op === 'stream') state.stream = toolChunks(await connection.requestToolStream(frame, options));
          const next = await state.stream.next();
          done = !!next.done;
          if (done) state.stream = null;
          else body = next.value;
        }
      }
      if (body !== undefined) {
        if (typeof body !== 'string' && !(body instanceof Uint8Array)) throw new TypeError('invalid MCP response');
        body = typeof body === 'string' ? Buffer.from(body) : Buffer.from(body.buffer, body.byteOffset, body.byteLength);
        if (op === 'request' && body.length > MAX_FRAME) throw new RangeError('MCP control frame too large');
      }
    } catch (error) {
      const code = outcomes.indexOf(error?.code);
      if (op === 'open') status = code >= 1 && code <= 5 ? code : 6;
      else if (code >= 1) status = code;
      else status = op === 'stream' || op === 'next' ? 7 : 8;
    }
    native.mcpReply(ticket, status, httpStatus, body, done);
  };
}

function servers(list, native) {
  if (!Array.isArray(list) || list.length > 64) throw new RangeError('mcpServers allows up to 64 servers');
  return Array.from(list, server => {
    const { namespace, serverBindingIdentity, configurationFingerprint, clientName = 'metacodes-node',
      clientVersion = '1', timeoutMs = 10000, negotiationPolicy = 'auto', transport = 'stdio' } = server;
    const transportCode = ['stdio', 'streamable_http'].indexOf(transport) + 1;
    const policy = policies.indexOf(negotiationPolicy) + 1;
    if (!transportCode || !policy || !Number.isInteger(timeoutMs) || timeoutMs <= 0 || timeoutMs > 0xffffffff ||
        [namespace, clientName, clientVersion].some(value => typeof value !== 'string'))
      throw new TypeError('invalid MCP server options');
    const open = server.open ?? (transport === 'stdio' && stdio(server));
    if (typeof open !== 'function') throw new TypeError('MCP server requires an open function');
    let limits = null;
    if (server.protocolLimits != null) {
      limits = {};
      for (const key of ['maxFrameBytes', 'maxTools', 'maxToolNameBytes', 'maxTextBytes', 'maxSchemaBytes',
        'maxJsonDepth', 'maxJsonNodes', 'maxCursorBytes', 'maxVersions']) {
        const value = server.protocolLimits[key];
        if (!Number.isSafeInteger(value) || value <= 0) throw new TypeError(`invalid MCP protocol limit ${key}`);
        limits[key] = BigInt(value);
      }
    }
    return { namespace: Buffer.from(namespace), clientName: Buffer.from(clientName), clientVersion: Buffer.from(clientVersion), limits,
      identity: identity(serverBindingIdentity), fingerprint: identity(configurationFingerprint),
      timeoutMs, policy, transport: transportCode, dispatch: dispatcher(open, native) };
  });
}

module.exports = { selection, servers };
