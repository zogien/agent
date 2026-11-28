import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { once } from 'node:events';
import { createReadStream, promises as fs } from 'node:fs';
import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { mainPackage, tarballIntegrity } from './release-metadata.mjs';

const dist = path.resolve(process.argv[2]);
const electron = createRequire(import.meta.url)(path.resolve(process.argv[3]));
const release = JSON.parse(await fs.readFile(path.join(dist, 'release.json')));
const metadata = new Map();
const files = new Map();
for (const { name, filename, integrity } of release.packages) {
  assert.equal(path.basename(filename), filename);
  const file = path.join(dist, filename);
  assert.equal(tarballIntegrity(file), integrity);
  const pkg = JSON.parse(execFileSync('tar', ['-xOf', file, 'package/package.json']));
  assert.equal(pkg.name, name);
  assert.equal(pkg.version, release.version);
  files.set('/' + filename, file);
  metadata.set('/' + name, { pkg, filename, integrity });
}

const server = createServer((req, res) => {
  const route = decodeURIComponent(req.url);
  if (files.has(route)) return createReadStream(files.get(route)).pipe(res);
  const entry = metadata.get(route);
  if (!entry) { res.writeHead(404).end(); return; }
  const { pkg, filename, integrity } = entry;
  res.setHeader('Content-Type', 'application/json');
  res.end(JSON.stringify({ name: pkg.name, 'dist-tags': { latest: pkg.version }, versions: {
    [pkg.version]: { ...pkg, dist: { integrity, tarball: registry + '/' + filename } },
  } }));
});
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const registry = 'http://127.0.0.1:' + server.address().port;
const work = await fs.mkdtemp(path.join(tmpdir(), 'agent-sdk-install-'));
const env = { ...process.env, AGENT_SDK_TEST_INSTALLED: '1', METACODES_NODE_SDK_REQUIRE_LIB: '1' };
env.METACODES_TEST_PYTHON = execFileSync(process.platform === 'win32' ? 'python' : 'python3',
  ['-c', 'import sys; print(sys.executable)'], { encoding: 'utf8' }).trim();
env.METACODES_MOCK_MCP_HTTP = path.resolve('tests/_harness/mock_mcp_http_server.py');
delete env.ELECTRON_RUN_AS_NODE;
for (const key of ['METACODES_AGENTCORE_LIB', 'METACODES_AGENTCORE_SDK', 'RG_BIN', 'NODE_PATH']) delete env[key];
for (const key of Object.keys(env)) {
  if (key.toUpperCase() === 'PATH') delete env[key];
}
env.PATH = path.dirname(process.execPath);

async function run(exe, args) {
  const child = spawn(exe, args, { cwd: work, stdio: 'inherit', env });
  const [status, signal] = await once(child, 'exit');
  assert.equal(status, 0, exe + ' exited with ' + (signal || status));
}

try {
  await fs.writeFile(path.join(work, 'package.json'), '{"name":"sdk-consumer","private":true}');
  const args = ['install', mainPackage + '@' + release.version, '--registry', registry, '--cache', path.join(work, 'cache'), '--no-audit', '--no-fund'];
  if (process.platform === 'win32') {
    await run(process.execPath, [path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js'), ...args]);
  } else {
    await run('npm', args);
  }
  for (const file of ['metacodes.test.js', 'mock_provider.js']) {
    await fs.copyFile(new URL('../../sdk/node/test/' + file, import.meta.url), path.join(work, file));
  }
  await fs.copyFile(new URL('./electron-smoke.cjs', import.meta.url), path.join(work, 'electron-smoke.cjs'));
  await run(process.execPath, ['--test', 'metacodes.test.js']);
  await run(electron, [path.join(work, 'electron-smoke.cjs')]);
  await run(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const fs = require('node:fs');
    const sdk = require('@zogien/agent-sdk');
    const bundle = sdk.resolve();
    const manifest = require(bundle.manifestPath);
    manifest.contract.binary_abi_revision++;
    assert.throws(() => new sdk.Runtime(), /ABI revision mismatch/);
    fs.renameSync(bundle.root, bundle.root + '.missing');
  `]);
  await run(process.execPath, ['-e', `
    const assert = require('node:assert/strict');
    const sdk = require('@zogien/agent-sdk');
    assert.throws(() => new sdk.Runtime(), /optional dependency/);
  `]);
} finally {
  server.close();
  await fs.rm(work, { recursive: true, force: true });
}
