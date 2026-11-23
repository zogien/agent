from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

sys.path.insert(0, str(Path(__file__).resolve().parent))
import agentcore_contract  # noqa: E402

SAFE_COORDINATE = re.compile(r"^[0-9A-Za-z._+-]+$")
ZIP_EPOCH = (1980, 1, 1, 0, 0, 0)
ZIP_COMPRESSION_LEVEL = 9


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitized_tar_info(info: tarfile.TarInfo) -> tarfile.TarInfo:
    """Remove build-host identity and timestamps from a tar member."""
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.pax_headers = {}
    return info


def write_zip_file(archive: zipfile.ZipFile, source: Path, archive_name: str) -> None:
    """Write a regular file without copying its host timestamp into the zip."""
    info = zipfile.ZipInfo(archive_name, date_time=ZIP_EPOCH)
    archive.writestr(
        info,
        source.read_bytes(),
        compress_type=zipfile.ZIP_DEFLATED,
        compresslevel=ZIP_COMPRESSION_LEVEL,
    )


@dataclass(frozen=True)
class GitFacts:
    head_commit: str | None = None
    fork_tags: tuple[str, ...] = ()
    dirty: bool = False


def collect_git_facts(repo_root: Path) -> GitFacts:
    def git(*argv: str) -> str:
        completed = subprocess.run(
            ["git", "-C", str(repo_root), *argv],
            capture_output=True,
            encoding="utf-8",
            check=False,
        )
        if completed.returncode != 0:
            raise ValueError(f"cannot read archive source identity: {completed.stderr.strip()}")
        return completed.stdout.strip()

    return GitFacts(
        head_commit=git("rev-parse", "HEAD"),
        fork_tags=tuple(git("tag", "--list", "--points-at", "HEAD", "fork/v*-fork.*").splitlines()),
        dirty=bool(git("status", "--porcelain=v1", "--untracked-files=normal", "--", ".")),
    )


@dataclass(frozen=True)
class Bundle:
    manifest: dict
    version: str
    target_os: str
    coordinate: str
    archive_paths: tuple[str, ...]


def load_bundle(bundle_root: Path) -> Bundle:
    if not bundle_root.is_dir():
        raise ValueError(f"bundle root is not a directory: {bundle_root}")
    manifest_path = bundle_root / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError("manifest.json is not a regular file")
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        schema_version = manifest["schema_version"]
        vendor = manifest["vendor"]
        name = manifest["name"]
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid AgentCore manifest: {error}") from error
    # Identity before shape: a manifest of the other unit is refused by name,
    # not by whichever field it happens to lack.
    if schema_version != 1 or vendor != "metask" or name != "agentcore":
        raise ValueError("manifest is not metask AgentCore schema 1")
    try:
        target_id = manifest["target"]["id"]
        target_os = manifest["target"]["os"]
        files = manifest["files"]
        version = manifest["version"]
    except (KeyError, TypeError) as error:
        raise ValueError(f"invalid AgentCore manifest: {error}") from error

    for field_name, value in (("version", version), ("target.id", target_id)):
        if not isinstance(value, str) or not SAFE_COORDINATE.fullmatch(value):
            raise ValueError(f"manifest {field_name} is not archive-name safe")
    if target_os not in ("windows", "linux", "macos"):
        raise ValueError(f"unsupported archive OS: {target_os}")
    if not isinstance(files, list):
        raise ValueError("manifest files must be an array")

    expected_paths = {"manifest.json"}
    for entry in files:
        try:
            relative_text = entry["path"]
            expected_hash = entry["sha256"]
        except (KeyError, TypeError) as error:
            raise ValueError("invalid manifest file entry") from error
        if not isinstance(relative_text, str) or not isinstance(expected_hash, str):
            raise ValueError("invalid manifest file entry")
        relative = PurePosixPath(relative_text)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or "\\" in relative_text
            or ":" in relative_text
            or relative_text != relative.as_posix()
        ):
            raise ValueError(f"unsafe manifest path: {relative_text}")
        payload = bundle_root
        for part in relative.parts:
            payload /= part
            if payload.is_symlink():
                raise ValueError(f"manifest payload traverses a symlink: {relative_text}")
        if not payload.is_file():
            raise ValueError(f"manifest payload is not a regular file: {relative_text}")
        if sha256_file(payload) != expected_hash:
            raise ValueError(f"manifest SHA-256 mismatch: {relative_text}")
        if relative_text in expected_paths:
            raise ValueError(f"duplicate manifest path: {relative_text}")
        expected_paths.add(relative_text)

    return Bundle(
        manifest=manifest,
        version=version,
        target_os=target_os,
        coordinate=f"metask-agentcore-{version}-{target_id}",
        archive_paths=tuple(sorted(expected_paths)),
    )


