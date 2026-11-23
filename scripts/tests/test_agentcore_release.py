from __future__ import annotations

import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import agentcore_contract as contract  # noqa: E402
import agentcore_release as release  # noqa: E402
import release_archive  # noqa: E402
import release_common as common  # noqa: E402

spec = importlib.util.spec_from_file_location("build_wheel", ROOT / "sdk/python/build_wheel.py")
build_wheel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build_wheel)

DIGEST = "a" * 64
TARGET = "riscv64-linux-gnu"
TAG = "manylinux_2_28_riscv64"


def git(cwd: Path, *argv: str) -> str:
    return subprocess.run(["git", *argv], cwd=str(cwd), capture_output=True, text=True, check=True).stdout.strip()


def write_tree(root: Path, version: str = "0.13.0-dev", revision: int = 26) -> None:
    files = {
        contract.PY_PROJECT: f'[project]\nname = "metacodes"\nversion = "{contract.python_version(version)}"\n',
        contract.PY_INIT: f'__version__ = "{contract.python_version(version)}"\n',
        contract.NODE_PACKAGE: json.dumps({"name": "metacodes", "version": contract.node_version(version)}, indent=2) + "\n",
        contract.LEDGER: contract.dump_ledger(contract.Ledger()),
        contract.ABI_AUTHORITY: f"pub const ABI_VERSION_V1: u32 = 1;\npub const ABI_REVISION: u32 = {revision};\n",
        "sdk/metask/agentcore.h": f"#define METASK_AGENTCORE_ABI_REVISION {revision}u\n",
        "sdk/rust/src/raw.rs": f"pub const METASK_AGENTCORE_ABI_REVISION: u32 = {revision};\n",
        "sdk/python/src/metacodes/_native.py": f"ABI_REVISION = {revision}\n",
        "sdk/python/README.md": "# metacodes\n",
        "sdk/node/index.js": f"const ABI_REVISION = {revision};\n",
        "LICENSE": "MIT\n",
        common.VERSION_ZIG: f'pub const semver = "{version}";\n',
        common.ZON: f'.{{\n    .version = "{version}",\n}}\n',
    }
    for rel, text in files.items():
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))


class Tree(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name) / "repo"
        self.root.mkdir()
        write_tree(self.root)
        git(self.root, "init", "-q", "-b", "main")
        git(self.root, "config", "user.email", "test@metacodes.local")
        git(self.root, "config", "user.name", "metacodes-test")
        git(self.root, "config", "commit.gpgsign", "false")
        git(self.root, "config", "tag.gpgsign", "false")
        self.commit("chore: init")
        self.addCleanup(self._tmp.cleanup)

    def commit(self, message: str) -> str:
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", message)
        return git(self.root, "rev-parse", "HEAD")


class VersionMappingTest(unittest.TestCase):
    def test_a_release_is_itself_in_every_ecosystem(self) -> None:
        self.assertEqual(contract.python_version("0.13.0"), "0.13.0")
        self.assertEqual(contract.node_version("0.13.0"), "0.13.0")
        self.assertEqual(contract.python_version("0.13.0-dev"), "0.13.0.dev0")
        self.assertEqual(contract.node_version("0.13.0-dev"), "0.13.0-dev.0")

    def test_other_shapes_are_not_agentcore_versions(self) -> None:
        for bad in ("0.13", "0.13.0-rc.1", "0.13.0+abc", "v0.13.0", "00.1.0"):
            with self.subTest(bad), self.assertRaises(common.CutError):
                contract.parse(bad)
        for bad in ("0.13.0-rc.1", "0.13.0-dev", "0.13.0+0123456789ab", "0.13.0-dev+short"):
            with self.subTest(bad), self.assertRaises(common.CutError):
                contract.base_of_built(bad)
        self.assertEqual(contract.base_of_built("0.13.0"), ("0.13.0", False))
        self.assertEqual(contract.base_of_built("0.13.0-dev+0123456789ab.dirty"), ("0.13.0", True))


