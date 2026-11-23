from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import agentcore_contract as contract  # noqa: E402


class SdkPackageVersionTest(unittest.TestCase):
    def test_generated_versions_match_the_root_declaration(self) -> None:
        self.assertEqual(contract.package_version_findings(ROOT), [])

    def test_fork_version_uses_each_package_formats_suffix(self) -> None:
        self.assertEqual(contract.python_version("0.16.1-fork.2"), "0.16.1+fork.2")
        self.assertEqual(contract.node_version("0.16.1-fork.2"), "0.16.1-fork.2")
