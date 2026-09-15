<p align="center">
  <img src="assets/Treepool.png" alt="Treepool" width="160">
</p>

<h1 align="center">Treepool</h1>

<p align="center">
  A warm-pool Git worktree manager for macOS and Linux.
</p>

<p align="center">
  <a href="#installation">Install</a> ·
  <a href="#quick-start">Quick start</a> ·
  <a href="#commands">Commands</a> ·
  <a href="#configuration">Configuration</a>
</p>

Treepool keeps a reusable pool of detached Git worktrees ready for the next task.
Create or switch to a branch in an idle slot instead of repeatedly creating and
removing worktree directories.

## Features

- Reusable, pre-warmed worktree slots for parallel work.
- One-command task pickup with `twt start`, whether the branch is active, existing, or new.
- Safe release: dirty worktrees are never detached, cleaned, or deleted.
- Optional `copyPatterns` to mirror repo files into newly assigned slots.
- JSON output for scripts and coding-agent workflows.
- Optional macOS menu-bar companion for viewing configured repositories.

## Requirements

- Git 2.34 or newer
- macOS 14+ on Apple Silicon, or Linux on `x86_64`/`aarch64`

Swift 6 is required only when building from source. Release Linux binaries are
statically linked with Swift's musl SDK. macOS Intel is not supported in v0.1.1.

## Installation

Install the latest release without a Swift toolchain:

```sh
curl -fsSL https://raw.githubusercontent.com/tokudayo/treepool/main/scripts/install-release.sh | bash
```

The release installer verifies the archive checksum and puts `twt` in
`~/.local/bin`. If that directory is not on `PATH`, it prints the command needed
to add it for the current shell. Set `TREEPOOL_VERSION=0.2.0` to install a
specific release.

```sh
curl -fsSL https://raw.githubusercontent.com/tokudayo/treepool/main/scripts/install-release.sh | TREEPOOL_VERSION=0.2.0 bash
```

To build, test, and install from a checkout:

```sh
swift build
swift test
scripts/install.sh
```

The source installer also installs the optional, ad-hoc-signed `Treepool.app`
menu-bar companion in `~/Applications`. The app is source-only in v0.2.0 and is not
included in release downloads.

Uninstall binaries and installed agent guidance without touching repository
configuration or worktrees:

```sh
twt uninstall
```

## Quick start

From a repository's primary checkout:

```sh
twt init --slots 4
twt start toku/my-feature --from main --slot tree-2
```

`init` writes `.twt.json` and creates detached sibling slots:

```text
my-project/
my-project.worktrees/
  tree-1/
  tree-2/
  tree-3/
  tree-4/
```

Work in the path returned by `twt start`. Running the same command again resumes
the active slot. When the work is ready to hand off, run this inside that worktree:

```sh
twt release
```

Release refuses dirty worktrees, detaches the clean slot, and preserves the
branch. Treepool never deletes branches.

## Commands

| Command | Purpose |
| --- | --- |
| `twt init [--slots N]` | Write `.twt.json` and create the warm worktree pool. |
| `twt setup [--dry-run]` | Create missing slots from an existing committed `.twt.json`. |
| `twt repair [--dry-run]` | Recreate missing configured slots after clearing only their stale registrations. |
| `twt start BRANCH [--from REF] [--slot SLOT]` | Resume an active pool branch, switch an existing branch, or create a new branch. |
| `twt new BRANCH [--from REF] [--slot SLOT]` | Create a branch from `REF` or the configured base branch, then apply configured `copyPatterns`. |
| `twt switch BRANCH [--slot SLOT]` | Assign an existing local or `origin` branch to an idle slot, then apply configured `copyPatterns`. |
| `twt list` | Show branches, cleanliness, state, and paths. |
| `twt release [QUERY]` | Detach a clean assigned slot while preserving its branch. |
| `twt uninstall` | Remove Treepool and installed agent guidance while preserving repository state. |

`--slot` accepts an exact or unambiguous partial slot name or path and requires
that slot to be clean and detached when an assignment is needed. Without it,
`start`, `new`, and `switch` choose the oldest idle slot. If `start` finds the
branch already active, it resumes that slot; a conflicting `--slot` is refused.
`--from` is consulted only when `start` creates a branch, so the same invocation
can safely resume or switch that branch later.
`QUERY` accepts an exact or unambiguous partial slot name, branch, or path. With
no query, `release` must run from an assigned Treepool pool slot.

All lifecycle and list commands accept `--json`. Successful responses use a
versioned envelope. `start`, `new`, and `switch` return the worktree in
`data.path`; `start` also returns `data.action` as `resumed`, `switched`, or
`created`.

## Configuration

`.twt.json` is repository policy and may be committed. Runtime timestamps and
operation locks live in the repository's common `.git/twt/` directory.