class LedgerTest(unittest.TestCase):
    def entry(self, version="0.13.0", revision=26, digest=DIGEST, mains=("0.10.0",)) -> contract.Release:
        return contract.Release(version, 1, revision, digest, mains)

    def test_a_round_trip(self) -> None:
        ledger = contract.Ledger((self.entry(), self.entry("0.14.0", 27, "b" * 64, ("0.11.0", "0.11.1"))))
        self.assertEqual(contract.parse_ledger(contract.dump_ledger(ledger)), ledger)
        self.assertEqual(ledger.by_main_release("0.11.1").version, "0.14.0")
        self.assertEqual(ledger.by_version("0.14.0").built_by, "0.11.0")

    def test_the_real_ledger_is_valid(self) -> None:
        contract.load_ledger(ROOT)

    def test_refusals(self) -> None:
        cases = (
            ((self.entry("0.13.0-dev"),), "not a final"),
            ((self.entry("0.13.0+abc"),), "not a final"),
            ((self.entry(digest="short"),), "input digest"),
            ((self.entry(revision=0),), "ABI version and revision"),
            ((self.entry(mains=()),), "names no main-project"),
            ((self.entry(mains=("0.10.0-dev",)),), "not a final"),
            ((self.entry(), self.entry("0.13.0", digest="b" * 64, mains=("0.11.0",))), "does not follow"),
            ((self.entry(), self.entry("0.13.1", digest=DIGEST, mains=("0.11.0",))), "unchanged AgentCore keeps its version"),
            ((self.entry(), self.entry("0.13.1", digest="b" * 64, mains=("0.10.0",))), "out of order"),
            ((self.entry(revision=27), self.entry("0.14.0", 26, "b" * 64, ("0.11.0",))), "lowers the ABI revision"),
            ((self.entry(), self.entry("0.13.1", 27, "b" * 64, ("0.11.0",))), "needs at least a minor"),
        )
        for releases, message in cases:
            with self.subTest(message), self.assertRaisesRegex(common.CutError, message):
                contract.validated(contract.Ledger(releases))

    def test_a_malformed_file_is_refused(self) -> None:
        for text in ("not json", "[]", '{"schema": "other", "releases": []}', json.dumps({"schema": contract.LEDGER_SCHEMA, "releases": [{"version": "0.13.0"}]})):
            with self.subTest(text), self.assertRaises(common.CutError):
                contract.parse_ledger(text)

    def test_released_entries_only_grow(self) -> None:
        older = contract.Ledger((self.entry(),))
        self.assertIsNone(contract.is_prefix_of(older, older))
        self.assertIsNone(contract.is_prefix_of(older, older.carrying(older.latest, "0.10.1")))
        self.assertIsNone(contract.is_prefix_of(older, older.appended(self.entry("0.14.0", 26, "b" * 64, ("0.11.0",)))))
        self.assertIn("dropped", contract.is_prefix_of(older, contract.Ledger()))
        self.assertIn("changed", contract.is_prefix_of(older, contract.Ledger((self.entry(revision=27),))))
        self.assertIn("changed", contract.is_prefix_of(older, contract.Ledger((self.entry(mains=("0.10.1",)),))))


class StateTest(Tree):
    def test_a_declared_version_synchronizes_all_consumers(self):
        contract.set_sdk_version(self.root, "0.16.1-fork.2")
        self.assertEqual(contract.sdk_version(self.root), "0.16.1-fork.2")
        self.assertEqual(contract.package_version_findings(self.root), [])
        self.assertIn('semver = "0.16.1-fork.2"', (self.root / common.VERSION_ZIG).read_text())
        self.assertEqual(json.loads((self.root / contract.NODE_PACKAGE).read_text())["version"], "0.16.1-fork.2")
        self.assertIn('version = "0.16.1+fork.2"', (self.root / contract.PY_PROJECT).read_text())
        self.assertEqual(release.state_findings(self.root, ["HEAD"]), [])

    def test_a_fork_tag_must_match_the_declaration(self):
        git(self.root, "tag", "fork/v0.16.1-fork.2")
        self.assertIn("HEAD has fork tags", "\\n".join(release.state_findings(self.root, ["HEAD"])))

    def test_migrating_the_ledger_retains_history_validation(self):
        entry = contract.Release("0.13.0", 1, 26, DIGEST, ("0.10.0",))
        ledger = contract.Ledger((entry,))
        old = self.root / "sdk/agentcore-releases.json"
        old.write_text(contract.dump_ledger(ledger), encoding="utf-8")
        current = self.root / contract.LEDGER
        current.unlink()
        original = self.commit("upstream release before layout migration")
        old.rename(current)
        self.commit("move release ledger")
        self.assertEqual(release.ledger_at(self.root, original), ledger)
        self.assertEqual(release.ledger_at(self.root, "HEAD"), ledger)
        self.assertEqual(release.state_findings(self.root, [original]), [])
        current.write_text(contract.dump_ledger(contract.Ledger()), encoding="utf-8")
        self.assertIn("dropped a release", "\\n".join(release.state_findings(self.root, [original])))


