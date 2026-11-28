'use strict';

const os = require('node:os');
const path = require('node:path');

const PLATFORM_DIR = path.join(__dirname, 'prebuilds', `${process.platform}-${process.arch}`);

function libraryFileName() {
  if (process.platform === 'darwin') return 'libmetask_agentcore.dylib';
  if (process.platform === 'win32') return 'metask_agentcore.dll';
  return 'libmetask_agentcore.so';
}

/** Where the AgentCore shared library is looked for, in order. */
function candidateLibraryPaths(explicit) {
  if (explicit) return [path.resolve(explicit)];
  const name = libraryFileName();
  const paths = [];
  if (process.env.METACODES_AGENTCORE_LIB) paths.push(path.resolve(process.env.METACODES_AGENTCORE_LIB));
  paths.push(path.join(PLATFORM_DIR, name));
  if (process.env.METACODES_AGENTCORE_SDK) paths.push(path.join(process.env.METACODES_AGENTCORE_SDK, 'lib', name));
  const opt = path.join(os.homedir(), '.local', 'opt');
  paths.push(path.join(opt, 'metacodes', 'sdk', 'agentcore', 'lib', name));
  paths.push(path.join(opt, 'metacodes-dev', 'sdk', 'agentcore', 'lib', name));
  return paths;
}

function addonPath() {
  return path.join(PLATFORM_DIR, 'metacodes.node');
}

module.exports = { addonPath, candidateLibraryPaths };
