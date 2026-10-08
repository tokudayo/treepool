import copy
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock


spec = importlib.util.spec_from_file_location(
    "auto_release", Path(__file__).resolve().parents[1] / "auto-release.py"
)
auto_release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(auto_release)


class AutoReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="treepool-auto-release-")
        self.addCleanup(self.temporary.cleanup)
        stage = Path(self.temporary.name)
        self.root = stage / "repo"
        self.root.mkdir()
        self.remote = stage / "remote.git"
        self.command("git", "init", "--bare", str(self.remote))
        self.command("git", "init", "-b", "main")
        self.command("git", "config", "user.name", "Release Test")
        self.command("git", "config", "user.email", "test@example.invalid")
        self.command("git", "remote", "add", "origin", str(self.remote))
        (self.root / "VERSION").write_text("0.2.2\n")
        (self.root / "CHANGELOG.md").write_text("## 0.2.2 - 2026-10-09\n")
        self.command("git", "add", ".")
        self.command("git", "commit", "-m", "release")
        self.sha = self.command("git", "rev-parse", "HEAD")
        self.event = {
            "repository": {"full_name": "owner/repo"},
            "workflow_run": {
                "conclusion": "success", "event": "push", "head_branch": "main",
                "head_repository": {"full_name": "owner/repo"}, "head_sha": self.sha,
            },
        }
        self.pull = {
            "merged_at": "2026-10-09T00:00:00Z", "merge_commit_sha": self.sha,
            "base": {"ref": "main"},
            "head": {"ref": "release/v0.2.2", "repo": {"full_name": "owner/repo"}},
        }
        self.published = None
        self.runs = []
        self.api = Mock(side_effect=self.response)

    def command(self, *args):
        return subprocess.check_output(
            args, cwd=self.root, text=True, stderr=subprocess.DEVNULL
        ).strip()

    def response(self, method, path, payload=None, missing_ok=False):
        if method == "POST":
            self.assertEqual(path, "actions/workflows/release.yml/dispatches")
            self.assertEqual(payload, {"ref": "v0.2.2"})
            return None
        if path.startswith("commits/"):
            return [self.pull]
        if path.startswith("releases/tags/"):
            self.assertTrue(missing_ok)
            return self.published
        if path.startswith("actions/workflows/release.yml/runs?"):
            return {"workflow_runs": self.runs}
        self.fail(f"Unexpected API request: {method} {path}")

    def run_release(self):
        auto_release.prepare_release(self.event, self.root, self.api)

    def dispatched(self):
        return [call for call in self.api.call_args_list if call.args[0] == "POST"]

    def test_creates_annotated_tag_on_remote_and_dispatches_exact_tag(self):
        self.run_release()
        self.assertEqual(self.command("git", "cat-file", "-t", "v0.2.2"), "tag")
        self.assertEqual(self.command("git", "rev-parse", "v0.2.2^{commit}"), self.sha)
        self.assertIn(self.sha, self.command("git", "ls-remote", "origin", "refs/tags/v0.2.2^{}"))
        self.assertEqual(len(self.dispatched()), 1)

    def test_skips_failed_ci_pr_ci_other_branches_and_other_repositories(self):
        for key, value in [
            ("conclusion", "failure"), ("event", "pull_request"),
            ("head_branch", "feature/test"),
            ("head_repository", {"full_name": "other/repo"}),
        ]:
            with self.subTest(key=key):
                event = copy.deepcopy(self.event)
                event["workflow_run"][key] = value
                auto_release.prepare_release(event, self.root, self.api)
        self.api.assert_not_called()
        self.assertEqual(self.command("git", "tag"), "")

    def test_skips_ordinary_unmerged_fork_and_unrelated_pull_requests(self):
        original = copy.deepcopy(self.pull)
        for kind in ["ordinary", "unmerged", "fork", "different_commit"]:
            with self.subTest(kind=kind):
                self.pull = copy.deepcopy(original)
                if kind == "ordinary":
                    self.pull["head"]["ref"] = "codex/feature"
                elif kind == "unmerged":
                    self.pull["merged_at"] = None
                elif kind == "fork":
                    self.pull["head"]["repo"]["full_name"] = "other/repo"
                else:
                    self.pull["merge_commit_sha"] = "0" * 40
                self.run_release()
                self.assertEqual(self.command("git", "tag"), "")
        self.assertEqual(self.dispatched(), [])

    def test_refuses_checkout_that_did_not_pass_ci(self):
        self.event["workflow_run"]["head_sha"] = "0" * 40
        with self.assertRaises(ValueError):
            self.run_release()
        self.api.assert_not_called()

    def test_refuses_branch_version_mismatch_and_invalid_version(self):
        for version in ["0.2.3", "not-a-version"]:
            with self.subTest(version=version):
                (self.root / "VERSION").write_text(version)
                with self.assertRaises(ValueError):
                    self.run_release()
                self.assertEqual(self.command("git", "tag"), "")

    def test_refuses_missing_or_invalid_dated_changelog(self):
        for changelog in ["## Unreleased\n", "## 0.2.2 - 2026-99-99\n"]:
            with self.subTest(changelog=changelog):
                (self.root / "CHANGELOG.md").write_text(changelog)
                with self.assertRaises(ValueError):
                    self.run_release()
                self.assertEqual(self.command("git", "tag"), "")

    def test_reuses_existing_annotated_tag_on_retry(self):
        self.run_release()
        tag_object = self.command("git", "rev-parse", "v0.2.2")
        self.api.reset_mock()
        self.run_release()
        self.assertEqual(self.command("git", "rev-parse", "v0.2.2"), tag_object)
        self.assertEqual(len(self.dispatched()), 1)

    def test_refuses_existing_lightweight_or_conflicting_tag(self):
        self.command("git", "tag", "v0.2.2")
        with self.assertRaises(ValueError):
            self.run_release()
        self.command("git", "tag", "-d", "v0.2.2")
        self.command("git", "commit", "--allow-empty", "-m", "later commit")
        self.command("git", "tag", "-a", "v0.2.2", "-m", "conflicting")
        self.command("git", "checkout", "--detach", self.sha)
        with self.assertRaises(ValueError):
            self.run_release()
        self.assertEqual(self.dispatched(), [])

    def test_does_not_dispatch_published_or_running_release(self):
        self.run_release()
        self.api.reset_mock()
        self.published = {"tag_name": "v0.2.2"}
        self.run_release()
        self.assertEqual(self.dispatched(), [])
        self.published = None
        self.runs = [{"head_sha": self.sha, "status": "in_progress"}]
        self.run_release()
        self.assertEqual(self.dispatched(), [])

    def test_retries_failed_publication(self):
        self.run_release()
        self.api.reset_mock()
        self.runs = [{"head_sha": self.sha, "status": "completed", "conclusion": "failure"}]
        self.run_release()
        self.assertEqual(len(self.dispatched()), 1)


if __name__ == "__main__":
    unittest.main()