class BundleContentsTest(unittest.TestCase):
    def bundle(self, **fixture) -> tuple:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        path = release_archive._sdk_fixture(Path(tmp.name), "linux", TARGET, **fixture)
        return path, json.loads((path / "manifest.json").read_text(encoding="utf-8"))

    def check(self, **fixture) -> None:
        path, manifest = self.bundle(**fixture)
        contract.check_bundle_contents(manifest, lambda rel: (path / rel).read_bytes())

    def test_a_consistent_bundle_passes(self) -> None:
        self.check()
        self.check(version="0.13.0")

    def test_each_member_that_disagrees_is_refused(self) -> None:
        cases = (
            ("include/metask/agentcore.h", "#define METASK_AGENTCORE_ABI_REVISION 25u\n", "ABI revision mismatch"),
            ("bindings/zig/src/types.zig", "pub const ABI_REVISION: u32 = 25;\n", "ABI revision mismatch"),
            ("bindings/rust/src/raw.rs", "pub const METASK_AGENTCORE_ABI_REVISION: u32 = 25;\n", "ABI revision mismatch"),
            ("bindings/zig/build.zig.zon", '.{\n    .version = "9.9.9",\n}\n', "version mismatch"),
            ("bindings/rust/Cargo.toml", '[package]\nversion = "9.9.9"\n', "version mismatch"),
            ("bindings/rust/Cargo.lock", 'version = "9.9.9"\n', "version mismatch"),
            ("README.md", "# metask-agentcore 9.9.9\n\nRevision 26 x.\n", "does not name version"),
            # The stale delivery document the issue names.
            ("README.md", "# metask-agentcore 0.1.0-dev+0123456789ab\n\nRevision 18 exposes one 64-byte root.\n", "describes ABI revision"),
            ("README.md", "# metask-agentcore 0.1.0-dev+0123456789ab\n\nNo revision stated.\n", "describes ABI revision"),
        )
        for rel, text, message in cases:
            with self.subTest(rel=rel, message=message), self.assertRaisesRegex(common.CutError, message):
                self.check(overrides={rel: text})

    def test_crlf_members_from_a_windows_checkout_pass(self) -> None:
        self.check(overrides={"include/metask/agentcore.h": "// header\r\n#define METASK_AGENTCORE_ABI_REVISION 26u\r\n"})

    def test_a_bad_version_shape_is_refused(self) -> None:
        with self.assertRaisesRegex(common.CutError, "invalid AgentCore bundle version"):
            self.check(version="0.13.0-rc.1")

    def test_a_development_version_must_name_its_commit(self) -> None:
        with self.assertRaisesRegex(common.CutError, "does not name its source commit"):
            self.check(commit="f" * 40)

    def test_an_unpinned_library_is_refused(self) -> None:
        path, manifest = self.bundle()
        manifest["files"] = [f for f in manifest["files"] if not f["path"].startswith("lib/")]
        with self.assertRaisesRegex(common.CutError, "not pinned"):
            contract.check_bundle_contents(manifest, lambda rel: (path / rel).read_bytes())

    def test_the_archive_refuses_an_inconsistent_bundle(self) -> None:
        path, _ = self.bundle(overrides={"bindings/zig/src/types.zig": "pub const ABI_REVISION: u32 = 25;\n"})
        with tempfile.TemporaryDirectory() as out, self.assertRaisesRegex(ValueError, "ABI revision mismatch"):
            release_archive.write_archive(path, Path(out), None)


