import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_binding_parity import ROOT, check


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

    def test_missing_node_entry(self):
        path = self.root / "sdk/node/abi-coverage.json"
        manifest = json.loads(path.read_text())
        del manifest["mcp.describe"]
        path.write_text(json.dumps(manifest))
        self.assertEqual(check(self.root), ["node mcp.describe: missing from manifest"])

    def assert_new_team_entry_is_missing(self, declaration):
        path = self.root / "sdk/metask/agentcore.h"
        path.write_text(path.read_text().replace(
            "} metask_agentcore_team_api_v1;",
            f"    {declaration}\n}} metask_agentcore_team_api_v1;",
        ).replace("ASSERT_SIZE(metask_agentcore_team_api_v1, 24)", "ASSERT_SIZE(metask_agentcore_team_api_v1, 32)"))
        result = subprocess.run(
            [sys.executable, "scripts/check_binding_parity.py"], cwd=self.root, capture_output=True, text=True,
        )
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
            manifest = json.loads(path.read_text())
            manifest["session.run_input"] = "Runtime.run"
            path.write_text(json.dumps(manifest))
            self.assertTrue(any(error.startswith(f"{language} session.run_input: unknown API") for error in check(self.root)))
