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
