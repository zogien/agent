from __future__ import annotations

import re
from pathlib import Path
from typing import Tuple


ZON = "build.zig.zon"

VERSION_ZIG = "src/version.zig"

ZON_VERSION_RE = re.compile(r'(\.version\s*=\s*")([^"]+)(")')

ZIG_VERSION_RE = re.compile(r'(pub const semver = ")([^"]+)(";)')

class CutError(ValueError):
    """A refusal with a message for the maintainer; nothing was written."""

def fmt(version: Tuple[int, int, int]) -> str:
    return "%d.%d.%d" % version

def set_version_text(text: str, pattern: re.Pattern, version: str, label: str) -> str:
    new, count = pattern.subn(lambda m: m.group(1) + version + m.group(3), text)
    if count != 1:
        raise CutError(f"{label}: expected exactly one version declaration, found {count}")
    return new

def read(root: Path, rel: str) -> str:
    return (root / rel).read_text(encoding="utf-8")

def write(root: Path, rel: str, text: str) -> None:
    with open(root / rel, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
