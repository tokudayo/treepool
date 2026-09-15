# Treepool

- Swift 6 package; run `swift test` and `swift build -c release --product twt` before handoff.
- Keep lifecycle actions in the CLI; menu-bar release must use `TreepoolCore` with identical safety guarantees.
- `twt release` must refuse dirty worktrees and preserve branches.
- Agent guidance is opt-in through `twt config --codex`, `--claude-code`, `--opencode`, or `--pi`.
- Update `Sources/twt/WorktreeSkill.swift` whenever commands or workflow behavior change.
- Start a release by fast-forwarding `main` from `origin/main` and creating `release/vX.Y.Z`; never develop releases on `main`.
- Merge only validated feature work into the release branch.
- During development, keep `VERSION` at the latest published version and changes under `CHANGELOG.md` → `Unreleased`.
- Once finalized, bump `VERSION`, create the dated changelog section, and raise a PR from the release branch to `main`.
- Keep changelog sections grouped under applicable `Added`, `Changed`, `Fixed`, and `Documentation` headings; never manually wrap bullets.
- After the PR merges, push `main`, create annotated tag `v$(cat VERSION)`, and push it; tag/version mismatches fail CI.
