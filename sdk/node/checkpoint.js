'use strict';

const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const { createHash } = require('node:crypto');

const MAX_CHECKPOINT = 64 * 1024 * 1024;
const MAX_BLOB = 128 * 1024 * 1024;
const MAX_STORE = 1024 * 1024 * 1024;
const DIGEST = /^[0-9a-f]{64}$/;
const SESSION_ID = /^[0-9a-f]{24}$/;

async function directory(root, parts, create = false) {
  let dir = root;
  for (const part of parts) {
    dir = path.join(dir, part);
    if (create) await fsp.mkdir(dir, { mode: 0o700 }).catch(e => { if (e.code !== 'EEXIST') throw e; });
    if (!(await fsp.lstat(dir)).isDirectory()) throw new Error('Expected a directory at ' + dir);
  }
  return dir;
}

async function regular(file, limit) {
  const before = await fsp.lstat(file);
  if (!before.isFile() || before.size > limit) throw new Error('Invalid snapshot file ' + file);
  const handle = await fsp.open(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.ino !== before.ino || stat.dev !== before.dev || stat.size > limit)
      throw new Error('Snapshot file changed ' + file);
    return handle;
  } catch (error) {
    await handle.close();
    throw error;
  }
}

async function transfer(source, destination, limit, expected) {
  const input = await regular(source, limit);
  try {
    const output = destination && await fsp.open(destination, 'wx', 0o600);
    try {
      const digest = createHash('sha256');
      const buffer = Buffer.allocUnsafe(65536);
      let size = 0;
      for (;;) {
        const { bytesRead } = await input.read(buffer);
        if (!bytesRead) break;
        size += bytesRead;
        if (size > limit) throw new Error('Snapshot size limit exceeded');
        const chunk = buffer.subarray(0, bytesRead);
        digest.update(chunk);
        if (output) await output.writeFile(chunk);
      }
      const sha256 = digest.digest('hex');
      if (expected && (expected.sha256 !== sha256 || expected.size !== size)) throw new Error('Snapshot integrity check failed');
      return { sha256, size };
    } finally { if (output) await output.close(); }
  } finally { await input.close(); }
}

async function exclusive(lockPath, work) {
  const lock = await fsp.open(lockPath, 'wx', 0o600);
  try { return await work(); }
  finally {
    await lock.close();
    await fsp.unlink(lockPath);
  }
}

function sessionParts(id) {
  if (!SESSION_ID.test(id)) throw new Error('Invalid snapshot session ID');
  return ['.metacodes', 'agentcore', 'sessions', id, 'tool-results', 'sha256'];
}

async function exportSnapshot(session, target) {
  const id = session.describe().session_id;
  const dest = path.resolve(target);
  return exclusive(dest + '.lock', async () => {
    await fsp.lstat(dest).then(() => { throw new Error('Snapshot destination already exists'); },
      error => { if (error.code !== 'ENOENT') throw error; });
    const stage = await fsp.mkdtemp(dest + '.tmp-');
    try {
      const binary = path.join(stage, 'checkpoint.bin');
      const file = await fsp.open(binary, 'wx', 0o600);
      try {
        session._native.sessionExport(session._handle, (buffer, length) => fs.writeSync(file.fd, buffer, 0, length));
      } finally { await file.close(); }
      const checkpoint = await transfer(binary, null, MAX_CHECKPOINT);
      const blobs = [];
      const source = await directory(session._workspaceHome, sessionParts(id)).catch(error => {
        if (error.code !== 'ENOENT') throw error;
      });
      const blobDir = await directory(stage, ['blobs'], true);
      let total = 0;
      for (const name of source ? (await fsp.readdir(source)).sort() : []) {
        const hash = name.endsWith('.blob') && name.slice(0, -5);
        if (!hash || !DIGEST.test(hash)) continue;
        const entry = await transfer(path.join(source, name), path.join(blobDir, name), Math.min(MAX_BLOB, MAX_STORE - total));
        if (entry.sha256 !== hash) throw new Error('Artifact digest mismatch ' + name);
        total += entry.size;
        blobs.push(entry);
      }
      await fsp.writeFile(path.join(stage, 'manifest.json'), JSON.stringify({ version: 1, sessionId: id, checkpoint, blobs }), { flag: 'wx', mode: 0o600 });
      await fsp.rename(stage, dest);
    } finally { await fsp.rm(stage, { recursive: true, force: true }); }
  });
}

function validate(entry, limit) {
  if (!entry || typeof entry.sha256 !== 'string' || !DIGEST.test(entry.sha256) ||
      !Number.isSafeInteger(entry.size) || entry.size < 0 || entry.size > limit) throw new Error('Invalid snapshot manifest entry');
}

async function restoreSnapshot(source, home, createSession) {
  const root = await fsp.realpath(source);
  const manifest = await regular(path.join(root, 'manifest.json'), 16 * 1024 * 1024);
  let data;
  try { data = JSON.parse(await manifest.readFile('utf8')); }
  finally { await manifest.close(); }
  if (data.version !== 1 || typeof data.sessionId !== 'string' || !Array.isArray(data.blobs)) throw new Error('Invalid snapshot manifest');
  const parts = sessionParts(data.sessionId);
  validate(data.checkpoint, MAX_CHECKPOINT);
  const hashes = new Set();
  let total = 0;
  for (const entry of data.blobs) {
    validate(entry, Math.min(MAX_BLOB, MAX_STORE - total));
    if (hashes.has(entry.sha256)) throw new Error('Duplicate artifact');
    hashes.add(entry.sha256);
    total += entry.size;
  }
  const blobs = await directory(root, ['blobs']);
  const base = await directory(await fsp.realpath(home), parts.slice(0, 3), true);
  return exclusive(path.join(base, data.sessionId + '.restore.lock'), async () => {
    const stage = await fsp.mkdtemp(path.join(base, '.restore-'));
    const installed = [];
    let session;
    try {
      const binary = path.join(stage, 'checkpoint.bin');
      await transfer(path.join(root, 'checkpoint.bin'), binary, MAX_CHECKPOINT, data.checkpoint);
      for (const entry of data.blobs) {
        const name = entry.sha256 + '.blob';
        await transfer(path.join(blobs, name), path.join(stage, name), entry.size, entry);
      }
      const input = await fsp.open(binary, 'r');
      try { session = createSession((buffer, length) => fs.readSync(input.fd, buffer, 0, length)); }
      finally { await input.close(); }
      if (session.restoreReport.session_id !== data.sessionId) throw new Error('Checkpoint session ID mismatch');
      const cas = await directory(base, parts.slice(3), true);
      for (const entry of data.blobs) {
        const name = entry.sha256 + '.blob';
        const dest = path.join(cas, name);
        try {
          await fsp.link(path.join(stage, name), dest);
          installed.push(dest);
        } catch (error) {
          if (error.code !== 'EEXIST') throw error;
          await transfer(dest, null, entry.size, entry);
        }
      }
      return session;
    } catch (error) {
      if (session) session.close();
      for (const file of installed) await fsp.unlink(file);
      throw error;
    } finally { await fsp.rm(stage, { recursive: true, force: true }); }
  });
}

module.exports = { exportSnapshot, restoreSnapshot };
