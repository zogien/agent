import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  config,
  mainPackage,
  packageTarballs,
  tarballIntegrity,
  versionFromTag,
} from "./release-metadata.mjs";

const [archives, tag, commit, destination, addons] = process.argv.slice(2);
assert(
  archives && tag && commit && destination && addons,
  "usage: node pack-release.mjs <archives-dir> <fork-tag> <commit> <out-dir> <addons-dir>",
);
assert(process.platform !== "win32", "pack on a POSIX filesystem to preserve executable bits");
const version = versionFromTag(tag);
assert.match(commit, /^[0-9a-f]{40}$/);
const license = fileURLToPath(new URL("../../LICENSE", import.meta.url));
const out = path.resolve(destination);
const packages = packageTarballs(version);
const mainTarball = packages.at(-1);
const optionalDependencies = Object.fromEntries(
  packages.slice(0, -1).map(({ name }) => [name, version]),
);
const repositoryMetadata = {
  repository: { type: "git", url: config.repository },
  homepage: config.homepage,
  license: config.license,
};
const publishConfig = { access: "public", registry: "https://registry.npmjs.org/" };
const archiveNames = config.platforms.map(({ target, os }) => {
  const extension = os === "win32" ? "zip" : "tar.gz";
  return `metask-agentcore-${version}-${target}.${extension}`;
});

const expectedFiles = archiveNames.flatMap((name) => [name, `${name}.sha256`]);
assert.deepEqual(readdirSync(archives).sort(), expectedFiles.sort(), "SDK archive set");
for (const name of archiveNames) {
  const file = path.resolve(archives, name);
  assert.equal(readFileSync(`${file}.sha256`, "utf8").trimEnd(), `${sha256(file)}  ${name}`);
}

function sha256(file) {
  return createHash("sha256").update(readFileSync(file)).digest("hex");
}

function listFiles(root, relative = "") {
  const files = [];
  for (const entry of readdirSync(path.join(root, relative), { withFileTypes: true })) {
    const child = path.posix.join(relative, entry.name);
    assert(entry.isFile() || entry.isDirectory(), `unexpected archive entry: ${child}`);
    if (entry.isDirectory()) files.push(...listFiles(root, child));
    else files.push(child);
  }
  return files;
}

function verifyBundle(root, manifest, extraFiles) {
  const expected = [...manifest.files.map(({ path }) => path), ...extraFiles];
  assert.deepEqual(listFiles(root).sort(), expected.sort(), `SDK files in ${root}`);
  for (const file of manifest.files) {
    assert.equal(sha256(path.join(root, file.path)), file.sha256, file.path);
  }
}

