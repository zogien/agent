from __future__ import annotations

import subprocess
from pathlib import Path, PurePosixPath
from typing import Callable, Iterable, List, Optional, Tuple

import agentcore_contract as contract
import release_archive
from release_common import CutError


ROOT = Path(__file__).resolve().parents[1]


def ledger_at(root: Path, rev: str) -> Optional[contract.Ledger]:
    for path in (contract.LEDGER, "sdk/agentcore-releases.json"):
        proc = subprocess.run(
            ["git", "-C", str(root), "show", f"{rev}:{path}"],
            capture_output=True,
            check=False,
        )
        if proc.returncode == 0:
            return contract.parse_ledger(proc.stdout.decode("utf-8"))
    return None


def state_findings(root: Path, revisions: Iterable[str]) -> List[str]:
    ledger = contract.load_ledger(root)
    version = contract.sdk_version(root)
    contract.abi_revision(root)
    findings = contract.package_version_findings(root)
    if contract.BARE_RE.fullmatch(version):
        findings.append(f"{contract.SDK_VERSION}: use X.Y.Z-dev or X.Y.Z-fork.N")
    facts = release_archive.collect_git_facts(root)
    tags = facts.fork_tags
    if tags and tags != (f"fork/v{version}",):
        findings.append(f"{contract.SDK_VERSION} declares {version}, but HEAD has fork tags {', '.join(tags)}")
    if tags and facts.dirty:
        findings.append("AgentCore fork release tags require a clean checkout")
    for rev in revisions:
        older = ledger_at(root, rev)
        if older is not None:
            rewritten = contract.is_prefix_of(older, ledger)
            if rewritten:
                findings.append(f"{rewritten} (since {rev}); released entries are immutable")
    return findings


def probe_library_abi(library: Path) -> Tuple[int, int]:
    """(abi_version, abi_revision) a shared library itself reports."""
    import ctypes

    handle = ctypes.CDLL(str(library))
    entry = handle.metask_agentcore_get_api
    entry.restype = ctypes.c_void_p
    entry.argtypes = [ctypes.c_uint32]
    api = entry(1)
    if not api:
        raise CutError(f"{library.name} refused ABI v1")
    words = (ctypes.c_uint32 * 3).from_address(api)
    return int(words[1]), int(words[2])


def host_runs(target: dict) -> bool:
    """Whether this interpreter can load a library built for `target`."""
    import platform

    machine = {"amd64": "x86_64", "arm64": "aarch64"}.get(platform.machine().lower(), platform.machine().lower())
    system = {"darwin": "macos"}.get(platform.system().lower(), platform.system().lower())
    return target.get("architecture") == machine and target.get("os") == system


def verify_package_inputs(
    bundle_root: Path,
    root: Path = ROOT,
    formal: bool = False,
    probe: Callable[[Path], Tuple[int, int]] = probe_library_abi,
    head: Optional[str] = None,
) -> dict:
    bundle = release_archive.load_bundle(bundle_root)
    manifest = bundle.manifest
    contract.check_bundle_contents(manifest, lambda rel: bundle_root.joinpath(*PurePosixPath(rel).parts).read_bytes())
    facts = release_archive.collect_git_facts(root)
    fork_release = contract.FORK_VERSION_RE.fullmatch(bundle.version) is not None
    if formal and not fork_release:
        raise CutError(f"{bundle.version} is not a tagged AgentCore fork release")
    if fork_release:
        release_archive.enforce_channel(bundle, facts)
    findings = contract.correspondence_findings(manifest, root)
    findings.extend(contract.package_version_findings(root))
    current = head if head is not None else facts.head_commit
    if current is None or manifest["source"]["commit"] != current:
        findings.append(f"the bundle was built from {manifest['source']['commit']}, but this checkout is {current}")
    if findings:
        raise CutError("; ".join(findings))
    library = bundle_root.joinpath(*PurePosixPath(manifest["shared_library"]["path"]).parts)
    if host_runs(manifest["target"]) or probe is not probe_library_abi:
        version, revision = probe(library)
        expected = (manifest["contract"]["binary_abi_version"], manifest["contract"]["binary_abi_revision"])
        if (version, revision) != expected:
            raise CutError(f"{library.name} reports ABI v{version} revision {revision}, but its manifest says v{expected[0]} revision {expected[1]}")
    return manifest
