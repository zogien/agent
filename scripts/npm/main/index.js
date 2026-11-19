"use strict";

// Locates the AgentCore SDK bundle installed for a platform.
//
// This package holds no binaries. Each platform's bundle is its own package,
// listed here as an optional dependency, and npm installs the one matching the
// machine. `resolve()` says where that bundle is; it does not load it.

const path = require("node:path");

const PACKAGES = Object.freeze(require("./platforms.json"));

function isMusl() {
  if (process.platform !== "linux") return false;
  const report = process.report && process.report.getReport();
  return !(report && report.header && report.header.glibcVersionRuntime);
}

function resolve(options = {}) {
  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  const entry = PACKAGES[`${platform}-${arch}`];
  if (!entry)
    throw new Error(`@zogien/agentcore has no bundle for ${platform}-${arch}`);
  if (!options.platform && !options.arch && isMusl())
    throw new Error(
      "@zogien/agentcore has no bundle for musl; the Linux bundles are built for glibc",
    );

  let manifestPath;
  try {
    manifestPath = require.resolve(`${entry.package}/manifest.json`);
  } catch (cause) {
    const error = new Error(
      `${entry.package} is not installed. It is an optional dependency of ` +
        "@zogien/agentcore: reinstall without --omit=optional, or, for a " +
        `platform other than this machine's, install with --os=${platform} --cpu=${arch}.`,
    );
    error.cause = cause;
    throw error;
  }

  const root = path.dirname(manifestPath);
  const manifest = require(manifestPath);
  return {
    package: entry.package,
    target: manifest.target.id,
    version: manifest.version,
    abiRevision: manifest.contract.binary_abi_revision,
    root,
    manifestPath,
    includeDir: path.join(root, "include"),
    libDir: path.join(root, "lib"),
    binDir: path.join(root, "bin"),
    bindingsDir: path.join(root, "bindings"),
    sharedLibrary: path.join(root, manifest.shared_library.path),
  };
}

module.exports = { resolve, packages: PACKAGES };