def enforce_channel(bundle: Bundle, git_facts: GitFacts | None) -> None:
    source = bundle.manifest["source"]
    tags = () if git_facts is None else git_facts.fork_tags
    if agentcore_contract.FORK_VERSION_RE.fullmatch(bundle.version):
        tag = f"fork/v{bundle.version}"
        if tags != (tag,):
            raise ValueError(f"AgentCore {bundle.version} requires tag {tag} at HEAD")
        if source.get("dirty") is not False or git_facts.dirty or source.get("commit") != git_facts.head_commit:
            raise ValueError(f"AgentCore {tag} requires a clean bundle built from the tagged commit")
    elif tags:
        raise ValueError(f"AgentCore development version {bundle.version} on fork release tag {tags[0]}")
    elif not agentcore_contract.BUILT_DEV_RE.fullmatch(bundle.version):
        raise ValueError(f"AgentCore {bundle.version} requires a fork release version")


def write_archive(bundle_root: Path, output_dir: Path, git_facts: GitFacts | None) -> tuple[Path, Path]:
    bundle_root = bundle_root.resolve()
    output_dir = output_dir.resolve()
    if output_dir == bundle_root or bundle_root in output_dir.parents:
        raise ValueError("archive output directory must not be inside the bundle root")
    bundle = load_bundle(bundle_root)
    agentcore_contract.check_bundle_contents(
        bundle.manifest,
        lambda relative: bundle_root.joinpath(*PurePosixPath(relative).parts).read_bytes(),
    )
    enforce_channel(bundle, git_facts)
    members = [(bundle_root.joinpath(*PurePosixPath(relative).parts), relative) for relative in bundle.archive_paths]
    return write_immutable(output_dir, bundle.coordinate, members, as_zip=bundle.target_os == "windows")


