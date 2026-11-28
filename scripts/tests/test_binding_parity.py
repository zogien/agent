import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_binding_parity import ROOT, check, inventory


class BindingParityTest(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        for filename in (
            "scripts/check_binding_parity.py",
            "sdk/metask/agentcore.h", "sdk/zig/types.zig", "sdk/zig/root.zig",
            "sdk/rust/src/lib.rs", "sdk/rust/src/raw.rs", "sdk/node/abi-coverage.json",
            "sdk/node/index.js", "sdk/node/src/addon.c", "sdk/node/index.d.ts", "sdk/python/abi-coverage.json",
            "sdk/python/src/metacodes/_client.py",
        ):
            destination = self.root / filename
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / filename, destination)

    def test_current_coverage(self):
        self.assertEqual(check(self.root), [])

    def run_parity_cli(self):
        flags = []
        if sys.version_info >= (3, 10):
            flags = ["-X", "warn_default_encoding", "-W", "error::EncodingWarning"]
        return subprocess.run(
            [sys.executable, *flags, "scripts/check_binding_parity.py"], cwd=self.root,
            env={**os.environ, "LC_ALL": "C", "PYTHONUTF8": "0", "PYTHONIOENCODING": "utf-8"},
            capture_output=True, encoding="utf-8",
        )

    def test_cli_reads_utf8_files_in_c_locale(self):
        result = self.run_parity_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Binding parity OK")

    def test_missing_node_entry(self):
        path = self.root / "sdk/node/abi-coverage.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        del manifest["mcp.describe"]
        path.write_text(json.dumps(manifest), encoding="utf-8")
        self.assertEqual(check(self.root), ["node mcp.describe: missing from manifest"])

    def test_every_run_options_field_is_required(self):
        header = (self.root / "sdk/metask/agentcore.h").read_text(encoding="utf-8")
        _, configs, _ = inventory(header)
        for language in ("node", "python"):
            path = self.root / f"sdk/{language}/abi-coverage.json"
            manifest = json.loads(path.read_text(encoding="utf-8"))
            for field in configs["run_options_v1"]:
                key = f"run_options_v1.{field}"
                with self.subTest(language=language, key=key):
                    path.write_text(json.dumps({k: v for k, v in manifest.items() if k != key}), encoding="utf-8")
                    self.assertEqual(check(self.root), [f"{language} {key}: missing from manifest"])
            path.write_text(json.dumps(manifest), encoding="utf-8")

    def assert_new_team_entry_is_missing(self, declaration):
        path = self.root / "sdk/metask/agentcore.h"
        header = path.read_text(encoding="utf-8").replace(
            "} metask_agentcore_team_api_v1;",
            f"    {declaration}\n}} metask_agentcore_team_api_v1;",
        ).replace("ASSERT_SIZE(metask_agentcore_team_api_v1, 24)", "ASSERT_SIZE(metask_agentcore_team_api_v1, 32)")
        path.write_text(header, encoding="utf-8")
        result = self.run_parity_cli()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        for language in ("node", "python"):
            self.assertIn(f"{language} team.poll_once: missing from manifest", result.stderr.splitlines())
        for language in ("zig", "rust"):
            self.assertIn(f"{language} missing TeamApi.poll_once", result.stderr.splitlines())

    def test_new_typedef_entry(self):
        self.assert_new_team_entry_is_missing("metask_agentcore_team_poll_fn_v1 poll_once;")

    def test_new_inline_function_pointer_entry(self):
        self.assert_new_team_entry_is_missing(
            "uint32_t (*poll_once)(metask_agentcore_session *, metask_agentcore_owned_bytes_v1 *,\n"
            "                          metask_agentcore_owned_bytes_v1 *);"
        )

    def test_unknown_api(self):
        for language in ("node", "python"):
            path = self.root / f"sdk/{language}/abi-coverage.json"
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["session.run_input"] = "Runtime.run"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            self.assertTrue(any(error.startswith(f"{language} session.run_input: unknown API") for error in check(self.root)))

    def test_node_requires_an_implementation(self):
        path = self.root / "sdk/node/abi-coverage.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["mcp.refresh"] = {"deferred": "#14"}
        path.write_text(json.dumps(manifest), encoding="utf-8")
        self.assertTrue(any(error.startswith("node mcp.refresh:") for error in check(self.root)))
