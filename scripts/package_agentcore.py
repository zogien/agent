#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
import unittest
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from scripts import agentcore_contract, release_archive  # noqa: E402

# Kept as names for the callers and tests that imported them from here.
SAFE_COORDINATE = release_archive.SAFE_COORDINATE
ZIP_EPOCH = release_archive.ZIP_EPOCH
ZIP_COMPRESSION_LEVEL = release_archive.ZIP_COMPRESSION_LEVEL
sha256_file = release_archive.sha256_file
sanitized_tar_info = release_archive.sanitized_tar_info
write_zip_file = release_archive.write_zip_file


def load_bundle(bundle_root: Path) -> tuple[dict, str, str, tuple[str, ...]]:
    bundle = release_archive.load_bundle(bundle_root)
    return bundle.manifest, bundle.target_os, bundle.coordinate, bundle.archive_paths


def write_archive(bundle_root: Path, output_dir: Path) -> tuple[Path, Path]:
    bundle = release_archive.load_bundle(bundle_root.resolve())
    git_facts = release_archive.collect_git_facts(PROJECT_ROOT)
    if agentcore_contract.FORK_VERSION_RE.fullmatch(bundle.version):
        findings = agentcore_contract.correspondence_findings(bundle.manifest, PROJECT_ROOT)
        findings.extend(agentcore_contract.package_version_findings(PROJECT_ROOT))
        if findings:
            raise ValueError("; ".join(findings))
    return release_archive.write_archive(bundle_root, output_dir, git_facts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle_root", nargs="?", type=Path)
    parser.add_argument("output_dir", nargs="?", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(release_archive.ArchiveTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.bundle_root is None or args.output_dir is None:
        parser.error("bundle_root and output_dir are required")
    try:
        archive, checksum = write_archive(args.bundle_root.resolve(), args.output_dir.resolve())
    except (FileExistsError, OSError, ValueError) as error:
        print(f"AgentCore archive: {error}", file=sys.stderr)
        return 1
    print(archive)
    print(checksum)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