def write_immutable(output_dir: Path, coordinate: str, members: list[tuple[Path, str]], as_zip: bool) -> tuple[Path, Path]:
    """`<coordinate>.zip|.tar.gz` holding each (file, path) under
    `<coordinate>/`, plus its `.sha256` sidecar; never replaced once written."""
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{coordinate}{'.zip' if as_zip else '.tar.gz'}"
    checksum_path = output_dir / f"{archive_path.name}.sha256"

    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{coordinate}.", suffix=".tmp", dir=output_dir)
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        if as_zip:
            with zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED, compresslevel=ZIP_COMPRESSION_LEVEL) as archive:
                for path, relative in members:
                    write_zip_file(archive, path, f"{coordinate}/{relative}")
        else:
            # A gzip header carries a file name and an mtime; `tarfile`'s "w:gz"
            # would write the temporary's name and the current time, and two
            # runs would differ. Fixed empty name, epoch mtime.
            with temporary.open("wb") as raw, gzip.GzipFile(
                filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=ZIP_COMPRESSION_LEVEL
            ) as compressed, tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as archive:
                for path, relative in members:
                    archive.add(path, arcname=f"{coordinate}/{relative}", recursive=False, filter=sanitized_tar_info)

        digest = sha256_file(temporary)
        if archive_path.exists() or checksum_path.exists():
            # Immutable, not merely write-once: the build graph re-runs this
            # step, so an existing archive is
            # accepted when it is byte-identical to what would be written now
            # — a reproducibility check for free — and never replaced.
            expected_sidecar = f"{digest}  {archive_path.name}\n"
            if (
                archive_path.is_file()
                and checksum_path.is_file()
                and sha256_file(archive_path) == digest
                and checksum_path.read_text(encoding="ascii") == expected_sidecar
            ):
                return archive_path, checksum_path
            raise FileExistsError(f"archive coordinate already exists with different bytes: {coordinate}")
        archive_created = False
        checksum_created = False
        try:
            with archive_path.open("xb") as destination, temporary.open("rb") as source:
                archive_created = True
                shutil.copyfileobj(source, destination, 1024 * 1024)
            with checksum_path.open("x", encoding="ascii", newline="\n") as checksum:
                checksum_created = True
                checksum.write(f"{digest}  {archive_path.name}\n")
        except BaseException:
            if archive_created:
                archive_path.unlink(missing_ok=True)
            if checksum_created:
                checksum_path.unlink(missing_ok=True)
            raise
    finally:
        temporary.unlink(missing_ok=True)
    return archive_path, checksum_path


COMMIT = "0123456789abcdef0123456789abcdef01234567"


