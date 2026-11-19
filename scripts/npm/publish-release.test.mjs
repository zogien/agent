import assert from "node:assert/strict";
import { test } from "node:test";
import { packageTarballs, versionFromTag } from "./release-metadata.mjs";
import { publishRelease } from "./publish-release.mjs";

const version = "0.15.0-fork.2";
const release = {
  version,
  packages: packageTarballs(version).map((pkg, index) => ({
    ...pkg,
    integrity: `tarball-${index}`,
  })),
};
const names = release.packages.map(({ name }) => name);
const previous = "0.15.0-fork.1";

function registry(latest = previous, versions = {}) {
  return { "dist-tags": { latest }, versions };
}

test("a retry skips verified platform packages and uploads the main package last", async () => {
  const completed = new Map();
  const lookup = async (name) => completed.get(name) ?? registry();
  const uploaded = [];
  const upload = async ({ name, integrity }) => {
    uploaded.push(name);
    completed.set(name, registry(version, { [version]: { dist: { integrity } } }));
  };
  await assert.rejects(
    publishRelease(release, lookup, async (pkg) => {
      if (pkg.name === names[2]) throw new Error("upload interrupted");
      await upload(pkg);
    }),
    /upload interrupted/,
  );
  assert.deepEqual(uploaded, names.slice(0, 2));

  await publishRelease(release, lookup, upload);
  assert.deepEqual(uploaded, names);
  await publishRelease(release, lookup, upload);
  assert.deepEqual(uploaded, names);
});

test("different bytes for an existing version stop all uploads", async () => {
  const lookup = async (name) =>
    name === names.at(-1)
      ? registry(version, { [version]: { dist: { integrity: "different" } } })
      : registry();
  await assert.rejects(
    publishRelease(release, lookup, () => assert.fail("unexpected upload")),
    /already exists with different bytes/,
  );
});

test("an older release cannot move latest backwards", async () => {
  await assert.rejects(
    publishRelease(
      release,
      async () => registry("0.15.0-fork.10"),
      () => assert.fail("unexpected upload"),
    ),
    /refusing to move .* latest from 0\.15\.0-fork\.10/,
  );
});

test("a failed registry read cannot be treated as a missing package", async () => {
  const lookup = async (name) => {
    if (name === names.at(-1)) throw new Error("HTTP 503");
    return registry();
  };
  await assert.rejects(
    publishRelease(release, lookup, () => assert.fail("unexpected upload")),
    /HTTP 503/,
  );
});

test("only canonical fork tags define npm release coordinates", () => {
  assert.equal(versionFromTag("fork/v0.15.0-fork.2"), version);
  assert.throws(() => versionFromTag("fork/v0.15.0-fork.02"));
  assert.throws(() => versionFromTag("v0.15.0"));
});