function writeJson(file, value) {
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`);
}

function pack(root, expected, metadata) {
  writeJson(path.join(root, "package.json"), metadata);
  copyFileSync(license, path.join(root, "LICENSE"));
  const [packed] = JSON.parse(execFileSync(
    "npm",
    ["pack", root, "--pack-destination", out, "--ignore-scripts", "--json"],
    { cwd: out, encoding: "utf8" },
  ));
  assert.equal(packed.name, expected.name);
  assert.equal(packed.version, version);
  assert.equal(packed.filename, expected.filename);
  console.log(`Packed ${packed.name}@${version} (${packed.size} bytes)`);
}

function packPlatform(work, archive, platform, expected) {
  const { target, os, cpu, libc, label } = platform;
  const extract = path.join(work, target);
  mkdirSync(extract);
  if (os === "win32") {
    execFileSync("unzip", ["-q", archive, "-d", extract]);
  } else {
    execFileSync("tar", ["-xf", archive, "-C", extract]);
  }
  const roots = readdirSync(extract);
  assert.equal(roots.length, 1, "SDK archive must contain one bundle directory");
  const root = path.join(extract, roots[0]);
  const manifestPath = path.join(root, "manifest.json");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  assert.equal(manifest.target.id, target);
  assert.equal(manifest.version, version);
  assert.equal(manifest.source.commit, commit);
  assert.equal(manifest.source.dirty, false);
  const { binary_abi_version: abiVersion, binary_abi_revision: abiRevision } = manifest.contract;
  assert(Number.isSafeInteger(abiVersion) && Number.isSafeInteger(abiRevision), "missing SDK ABI");
  verifyBundle(root, manifest, ["manifest.json"]);
  const addonFile = path.join(addons, target + ".node");
  const addonDigest = sha256(addonFile);
  assert.deepEqual(JSON.parse(readFileSync(addonFile + ".json")), {
    version, commit, target, revision: abiRevision, sha256: addonDigest,
  });
  mkdirSync(path.join(root, "node"));
  copyFileSync(addonFile, path.join(root, "node", "metacodes.node"));

  const topLevel = new Set(
    manifest.files.map(({ path }) => path.split("/")[0]).sort(),
  );
  topLevel.delete("README.md");
  pack(root, expected, {
    name: expected.name,
    version,
    description: `AgentCore SDK bundle for ${label}: C ABI library, header, Zig and Rust bindings`,
    os: [os],
    cpu: [cpu],
    ...(libc ? { libc: [libc] } : {}),
    files: ["manifest.json", "node", ...topLevel],
    preferUnplugged: true,
    ...repositoryMetadata,
    publishConfig,
  });

  const verify = path.join(work, `${target}.verify`);
  mkdirSync(verify);
  execFileSync("tar", ["-xf", path.join(out, expected.filename), "-C", verify]);
  const unpacked = path.join(verify, "package");
  verifyBundle(unpacked, manifest, ["manifest.json", "package.json", "LICENSE", "node/metacodes.node"]);
  assert.equal(sha256(path.join(unpacked, "node/metacodes.node")), addonDigest);
  assert.equal(sha256(path.join(unpacked, "manifest.json")), sha256(manifestPath));
  if (os !== "win32") {
    for (const file of manifest.files) {
      if (file.path.startsWith("bin/") && !file.path.includes("LICENSE")) {
        assert(statSync(path.join(unpacked, file.path)).mode & 0o100, `not executable: ${file.path}`);
      }
    }
  }
  return { version: abiVersion, revision: abiRevision };
}

function packMain(work) {
  const root = path.join(work, "main");
  mkdirSync(root);
  const byHost = Object.fromEntries(config.platforms.map(({ os, cpu, target }, index) => [
    `${os}-${cpu}`,
    { package: packages[index].name, target },
  ]));
  writeJson(path.join(root, "platforms.json"), byHost);
  for (const file of ["index.js", "index.d.ts", "location.js", "README.md"]) {
    copyFileSync(new URL(`./main/${file}`, import.meta.url), path.join(root, file));
  }
  for (const extension of ["js", "d.ts"]) {
    copyFileSync(new URL(`../../sdk/node/index.${extension}`, import.meta.url), path.join(root, `binding.${extension}`));
  }
  pack(root, mainTarball, {
    name: mainPackage,
    version,
    description:
      "AgentCore SDK: prebuilt bundles of the embeddable agent runtime (C ABI library, header, Zig and Rust bindings)",
    main: "index.js",
    types: "index.d.ts",
    exports: {
      ".": { types: "./index.d.ts", default: "./index.js" },
      "./package.json": "./package.json",
    },
    files: ["index.js", "index.d.ts", "location.js", "binding.js", "binding.d.ts", "platforms.json"],
    keywords: ["agent", "agent-runtime", "agentcore", "sdk", "c-abi", "zig"],
    ...repositoryMetadata,
    engines: { node: ">=18" },
    optionalDependencies,
    publishConfig,
  });
}

function checkInstallation(work, abiRevision) {
  const index = config.platforms.findIndex(
    ({ os, cpu }) => os === process.platform && cpu === process.arch,
  );
  assert(index >= 0, "build runner must have an AgentCore platform package");
  const hostPackage = packages[index];
  const hostTarget = config.platforms[index].target;
  const installation = path.join(work, "installation");
  mkdirSync(installation);
  const packageJson = path.join(installation, "package.json");
  writeFileSync(packageJson, '{"private":true}\n');
  execFileSync(
    "npm",
    [
      "install", "--offline", "--ignore-scripts", "--no-audit", "--no-fund",
      "--no-package-lock", "--include=optional",
      path.join(out, mainTarball.filename), path.join(out, hostPackage.filename),
    ],
    { cwd: installation, stdio: "inherit" },
  );
  const requireInstalled = createRequire(packageJson);
  const metadata = requireInstalled(`${mainPackage}/package.json`);
  assert.equal(metadata.name, mainPackage);
  assert.equal(metadata.version, version);
  assert.equal(metadata.repository.url, config.repository);
  assert.deepEqual(metadata.optionalDependencies, optionalDependencies);
  const bundle = requireInstalled(mainPackage).resolve();
  new (requireInstalled(mainPackage).Runtime)({ tools: [] }).close();
  assert.equal(bundle.package, hostPackage.name);
  assert.equal(bundle.target, hostTarget);
  assert.equal(bundle.version, version);
  assert.equal(bundle.abiRevision, abiRevision);
  assert(existsSync(bundle.sharedLibrary), "installed SDK shared library is missing");
  assert(existsSync(path.join(bundle.includeDir, "metask", "agentcore.h")), "SDK header is missing");
  console.log(`Verified npm installation and SDK resolution for ${hostTarget}`);
}

// Keep working files outside the artifact directory and never reuse old tarballs.
mkdirSync(out);
const work = mkdtempSync(path.join(tmpdir(), "agentcore-npm-"));
try {
  const abis = config.platforms.map((platform, index) =>
    packPlatform(work, path.resolve(archives, archiveNames[index]), platform, packages[index]),
  );
  for (const abi of abis) {
    assert.deepEqual(abi, abis[0], "all platform bundles must implement the same ABI");
  }
  packMain(work);
  checkInstallation(work, abis[0].revision);
  const release = {
    version,
    packages: packages.map((pkg) => ({
      ...pkg,
      integrity: tarballIntegrity(path.join(out, pkg.filename)),
    })),
  };
  writeJson(path.join(out, "release.json"), release);
} finally {
  rmSync(work, { recursive: true, force: true });
}
