#!/usr/bin/env node
'use strict';
// Build the native addon for this platform and stage it with an AgentCore bundle:
//
//   zig build agentcore:bundle -Dtarget=<target> -Doptimize=ReleaseSafe
//   node sdk/node/scripts/build.js --bundle zig-out/agentcore/<resolved-target>
//
// Output: sdk/node/prebuilds/<platform>-<arch>/{metacodes.node, metacodes-LICENSE,
// libmetask_agentcore.*, rg, ripgrep-LICENSE-MIT}.
// The addon is compiled with `zig cc` against this Node's own Node-API headers
// (<node prefix>/include/node, or NODE_INCLUDE_DIR) and the repository's
// sdk/metask/agentcore.h. Without --bundle only the addon is built. A bundle must
// be the AgentCore release this package declares (scripts/verify_bundle.js), and
// --release refuses a development one, before anything is compiled.

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
if (bundle) {
  const { verifyBundle } = require('./verify_bundle.js');
  try {
    verifyBundle(bundle, { release: process.argv.includes('--release') });
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
const args = [
  'cc', '-shared', '-target', platform.target, '-O2', '-std=c11',
  '-Wall', '-Wextra', '-Wno-unused-parameter',
  '-I', nodeInclude,
  '-I', path.join(repo, 'sdk'),
  '-o', path.join(out, 'metacodes.node'),
  path.join(here, 'src', 'addon.c'),
];
if (platform.os === 'win32') {
  const source = fs.readFileSync(path.join(here, 'src', 'addon.c'), 'utf8');
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
  const manifest = JSON.parse(fs.readFileSync(path.join(bundle, 'manifest.json'), 'utf8'));
  if (manifest.target.id !== platform.target) throw new Error('SDK and addon targets differ');
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