class PackageInputsTest(Tree):
    """The issue's case: the wheel's version comes from the checkout and its
    library from a supplied bundle."""

    def setUp(self) -> None:
        super().setUp()
        self.out = Path(self._tmp.name) / "out"
        self.head = git(self.root, "rev-parse", "HEAD")
        self.bundles = Path(self._tmp.name) / "bundles"

    def dev_bundle(self, base: str = "0.13.0", commit: str = "", revision: int = 26, **fixture) -> Path:
        commit = commit or self.head
        self.bundles.mkdir(exist_ok=True)
        where = Path(tempfile.mkdtemp(dir=self.bundles))
        return release_archive._sdk_fixture(where, "linux", TARGET, version=f"{base}-dev+{commit[:12]}", commit=commit, revision=revision, architecture="riscv64", **fixture)

    def stable_bundle(self, version: str = "0.13.0", revision: int = 26) -> Path:
        self.bundles.mkdir(exist_ok=True)
        where = Path(tempfile.mkdtemp(dir=self.bundles))
        return release_archive._sdk_fixture(where, "linux", TARGET, version=version, commit=self.head, revision=revision, architecture="riscv64")

    def build(self, bundle: Path, formal: bool = False) -> Path:
        return build_wheel.build(bundle, self.out, "", formal=formal, root=self.root)

    def test_a_matching_bundle_builds_and_the_wheel_carries_its_version(self) -> None:
        wheel = self.build(self.dev_bundle())
        self.assertEqual(wheel.name, f"metacodes-0.13.0.dev0-py3-none-{TAG}.whl")
        with zipfile.ZipFile(wheel) as archive:
            self.assertIn("\nVersion: 0.13.0.dev0\n", archive.read("metacodes-0.13.0.dev0.dist-info/METADATA").decode("utf-8"))

    def test_a_bundle_of_another_version_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "the bundle is AgentCore 0.12.0"):
            self.build(self.dev_bundle("0.12.0"))

    def test_a_release_bundle_in_a_development_checkout_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "this checkout is 0.13.0-dev"):
            self.build(self.stable_bundle())

    def test_a_bundle_of_another_abi_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "implements ABI revision 25"):
            self.build(self.dev_bundle(revision=25))

    def test_a_bundle_of_another_commit_is_refused(self) -> None:
        with self.assertRaisesRegex(SystemExit, "was built from"):
            self.build(self.dev_bundle(commit="f" * 40))

    def test_a_tampered_library_is_refused(self) -> None:
        bundle = self.dev_bundle()
        (bundle / "lib" / "libmetask_agentcore.so").write_bytes(b"another library")
        with self.assertRaisesRegex(SystemExit, "SHA-256 mismatch"):
            self.build(bundle)

    def test_a_formal_package_refuses_a_development_bundle(self) -> None:
        with self.assertRaisesRegex(SystemExit, "not a tagged AgentCore fork release"):
            self.build(self.dev_bundle(), formal=True)

    def test_a_fork_wheel_requires_the_clean_tagged_checkout(self) -> None:
        version = "0.13.0-fork.2"
        contract.set_sdk_version(self.root, version)
        self.head = self.commit("prepare AgentCore version")
        bundle = self.stable_bundle(version)
        with self.assertRaisesRegex(SystemExit, "requires tag"):
            self.build(bundle, formal=True)
        git(self.root, "tag", f"fork/v{version}")
        result = self.build(bundle, formal=True)
        self.assertEqual(result.name, f"metacodes-0.13.0+fork.2-py3-none-{TAG}.whl")
        (self.root / "LICENSE").write_text("changed", encoding="utf-8")
        with self.assertRaisesRegex(SystemExit, "clean bundle"):
            self.build(bundle, formal=True)

    def test_the_library_itself_must_report_the_revision(self) -> None:
        bundle = self.dev_bundle()
        with self.assertRaisesRegex(common.CutError, "reports ABI v1 revision 25"):
            release.verify_package_inputs(bundle, self.root, probe=lambda _: (1, 25))
        release.verify_package_inputs(bundle, self.root, probe=lambda _: (1, 26))

    def test_a_host_that_can_run_the_target_must_load_it(self) -> None:
        bundle = self.dev_bundle()
        with mock.patch.object(release, "host_runs", return_value=True), self.assertRaises(OSError):
            release.verify_package_inputs(bundle, self.root)  # the fixture is not a library

    def test_host_runs_compares_the_machine(self) -> None:
        self.assertFalse(release.host_runs({"architecture": "riscv64", "os": "linux"}))
        with mock.patch("platform.machine", return_value="arm64"), mock.patch("platform.system", return_value="Darwin"):
            self.assertTrue(release.host_runs({"architecture": "aarch64", "os": "macos"}))
            self.assertFalse(release.host_runs({"architecture": "x86_64", "os": "macos"}))


