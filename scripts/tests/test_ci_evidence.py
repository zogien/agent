import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import ci_evidence

ROOT = Path(__file__).resolve().parents[2]


class EvidenceWriterTest(unittest.TestCase):
    def test_real_merge_commit_produces_exact_tree_and_rejects_wrong_event_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            git("config", "user.name", "evidence test")
            git("config", "user.email", "test@example.invalid")
            (root / "app").write_text("base")
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            git("switch", "-qc", "feature")
            (root / "app").write_text("changed")
            git("commit", "-qam", "feature")
            head = git("rev-parse", "HEAD")
            git("switch", "-q", "main")
            git("merge", "--no-ff", "-qm", "test merge", "feature")
            event = root / "event.json"
            event.write_text(json.dumps({"pull_request": {"base": {"sha": base}, "head": {"sha": head}}}))
            output = root / "pr-ci-evidence.json"
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event),
                       GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_REPOSITORY="o/r",
                       GITHUB_RUN_ID="17", GITHUB_RUN_ATTEMPT="2")
            # Run the same executable that the workflow runs, not a schema-only check.
            subprocess.run([sys.executable, str(ROOT / "scripts/ci_evidence.py"), "--output", str(output)],
                           cwd=root, env=env, capture_output=True, check=True)
            proof = json.loads(output.read_text())
            self.assertEqual((proof["head"], proof["base"], proof["tree"], proof["run_id"], proof["attempt"]),
                             (head, base, git("rev-parse", "HEAD^{tree}"), 17, 2))
            for change in ({"GITHUB_EVENT_NAME": "push"}, {"GITHUB_SHA": head}):
                with self.assertRaises(ValueError):
                    ci_evidence.write_evidence(root, output, dict(env, **change))
            event.write_text(json.dumps({"pull_request": {"base": {"sha": base}, "head": {"sha": base}}}))
            with self.assertRaises(ValueError):
                ci_evidence.write_evidence(root, output, env)

    def test_main_moved_past_the_merge_base_records_the_base_github_merged_onto(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, text=True, stderr=subprocess.DEVNULL).strip()
            git("init", "-q", "-b", "main")
            git("config", "user.name", "evidence test")
            git("config", "user.email", "test@example.invalid")
            (root / "app").write_text("base")
            git("add", ".")
            git("commit", "-qm", "base")
            merge_base = git("rev-parse", "HEAD")
            git("switch", "-qc", "feature")
            (root / "app").write_text("changed")
            git("commit", "-qam", "feature")
            head = git("rev-parse", "HEAD")
            git("switch", "-q", "main")
            (root / "other").write_text("main moved")
            git("add", ".")
            git("commit", "-qm", "main moved")
            tip = git("rev-parse", "HEAD")
            git("merge", "--no-ff", "-qm", "test merge", "feature")
            event = root / "event.json"
            event.write_text(json.dumps({"pull_request": {"base": {"sha": merge_base}, "head": {"sha": head}}}))
            output = root / "pr-ci-evidence.json"
            env = dict(os.environ, GITHUB_EVENT_NAME="pull_request", GITHUB_EVENT_PATH=str(event),
                       GITHUB_SHA=git("rev-parse", "HEAD"), GITHUB_REPOSITORY="o/r",
                       GITHUB_RUN_ID="17", GITHUB_RUN_ATTEMPT="1")
            ci_evidence.write_evidence(root, output, env)
            proof = json.loads(output.read_text())
            self.assertEqual((proof["head"], proof["base"], proof["tree"]),
                             (head, tip, git("rev-parse", "HEAD^{tree}")))
