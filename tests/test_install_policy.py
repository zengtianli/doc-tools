"""Installation policy regressions; these do not install or touch a real app."""
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/install.py"
spec = importlib.util.spec_from_file_location("dockit_install", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallPolicy(unittest.TestCase):
    def test_requirement_readback_accepts_codesign_stdout(self):
        outputs = [subprocess.CompletedProcess([], 0, "", "TeamIdentifier=B9LJH93LA4\n"),
                   subprocess.CompletedProcess([], 0, 'designated => identifier "io.github.zengtianli.DocTools"\n', "Executable=/app\n")]
        with patch.object(installer.subprocess, "run", side_effect=outputs):
            self.assertEqual(installer.signing_identity(Path("app")), ("B9LJH93LA4", 'identifier "io.github.zengtianli.DocTools"'))

    def test_distribution_still_requires_notarization(self):
        with patch.object(installer.notarize, "notarized", return_value=["no stapled ticket"]) as gate:
            self.assertEqual(installer.policy_problems(Path("app"), None, local=False), ["no stapled ticket"])
            gate.assert_called_once()

    def test_local_rejects_adhoc_before_identity_comparison(self):
        with patch.object(installer, "signed_facts", return_value={"problems": ["not Developer ID"]}), patch.object(installer, "signing_identity") as identity:
            self.assertTrue(installer.policy_problems(Path("app"), None, local=True))
            identity.assert_not_called()

    def test_local_preserves_team_and_requirement(self):
        with tempfile.TemporaryDirectory() as temp:
            old = Path(temp)
            for previous in [("OTHER", "same"), ("TEAM", "changed")]:
                with patch.object(installer, "signed_facts", return_value={"problems": [], "nested": [{"team": "TEAM"}]}), patch.object(installer, "signing_identity", side_effect=[("TEAM", "same"), previous]):
                    self.assertTrue(installer.policy_problems(Path("app"), old, local=True))

    def test_local_rejects_nested_team_change(self):
        with patch.object(installer, "signed_facts", return_value={"problems": [], "nested": [{"team": "OTHER"}]}), patch.object(installer, "signing_identity", return_value=("TEAM", "same")):
            self.assertTrue(installer.policy_problems(Path("app"), None, local=True))

    def test_local_signed_same_identity_does_not_request_notarization(self):
        with patch.object(installer, "signed_facts", return_value={"problems": [], "nested": [{"team": "TEAM"}]}), patch.object(installer, "signing_identity", return_value=("TEAM", "same")), patch.object(installer.notarize, "notarized") as notary:
            self.assertEqual(installer.policy_problems(Path("app"), None, local=True), [])
            notary.assert_not_called()


if __name__ == "__main__":
    unittest.main()
