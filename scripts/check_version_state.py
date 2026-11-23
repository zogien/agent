#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

import agentcore_contract as contract
import agentcore_release


ROOT = Path(__file__).resolve().parents[1]


def historical_baselines(root: Path) -> list[str]:
    last_release = subprocess.run(
        ["git", "-C", str(root), "describe", "--tags", "--abbrev=0",
         "--match", "fork/v*-fork.*", "--match", "[0-9]*.[0-9]*.[0-9]*"],
        capture_output=True, text=True, encoding="utf-8", check=False,
    ).stdout.strip()
    return ["HEAD", last_release] if last_release else ["HEAD"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sync", action="store_true", help="update the version mirrors from build.zig.zon")
    args = parser.parse_args()
    try:
        if args.sync:
            contract.set_sdk_version(ROOT, contract.sdk_version(ROOT))
        findings = agentcore_release.state_findings(ROOT, historical_baselines(ROOT))
    except ValueError as error:
        findings = [str(error)]
    if findings:
        for finding in findings:
            print(f"check_version_state: {finding}")
        return 1
    print("version state ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
