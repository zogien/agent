import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

export const config = JSON.parse(
  readFileSync(new URL("./platforms.json", import.meta.url), "utf8"),
);
export const mainPackage = `${config.scope}/${config.name}`;
const number = "(0|[1-9][0-9]*)";
const forkVersion = new RegExp(
  `^${number}\\.${number}\\.${number}-fork\\.${number}$`,
);

function versionParts(version) {
  const match = forkVersion.exec(version);
  assert(match, `expected a fork version, got ${version}`);
  return match.slice(1).map(BigInt);
}

export function versionFromTag(tag) {
  assert(tag?.startsWith("fork/v"), `expected a fork/v release tag, got ${tag}`);
  const version = tag.slice("fork/v".length);
  versionParts(version);
  return version;
}

export function isNewerVersion(candidate, version) {
  const left = versionParts(candidate);
  const right = versionParts(version);
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return left[index] > right[index];
  }
  return false;
}

export function packageTarballs(version) {
  const names = config.platforms.map(({ suffix }) => `${mainPackage}-${suffix}`);
  return [...names, mainPackage].map((name) => ({
    name,
    filename: `${name.slice(1).replace("/", "-")}-${version}.tgz`,
  }));
}

export function tarballIntegrity(filename) {
  const hash = createHash("sha512").update(readFileSync(filename)).digest("base64");
  return `sha512-${hash}`;
}