def _sdk_fixture(root: Path, target_os: str, target_id: str, version: str = "0.1.0-dev+0123456789ab", revision: int = 26,
                 commit: str = COMMIT, overrides: dict[str, str] | None = None, architecture: str = "x86_64", abi: str = "gnu") -> Path:
    """A bundle whose every member describes one release; `overrides` replaces a
    member's text afterwards, with the manifest digest following it, so a test
    states exactly which file disagrees."""
    bundle = root / "sdk-bundle"
    library = "metask_agentcore.dll" if target_os == "windows" else "libmetask_agentcore.so"
    members = {
        "include/metask/agentcore.h": f"#define METASK_AGENTCORE_ABI_REVISION {revision}u\n",
        "bindings/zig/src/types.zig": f"pub const ABI_REVISION: u32 = {revision};\n",
        "bindings/rust/src/raw.rs": f"pub const METASK_AGENTCORE_ABI_REVISION: u32 = {revision};\n",
        "bindings/zig/build.zig.zon": f'.{{\n    .version = "{version}",\n}}\n',
        "bindings/rust/Cargo.toml": f'[package]\nversion = "{version}"\n',
        "bindings/rust/Cargo.lock": f'version = 4\n\n[[package]]\nversion = "{version}"\n',
        "README.md": f"# metask-agentcore {version}\n\nRevision {revision} exposes the tables.\n",
        f"lib/{library}": f"library {version} {target_id}\n",
    }
    members.update(overrides or {})
    files = []
    for relative, text in members.items():
        payload = bundle.joinpath(*PurePosixPath(relative).parts)
        payload.parent.mkdir(parents=True, exist_ok=True)
        payload.write_bytes(text.encode("utf-8"))
        files.append({"path": relative, "sha256": sha256_file(payload)})
    manifest = {
        "schema_version": 1,
        "vendor": "metask",
        "name": "agentcore",
        "version": version,
        "source": {"commit": commit, "dirty": False},
        "target": {"id": target_id, "os": target_os, "architecture": architecture, "abi": abi, "zig_target": target_id},
        "contract": {"binary_abi_version": 1, "binary_abi_revision": revision},
        "shared_library": {"path": f"lib/{library}"},
        "files": files,
    }
    (bundle / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return bundle


class ArchiveTests(unittest.TestCase):
    def test_sdk_windows_zip_has_coordinate_root_and_refuses_overwrite(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "windows", "x86_64-windows-msvc")
            stale = bundle / "sdk" / "old-agentcore.zig"
            stale.parent.mkdir()
            stale.write_text("// ignored local residue\n", encoding="utf-8")
            archive, checksum = write_archive(bundle, root / "out", None)
            self.assertEqual(archive.suffix, ".zip")
            with zipfile.ZipFile(archive) as opened:
                self.assertIn("metask-agentcore-0.1.0-dev+0123456789ab-x86_64-windows-msvc/manifest.json", opened.namelist())
                self.assertTrue(all(info.date_time == ZIP_EPOCH for info in opened.infolist()))
                self.assertFalse(any(name.endswith("sdk/old-agentcore.zig") for name in opened.namelist()))
            self.assertTrue(checksum.read_text(encoding="ascii").startswith(sha256_file(archive)))
            # Re-running over the unchanged bundle is a no-op that proves the
            # bytes reproduce; a changed bundle may not replace the archive.
            self.assertEqual(write_archive(bundle, root / "out", None), (archive, checksum))
            payload = bundle / "lib" / "metask_agentcore.dll"
            payload.write_text("/* changed */\n", encoding="utf-8")
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            next(entry for entry in manifest["files"] if entry["path"] == "lib/metask_agentcore.dll")["sha256"] = sha256_file(payload)
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(FileExistsError, "different bytes"):
                write_archive(bundle, root / "out", None)

    def test_sdk_tar_gz_is_reproducible_and_named_after_the_release(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            first, _ = write_archive(bundle, root / "one", None)
            second, _ = write_archive(bundle, root / "two", None)
            self.assertEqual(first.name, "metask-agentcore-0.1.0-dev+0123456789ab-x86_64-linux-gnu.tar.gz")
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with tarfile.open(first, "r:gz") as opened:
                self.assertIn("metask-agentcore-0.1.0-dev+0123456789ab-x86_64-linux-gnu/manifest.json", opened.getnames())
                for member in opened.getmembers():
                    self.assertEqual((member.uid, member.gid, member.uname, member.gname, member.mtime), (0, 0, "", "", 0))

    def test_a_development_sdk_refuses_a_release_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            with self.assertRaisesRegex(ValueError, "development version"):
                write_archive(bundle, root / "out", GitFacts(fork_tags=("fork/v0.1.0-fork.1",)))
            write_archive(bundle, root / "out", GitFacts())

    def test_a_fork_sdk_archives_under_its_own_tag(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            version = "0.15.1-fork.1"
            tag = f"fork/v{version}"
            bundle = _sdk_fixture(root, "windows", "x86_64-windows-gnu", version=version)
            with self.assertRaisesRegex(ValueError, f"requires tag {re.escape(tag)} at HEAD"):
                write_archive(bundle, root / "out", GitFacts(COMMIT, (f"fork/{version}",)))
            with self.assertRaisesRegex(ValueError, "built from the tagged commit"):
                write_archive(bundle, root / "out", GitFacts("f" * 40, (tag,)))
            with self.assertRaisesRegex(ValueError, "clean bundle"):
                write_archive(bundle, root / "out", GitFacts(COMMIT, (tag,), dirty=True))
            archive, sidecar = write_archive(bundle, root / "out", GitFacts(COMMIT, (tag,)))
            self.assertEqual(archive.name, f"metask-agentcore-{version}-x86_64-windows-gnu.zip")
            self.assertEqual(sidecar.name, f"{archive.name}.sha256")

    def test_rejects_payload_hash_mismatch_and_wrong_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bundle = _sdk_fixture(root, "linux", "x86_64-linux-gnu")
            (bundle / "include" / "metask" / "agentcore.h").write_text("changed", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                write_archive(bundle, root / "out", None)
            manifest_path = bundle / "manifest.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["name"] = "metacodes-cli"
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "not metask AgentCore"):
                write_archive(bundle, root / "out", None)
            with self.assertRaisesRegex(ValueError, "must not be inside"):
                write_archive(bundle, bundle / "archives", None)