@unittest.skipIf(shutil.which("node") is None, "node is not installed")
class NodeBundleTest(unittest.TestCase):
    """sdk/node/scripts/verify_bundle.js, as build.js calls it."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.package = Path(self._tmp.name) / "package"
        self.package.mkdir()
        self.declare("0.13.0-dev.0", 26)

    def declare(self, version: str, revision: int) -> None:
        (self.package / "package.json").write_text(json.dumps({"version": version}), encoding="utf-8")
        (self.package / "index.js").write_text(f"const ABI_REVISION = {revision};\n", encoding="utf-8")

    def verify(self, bundle: Path, release_flag: bool = False) -> subprocess.CompletedProcess:
        script = (
            "const { verifyBundle } = require(process.argv[1]);"
            "verifyBundle(process.argv[2], { release: process.argv[3] === 'release', packageRoot: process.argv[4] });"
        )
        return subprocess.run(
            ["node", "-e", script, str(ROOT / "sdk" / "node" / "scripts" / "verify_bundle.js"), str(bundle), "release" if release_flag else "dev", str(self.package)],
            capture_output=True,
            text=True,
        )

    def bundle(self, **fixture) -> Path:
        return release_archive._sdk_fixture(Path(tempfile.mkdtemp(dir=self._tmp.name)), "linux", TARGET, **fixture)

    def test_a_matching_bundle_passes(self) -> None:
        self.assertEqual(self.verify(self.bundle(version="0.13.0-dev+0123456789ab")).returncode, 0)
        self.declare("0.13.0", 26)
        proc = self.verify(self.bundle(version="0.13.0"), release_flag=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.declare("0.13.0-fork.2", 26)
        proc = self.verify(self.bundle(version="0.13.0-fork.2"), release_flag=True)
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_refusals(self) -> None:
        proc = self.verify(self.bundle(version="0.12.0-dev+0123456789ab"))
        self.assertIn("package.json says 0.13.0-dev.0", proc.stderr)
        proc = self.verify(self.bundle(version="0.13.0-dev+0123456789ab", revision=25))
        self.assertIn("implements ABI revision 25", proc.stderr)
        proc = self.verify(self.bundle(version="0.13.0-dev+0123456789ab"), release_flag=True)
        self.assertIn("cannot go into a formal release", proc.stderr)
        tampered = self.bundle(version="0.13.0-dev+0123456789ab")
        (tampered / "lib" / "libmetask_agentcore.so").write_bytes(b"another")
        self.assertIn("not the file its manifest pins", self.verify(tampered).stderr)


class ForkReleaseWorkflowTest(unittest.TestCase):
    def test_release_publishes_the_pushed_fork_tag(self):
        try:
            import yaml
        except ImportError:  # requirements-dev.txt
            self.skipTest("PyYAML is not installed")
        workflow = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8"))
        self.assertEqual(workflow.get("on", workflow.get(True)), {"push": {"tags": ["fork/v*-fork.*"]}})
        steps = workflow["jobs"]["publish"]["steps"]
        publish = next(step for step in steps if step.get("name") == "Create GitHub release")
        self.assertEqual(publish["env"]["RELEASE_TAG"], "${{ github.ref_name }}")
        self.assertIn('gh release create "$RELEASE_TAG" --verify-tag', publish["run"])
