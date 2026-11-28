'use strict';

const { spawn } = require('node:child_process');
const { once } = require('node:events');

const MAX_FRAME = 8388608;
const policies = ['auto', 'modern_only', 'legacy_only', 'legacy_2025_06_only'];
const eras = ['2026-07-28', '2025-11-25', '2025-06-18'];
const outcomes = ['response', 'timeout', 'network_error', 'auth_error', 'server_error', 'child_exit', 'cancelled', 'indeterminate', 'fatal'];

function identity(hex) {
  if (typeof hex !== 'string' || !/^[a-f\d]{64}$/i.test(hex) || /^0+$/.test(hex))
    throw new TypeError('MCP identity and fingerprint must be nonzero 32-byte hex strings');
  return Buffer.from(hex, 'hex');
}

function selection(selectors) {
  if (!Array.isArray(selectors) || selectors.length > 1024) throw new RangeError('invalid MCP selection');
  return Array.from(selectors, ({ serverBindingIdentity, toolName }) => {
    if (typeof toolName !== 'string') throw new TypeError('toolName must be a string');
    return { identity: identity(serverBindingIdentity), name: Buffer.from(toolName) };
  });
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
    const send = frame => new Promise((resolve, reject) => child.stdin.write(frame + '\n', error => error ? reject(error) : resolve()));
    async function* exchange(frame) {
      await send(frame);
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
    return {
      async request(frame) {
        const chunks = [];
        let size = 0;
        for await (const chunk of exchange(frame)) {
          size += chunk.length;
          if (size > MAX_FRAME) throw new RangeError('MCP control frame too large');
          chunks.push(chunk);
        }
        return { body: Buffer.concat(chunks, size) };
      },
      requestToolStream: exchange,
      notify: send,
      close() {
        child.stdin.destroy();
        child.stdout.destroy();
        child.kill('SIGKILL');
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
