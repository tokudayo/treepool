#!/usr/bin/env python3
"""Tag a merged release after its main CI succeeds, then dispatch publication."""

import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request


def git(root, *arguments):
    return subprocess.check_output(
        ["git", *arguments], cwd=root, text=True
    ).strip()


def prepare_release(event, root, api):
    repository = event["repository"]["full_name"]
    run = event["workflow_run"]
    if (
        run["conclusion"] != "success"
        or run["event"] != "push"
        or run["head_branch"] != "main"
        or run["head_repository"]["full_name"].lower() != repository.lower()
    ):
        print("Skipping: this is not successful main push CI for this repository.")
        return

    sha = run["head_sha"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or git(root, "rev-parse", "HEAD") != sha:
        raise ValueError("The checkout must match the commit that passed CI.")

    pulls = api("GET", f"commits/{sha}/pulls?per_page=100")
    releases = [
        pull for pull in pulls
        if pull.get("merged_at")
        and pull["merge_commit_sha"] == sha
        and pull["base"]["ref"] == "main"
        and pull["head"]["ref"].startswith("release/")
        and pull["head"].get("repo")
        and pull["head"]["repo"]["full_name"].lower() == repository.lower()
    ]
    if not releases:
        print("Skipping: this commit did not merge a release branch into main.")
        return
    if len(releases) != 1:
        raise ValueError("Expected exactly one merged release PR for this commit.")

    version = (root / "VERSION").read_text().strip()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("VERSION must contain X.Y.Z.")
    tag = f"v{version}"
    if releases[0]["head"]["ref"] != f"release/{tag}":
        raise ValueError("The release branch name must match VERSION.")
    changelog = (root / "CHANGELOG.md").read_text()
    section = re.search(
        rf"^## {re.escape(version)} - (\d{{4}}-\d{{2}}-\d{{2}})$",
        changelog, re.MULTILINE,
    )
    if not section:
        raise ValueError("CHANGELOG.md must have a dated section for VERSION.")
    datetime.date.fromisoformat(section[1])

    ref = f"refs/tags/{tag}"
    exists = subprocess.run(
        ["git", "show-ref", "--verify", "--quiet", ref], cwd=root
    ).returncode
    if exists == 0:
        if git(root, "cat-file", "-t", ref) != "tag" or git(root, "rev-parse", f"{ref}^{{commit}}") != sha:
            raise ValueError(f"Existing {tag} must be annotated and point to the CI commit.")
    elif exists == 1:
        git(
            root, "-c", "user.name=github-actions[bot]",
            "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
            "tag", "-a", tag, "-m", f"Release {version}", sha,
        )
        git(root, "push", "origin", ref)
    else:
        raise ValueError("Could not inspect existing tags.")

    if api("GET", f"releases/tags/{tag}", missing_ok=True) is not None:
        print(f"Skipping publication: {tag} is already published.")
        return
    runs = api("GET", f"actions/workflows/release.yml/runs?head_sha={sha}&per_page=100")
    if any(
        candidate["head_sha"] == sha
        and candidate["status"] != "completed"
        for candidate in runs["workflow_runs"]
    ):
        print(f"Skipping dispatch: publication for {tag} is already running.")
        return
    api("POST", "actions/workflows/release.yml/dispatches", {"ref": tag})
    print(f"Dispatched Release for {tag} at {sha}.")


def main():
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repository = os.environ["GITHUB_REPOSITORY"]
    if event["repository"]["full_name"].lower() != repository.lower():
        raise ValueError("The event repository must match GITHUB_REPOSITORY.")
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com")

    def api(method, path, payload=None, missing_ok=False):
        request = urllib.request.Request(
            f"{base}/repos/{repository}/{path}",
            data=json.dumps(payload).encode() if payload is not None else None,
            method=method,
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
                "X-GitHub-Api-Version": "2022-11-28",
                "Content-Type": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise

    prepare_release(event, Path.cwd(), api)


if __name__ == "__main__":
    main()
