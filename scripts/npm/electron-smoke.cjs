'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { app } = require('electron');
const { startMockProvider } = require('./mock_provider');
const { Runtime } = require('@zogien/agent-sdk');

async function check() {
  await app.whenReady();
  assert.equal(process.type, 'browser');
  fs.writeFileSync('electron-check.txt', 'needle-731\n');
  const mock = await startMockProvider([
    ['tool', 'Grep', { pattern: 'needle-[0-9]+', path: 'electron-check.txt', output_mode: 'content' }],
    ['echo'],
  ]);
  const runtime = new Runtime();
  try {
    const session = runtime.session('mock-model', { workspace: process.cwd(), baseUrl: mock.baseUrl, apiKey: 'local' });
    const result = await session.run('hello');
    assert.match(result.text, /needle-731/);
    assert.equal(result.runId, 1n);
    console.log('Electron main passed', process.versions.electron, process.platform, process.arch);
  } finally {
    runtime.close();
    await mock.close();
  }
}

check().then(() => app.exit(0), error => { console.error(error); app.exit(1); });
