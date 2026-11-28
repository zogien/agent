#!/usr/bin/env node
'use strict';

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const here = path.resolve(__dirname, '..');
const repo = path.resolve(here, '..', '..');

function argument(name) {
  const index = process.argv.indexOf(name);
  return index === -1 ? null : process.argv[index + 1];
}

const platforms = require('../../../scripts/npm/platforms.json').platforms;
const selected = argument('--target');
const platform = platforms.find(p => selected ? p.target === selected : p.os === process.platform && p.cpu === process.arch);
if (!platform) throw new Error('Unsupported Node addon target');

let bundle = argument('--bundle');
const artifact = argument('--artifact');
if (artifact) {
  const base = path.join(repo, 'zig-out', 'agentcore');
  const roots = fs.readdirSync(base).map(dir => path.join(base, dir)).filter(dir => {
    const file = path.join(dir, 'manifest.json');
    return fs.existsSync(file) && JSON.parse(fs.readFileSync(file)).target.id === platform.target;
  });
  if (roots.length !== 1) throw new Error('Expected one built SDK bundle for ' + platform.target);
  bundle = roots[0];
}
let manifest;
if (bundle) {
  const { verifyBundle } = require('./verify_bundle.js');
  try {
    manifest = verifyBundle(bundle, { release: process.argv.includes('--release') });
    if (manifest.target.id !== platform.target) throw new Error('SDK and addon targets differ');
    if (artifact && manifest.source.commit !== execFileSync('git', ['rev-parse', 'HEAD'], { cwd: repo, encoding: 'utf8' }).trim())
      throw new Error('SDK and addon source commits differ');
    if (artifact && process.argv.includes('--release') && (manifest.source.dirty ||
        execFileSync('git', ['status', '--porcelain'], { cwd: repo, encoding: 'utf8' }).trim()))
      throw new Error('release requires clean SDK and addon sources');
  } catch (error) {
    console.error(`metacodes: cannot package ${bundle}: ${error.message}`);
    process.exit(1);
  }
}
const out = path.resolve(argument('--out') || path.join(here, 'prebuilds', `${platform.os}-${platform.cpu}`));
const zig = process.env.ZIG || 'zig';
const nodeInclude = process.env.NODE_INCLUDE_DIR || path.join(path.dirname(require.resolve('node-api-headers/package.json')), 'include');
if (!fs.existsSync(path.join(nodeInclude, 'node_api.h'))) {
  console.error(`metacodes: node_api.h not found in ${nodeInclude}; set NODE_INCLUDE_DIR`);
  process.exit(1);
}

fs.mkdirSync(out, { recursive: true });
const codec = path.join(out, 'protocol.o');
const target = manifest?.target.zig_target || platform.target;
execFileSync(zig, ['build-obj', '-O', 'ReleaseSafe', '-target', target, '-fPIC', '-lc',
  '--dep', 'protocol', '-Mroot=' + path.join(here, 'src/protocol.zig'),
  '-Mprotocol=' + path.join(repo, 'sdk/zig/protocol.zig'), '-femit-bin=' + codec], { stdio: 'inherit' });
const args = [
  'cc', '-shared', '-target', target, '-O2', '-std=c11',
  '-Wall', '-Wextra', '-Wno-unused-parameter',
  '-I', nodeInclude,
  '-I', path.join(repo, 'sdk'),
  '-o', path.join(out, 'metacodes.node'),
  path.join(here, 'src', 'addon.c'),
  codec,
];
if (platform.os === 'win32') {
  const source = ['addon.c', 'mcp_bridge.h'].map(file => fs.readFileSync(path.join(here, 'src', file), 'utf8')).join('\n');
  const symbols = [...new Set(Array.from(source.matchAll(/\b(napi_\w+)\s*\(/g), m => m[1]))].sort();
  fs.writeFileSync(path.join(out, 'host_api.h'), [
    ...symbols.map(name => `static __typeof__(&${name}) host_${name};`),
    'static BOOL CALLBACK bind_host_api(PINIT_ONCE once, PVOID arg, PVOID *ctx) {',
    '  HMODULE host = GetModuleHandleW(L"libnode.dll");',
    '  if (!host) host = GetModuleHandleW(NULL);',
    ...symbols.map(name => `  if (!(host_${name} = (__typeof__(&${name}))GetProcAddress(host, "${name}"))) return FALSE;`),
    '  return TRUE;',
    '}',
    'static int load_host_api(void) {',
    '  static INIT_ONCE once = INIT_ONCE_STATIC_INIT;',
    '  return InitOnceExecuteOnce(&once, bind_host_api, NULL, NULL);',
    '}',
    ...symbols.map(name => `#define ${name} host_${name}`),
  ].join('\n'));
  args.push('-I', out);
} else {
  args.push('-fPIC', '-pthread');
  if (platform.os === 'darwin') args.push('-Wl,-undefined,dynamic_lookup');
}
execFileSync(zig, args, { stdio: 'inherit' });

fs.copyFileSync(path.join(repo, 'LICENSE'), path.join(out, 'metacodes-LICENSE'));

if (bundle) {
  if (artifact) {
    fs.mkdirSync(artifact, { recursive: true });
    const file = path.join(artifact, platform.target + '.node');
    fs.copyFileSync(path.join(out, 'metacodes.node'), file);
    const sha256 = require('node:crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex');
    fs.writeFileSync(file + '.json', JSON.stringify({ target: platform.target, version: manifest.version,
      commit: manifest.source.commit, revision: manifest.contract.binary_abi_revision, sha256 }));
  }
  const library = path.join(bundle, manifest.shared_library.path);
  fs.copyFileSync(library, path.join(out, path.basename(library)));
  const bin = path.join(bundle, 'bin');
  if (fs.existsSync(bin)) {
    for (const name of fs.readdirSync(bin)) {
      fs.copyFileSync(path.join(bin, name), path.join(out, name));
      if (name === 'rg') fs.chmodSync(path.join(out, name), 0o755);
    }
  }
}
console.log(out);
