# @zogien/agent-sdk

Run AgentCore from Node.js or Electron main with its prebuilt Node-API binding.
The platform package also includes the C ABI libraries, header, Zig and Rust bindings and runtime helpers.

```sh
npm install @zogien/agent-sdk
```

```js
const { Runtime } = require('@zogien/agent-sdk');

async function ask(model, prompt) {
  const runtime = new Runtime();
  try {
    const session = runtime.session(model, { workspace: '.', provider: 'anthropic' });
    return await session.run(prompt);
  } finally {
    runtime.close();
  }
}
```

Supply the provider credential with `apiKey` or its environment variable.
The [Node SDK guide](https://github.com/zogien/agent/blob/main/sdk/node/README.md)
covers streams, JavaScript tools, cancellation and portable checkpoints.

This package holds no binaries. Each platform's bundle is its own package, and
npm installs the one that matches the machine:

| Platform            | Package                             | AgentCore target      |
| ------------------- | ----------------------------------- | --------------------- |
| Windows x64         | `@zogien/agent-sdk-win32-x64`        | `x86_64-windows-msvc`  |
| Windows ARM64       | `@zogien/agent-sdk-win32-arm64`      | `aarch64-windows-msvc` |
| macOS ARM64         | `@zogien/agent-sdk-darwin-arm64`     | `aarch64-macos`        |
| macOS x64           | `@zogien/agent-sdk-darwin-x64`       | `x86_64-macos`         |
| Linux x64 (glibc)    | `@zogien/agent-sdk-linux-x64-gnu`    | `x86_64-linux-gnu`     |
| Linux ARM64 (glibc)  | `@zogien/agent-sdk-linux-arm64-gnu`  | `aarch64-linux-gnu`    |

## Finding the bundle

```js
const agentcore = require("@zogien/agent-sdk");

const bundle = agentcore.resolve();
bundle.root; // the bundle directory, with manifest.json directly inside
bundle.includeDir; // include/metask/agentcore.h
bundle.libDir; // the static and shared libraries
bundle.target; // "x86_64-windows-msvc"
```

`resolve()` only says where the bundle is. Consume the bundle whole and check it
against its `manifest.json`, as the bundle's own README describes.

## Building for another platform

npm installs the package for the machine it runs on. To fetch a different
platform's bundle, say so at install time:

```sh
npm install --os=win32 --cpu=arm64
```

and ask for it by name:

```js
agentcore.resolve({ platform: "win32", arch: "arm64" });
```

## Versions

Every package here carries the same version, which is AgentCore's own. Pin it
exactly: these are `-fork.N` versions, which a `^` or `~` range does not match.
