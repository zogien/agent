import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { setTimeout } from "node:timers/promises";
import {
  isNewerVersion,
  packageTarballs,
  tarballIntegrity,
  versionFromTag,
} from "./release-metadata.mjs";

export async function publishRelease(release, lookup, upload) {
  const pending = [];
  // Check every coordinate before writing anything. A registry error or a
  // collision in a later package must not leave an avoidable partial release.
  for (const pkg of release.packages) {
    const metadata = await lookup(pkg.name);
    const existing = metadata.versions[release.version];
    if (existing) {
      assert.equal(
        existing.dist.integrity,
        pkg.integrity,
        `${pkg.name}@${release.version} already exists with different bytes`,
      );
      console.log(`${pkg.name}@${release.version} already verified, skipping`);
      continue;
    }
    const latest = metadata["dist-tags"].latest;
    assert(
      !latest || !isNewerVersion(latest, release.version),
      `refusing to move ${pkg.name} latest from ${latest} to ${release.version}`,
    );
    pending.push(pkg);
  }

  for (const pkg of pending) await upload(pkg);
}

async function lookup(name) {
  const response = await fetch(`https://registry.npmjs.org/${encodeURIComponent(name)}`, {
    headers: { accept: "application/vnd.npm.install-v1+json", "cache-control": "no-cache" },
    signal: AbortSignal.timeout(10000),
  });
  assert(response.ok, `npm registry lookup for ${name} returned HTTP ${response.status}`);
  return response.json();
}

async function waitForVersion(pkg, version) {
  for (let attempt = 0; attempt < 8; attempt += 1) {
    if (attempt > 0) await setTimeout(2000);
    const metadata = await lookup(pkg.name);
    const existing = metadata.versions[version];
    if (!existing) continue;
    assert.equal(existing.dist.integrity, pkg.integrity, `registry digest for ${pkg.name}`);
    if (metadata["dist-tags"].latest === version) return;
  }
  throw new Error(`npm did not expose ${pkg.name}@${version} as latest after publish`);
}

if (import.meta.main) {
  const [directory, tag] = process.argv.slice(2);
  assert(directory && tag, "usage: node publish-release.mjs <package-dir> <fork-tag>");
  const version = versionFromTag(tag);
  const release = JSON.parse(readFileSync(path.join(directory, "release.json"), "utf8"));
  assert.equal(release.version, version);
  const expected = packageTarballs(version);
  assert.deepEqual(
    release.packages.map(({ name, filename }) => ({ name, filename })),
    expected,
    "npm artifact must list all platform packages followed by the main package",
  );
  const filenames = [...expected.map(({ filename }) => filename), "release.json"];
  assert.deepEqual(readdirSync(directory).sort(), filenames.sort(), "npm artifact file set");
  for (const pkg of release.packages) {
    assert.equal(tarballIntegrity(path.join(directory, pkg.filename)), pkg.integrity, pkg.filename);
  }

  await publishRelease(release, lookup, async (pkg) => {
    execFileSync(
      "npm",
      [
        "publish", path.resolve(directory, pkg.filename), "--ignore-scripts",
        "--access", "public", "--tag", "latest",
      ],
      { stdio: "inherit" },
    );
    await waitForVersion(pkg, release.version);
  });
}