```json
{
  "schemaVersion": 1,
  "baseBranch": "",
  "remote": "origin",
  "pool": {
    "size": 4,
    "root": "../my-project.worktrees",
    "pattern": "tree-{index}"
  },
  "copyPatterns": [
    ".env.local",
    "config/local/**/*.json"
  ],
  "hooks": {
    "postAssign": [
      "mise install",
      "npm install"
    ],
    "preRelease": [
      "swift test"
    ]
  }
}
```

Treepool does not fetch remotes, install dependencies, or clean ignored files.
Run your repository's usual setup commands in each assigned slot as needed.

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `schemaVersion` | integer | `1` | Configuration schema version. Treepool 0.2.x supports `1`. |
| `baseBranch` | string | `""` | Default ref for `twt start` or `twt new` when creating a branch and `--from` is omitted. If empty, creation requires `--from`. Pool setup can still auto-detect a bootstrap ref when this is empty. |
| `remote` | string | `"origin"` | Remote used by `twt start` or `twt switch` when tracking a branch that does not exist locally. Must not be empty. Treepool does not fetch. |
| `pool.size` | integer | `4` | Number of managed warm slots. Must be between `1` and `64`. |
| `pool.root` | string | `../<repo>.worktrees` from `twt init` | Directory containing managed slots. Relative paths are resolved from the primary checkout. Must be outside the primary checkout. |
| `pool.pattern` | string | `"tree-{index}"` | Slot directory name pattern. Must contain exactly one `{index}` and produce unique single-component names. |
| `copyPatterns` | string array | `[]` | Repository-relative glob patterns copied from the primary checkout into slots assigned by `twt start`, `twt new`, and `twt switch`. Supports `*`, `?`, and `**`. Patterns must not be absolute, contain empty path components, contain `..`, or target `.git` metadata. |
| `hooks.postAssign` | string array | `[]` | Shell commands run from the assigned slot after `twt start`, `twt new`, or `twt switch` checks out the branch and applies `copyPatterns`. A resumed `twt start` does not rerun assignment work. Commands run in order; the first non-zero exit stops the command. |
| `hooks.preRelease` | string array | `[]` | Shell commands run from the assigned slot before `twt release` detaches it. Commands run in order; the first non-zero exit stops release and leaves the slot active. |

When `copyPatterns` is set, matching files are copied to the same relative paths
in the assigned slot. Existing files at those paths are replaced. If a pattern
matches no files, Treepool reports a warning but still assigns the slot.

Hooks run with `/bin/sh -c` from the assigned slot root. `preRelease` hooks run
before the clean-worktree check, so they may update generated files or fail the
release before Treepool decides whether the slot can be detached.

After cloning a repository that already contains `.twt.json`, run `twt setup`.
After editing pool size or paths, preview with `twt setup --dry-run`, then run
`twt setup`. Extra registered worktrees are reported and never removed. If a
configured slot directory was deleted manually, preview and run `twt repair`.

## Coding-agent workflow guidance

Install optional Treepool guidance for one supported coding-agent harness:

```sh
twt config --codex
twt config --claude-code
twt config --opencode
twt config --pi
```

The document is installed globally for the chosen harness. Re-run with `--force`
to replace a modified Treepool document. Inspect or remove guidance with:

```sh
twt config --show
twt config --codex --dry-run
twt config --codex --remove
```

Removal preserves modified skill files unless `--force` is passed.

## macOS menu-bar app

Open `~/Applications/Treepool.app`, choose **Add Repository…**, then select a
repository with `.twt.json`. The app shows worktree status, can reveal or copy
worktree paths, and can safely release clean active slots. Configure repositories
with `twt init` or `twt setup` before adding them.

## Troubleshooting

- Dirty slots cannot be released; commit or otherwise resolve changes yourself.
- An exhausted pool is shown by `twt list`; Treepool never repurposes active slots.
- Treepool does not fetch. Fetch missing remote refs with Git before `start`, `new`, or `switch`.
- Run `twt repair --dry-run` for a missing configured slot.
- Exit status `8` means another lifecycle operation holds the repository lock.

## Development

```sh
swift test
swift build -c release --product twt
```

## Exit statuses

| Code | Meaning |
| --- | --- |
| `3` | Configuration or repository error |
| `4` | No available slot, no match, or ambiguous query |
| `5` | Unsafe action, such as releasing a dirty slot |
| `6` | Git failure |
| `8` | Another Treepool operation is already running |

Successful `--json` responses and parsed runtime failures use a schema-versioned
envelope. Argument-parser usage errors remain human-readable text. Schema version
1 is maintained compatibly throughout Treepool 0.1.x.

## License

[MIT](LICENSE)
