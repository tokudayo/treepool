# Treepool

- Swift 6 package. Run `swift test` before handoff; build the CLI with
  `swift build -c release --product twt`.
- Treepool manages reusable Git worktree slots. Keep lifecycle actions in the CLI;
  do not add them to the macOS menu-bar app.
- `twt release` is non-destructive: it must refuse dirty worktrees and preserve
  the branch.
- Agent workflow guidance is opt-in: `twt config --codex`, `--claude-code`,
  `--opencode`, or `--pi` installs it for a user-selected harness.
- When changing Treepool commands or workflow behavior, update the bundled skill
  template in `Sources/twt/WorktreeSkill.swift` as part of the same change.
- Release tags must match `VERSION`: before tagging, update `VERSION` and
  `CHANGELOG.md`, commit them to `main`, and push `main`.
- Keep `CHANGELOG.md` structured with an `Unreleased` section and release entries
  grouped under `Added`, `Changed`, `Fixed`, and `Documentation` headings when
  those categories apply. When asked for release notes or patch notes, summarize
  from this structured changelog first.
- Do not manually line-wrap changelog bullets or release-note bullets; keep each
  bullet as one line so it can be copied into GitHub release notes cleanly.
- Create releases from `main` with an annotated tag named exactly `v$(cat VERSION)`
  (for example, `git tag -a v0.1.2 -m "Treepool 0.1.2"`). Pushing that tag triggers
  the GitHub release workflow.
- Do not tag a commit whose `VERSION` still names the previous release; CI validates
  `GITHUB_REF_NAME == v$(tr -d '[:space:]' < VERSION)` and will fail on mismatch.
