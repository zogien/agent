import json
import shutil
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

    def test_new_header_entry(self):
        path = self.root / "sdk/metask/agentcore.h"
        path.write_text(path.read_text().replace(
            "} metask_agentcore_team_api_v1;",
            "    metask_agentcore_team_poll_fn_v1 poll_once;\n} metask_agentcore_team_api_v1;",
        ))
        errors = check(self.root)
        for language in ("zig", "rust", "node", "python"):
            self.assertTrue(any(error.startswith(language) and "poll_once" in error for error in errors))

    def test_unknown_api(self):
        for language in ("node", "python"):
            path = self.root / f"sdk/{language}/abi-coverage.json"
            manifest = json.loads(path.read_text())
            manifest["session.run_input"] = "Runtime.run"
            path.write_text(json.dumps(manifest))
            self.assertTrue(any(error.startswith(f"{language} session.run_input: unknown API") for error in check(self.root)))
