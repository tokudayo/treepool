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
- Explicit branch creation with `twt new --from REF`.
- Safe release: dirty worktrees are never detached, cleaned, or deleted.
- JSON output for scripts and coding-agent workflows.
- Optional macOS menu-bar companion for viewing configured repositories.

## Requirements

- Git 2.34 or newer
- macOS 14+ on Apple Silicon, or Linux on `x86_64`/`aarch64`

Swift 6 is required only when building from source. Release Linux binaries are
statically linked with Swift's musl SDK. macOS Intel is not supported in v0.1.0.

## Installation

Install the latest release without a Swift toolchain:

```sh
curl -fsSL https://raw.githubusercontent.com/tokudayo/treepool/main/scripts/install-release.sh | bash
```

The release installer verifies the archive checksum and puts `twt` in
`~/.local/bin`. If that directory is not on `PATH`, it prints the command needed
to add it for the current shell. Set `TREEPOOL_VERSION=0.1.0` to install a
specific release.

```sh
curl -fsSL https://raw.githubusercontent.com/tokudayo/treepool/main/scripts/install-release.sh | TREEPOOL_VERSION=0.1.0 bash
```

To build, test, and install from a checkout:

```sh
swift build
swift test
scripts/install.sh
```

The source installer also installs the optional, ad-hoc-signed `Treepool.app`
menu-bar companion in `~/Applications`. The app is source-only in v0.1.0 and is not
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
twt new toku/my-feature --from main
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

Work in the path returned by `twt new`. When the work is ready to hand off, run
this inside that worktree:

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
| `twt new BRANCH [--from REF]` | Create a branch from `REF` or the configured base branch. |
| `twt switch BRANCH` | Assign an existing local or `origin` branch to an idle slot. |
| `twt list` | Show branches, cleanliness, state, and paths. |
| `twt release [QUERY]` | Detach a clean assigned slot while preserving its branch. |
| `twt uninstall` | Remove Treepool and installed agent guidance while preserving repository state. |

`QUERY` accepts an exact or unambiguous partial slot name, branch, or path. With
no query, `release` must run from an assigned Treepool pool slot.

All lifecycle and list commands accept `--json`. Successful responses use a
versioned envelope; `new` and `switch` return the allocated worktree in
`data.path`.

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
  }
}
```

Treepool does not fetch remotes, install dependencies, or clean ignored files.
Run your repository's usual setup commands in each assigned slot as needed.
`baseBranch` defaults to empty, so `twt new` requires `--from`. Set `baseBranch`
to make that ref the default when `--from` is omitted. Pool setup can still
auto-detect a bootstrap ref when `baseBranch` is empty.

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
repository with `.twt.json`. The app shows worktree status and can reveal or copy
worktree paths. Lifecycle changes remain in the CLI; configure repositories with
`twt init` or `twt setup` before adding them.

## Troubleshooting

- Dirty slots cannot be released; commit or otherwise resolve changes yourself.
- An exhausted pool is shown by `twt list`; Treepool never repurposes active slots.
- Treepool does not fetch. Fetch missing remote refs with Git before `new` or `switch`.
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
