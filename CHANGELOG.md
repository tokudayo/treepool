# Changelog

All notable changes to Treepool are documented here.

## Unreleased

## 0.2.1 - 2026-10-09

### Added

- Add `twt release --force` to discard unstaged tracked changes before releasing, and an Abort / Force Release warning for dirty slots in the macOS menu-bar app; staged changes, untracked files, ignored files, branches, and commits are preserved.
- Add an optional `.twt.json` `fingerprint` file that prefers an idle slot with an exact content hash or, when no hash matches, the smallest line diff to the branch being assigned.

### Changed

- Run CI on release branch pushes, validate release builds for the CLI and macOS menu app, and cover force release and fingerprint selection in CLI smoke tests.

## 0.2.0 - 2026-09-15

### Added

- Add `twt start` to resume an active pool branch, switch an existing local or configured-remote branch, or create a new branch without requiring callers to choose between `twt new` and `twt switch`.

### Changed

- Split TreepoolCore lifecycle, repository, inspection, configuration, and file-copy responsibilities, and separate the macOS menu app into focused state, application, and view components.

## 0.1.4 - 2026-09-09

### Added

- Add a "Release Slot" action to the macOS menu-bar app that releases a clean, active pool slot through the same non-destructive `TreepoolCore` path as `twt release` (runs `hooks.preRelease`, refuses dirty worktrees, preserves the branch).

## 0.1.3 - 2026-08-26

### Added

- Add `.twt.json` `hooks.postAssign` and `hooks.preRelease` command arrays for slot lifecycle automation.

## 0.1.2 - 2026-08-26

### Added

- Add optional `.twt.json` `copyPatterns` globs to mirror matching files from the primary checkout into slots assigned by `twt new` and `twt switch`.
- Add warnings for `copyPatterns` entries that match no files.

### Changed

- Always overwrite matching files in assigned slots instead of exposing an overwrite toggle.

### Documentation

- Restructure the README Configuration section into a table that lists every supported `.twt.json` option and its default, constraints, and behavior.

## 0.1.1 - 2026-07-14

- Add `--slot` to `twt new` and `twt switch` for explicit clean, detached slot selection.

## 0.1.0

- Safe, reusable Git worktree pool lifecycle.
- Committed policy provisioning with `twt setup`.
- Targeted missing-slot recovery with `twt repair`.
- Versioned JSON output and coding-agent workflow guidance.
- One-command installation, PATH guidance, and repository-independent `twt uninstall`.
- Base-branch defaults and actionable CLI error hints.
- macOS Apple Silicon and static Linux CLI releases.
