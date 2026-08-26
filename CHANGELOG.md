# Changelog

All notable changes to Treepool are documented here.

## Unreleased

## 0.1.2 - 2026-08-26

- Add optional `.twt.json` `copyPatterns` globs to mirror matching files from the
  primary checkout into slots assigned by `twt new` and `twt switch`.
- Add warnings for `copyPatterns` entries that match no files.
- Always overwrite matching files in assigned slots (no overwrite toggle).

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
