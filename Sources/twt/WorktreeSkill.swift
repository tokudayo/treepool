import Foundation

enum WorktreeSkill {
    static let contents = #"""
    ---
    name: use-treepool-worktrees
    description: Manage isolated tasks with Treepool's reusable Git worktrees. Use in repositories with .twt.json to allocate or resume worktrees and set up, repair, or release pool slots. Do not use for ordinary Git branching.
    ---

    # Use Treepool Worktrees

    Use `twt` for pool lifecycle changes, not raw `git worktree` commands.
    Treepool does not fetch remotes or install dependencies.

    ## Select a slot

    1. Run `command -v twt`, `git rev-parse --show-toplevel`, and `twt list --json`. If `twt` is
       unavailable, report that it must be installed or added to `PATH`.
    2. In `data`, match the current root or task branch to a pool entry (`isPoolSlot: true`).
       Continue in it when `exists: true` and `detached: false`. `twt start` also performs this
       resume check; never allocate a duplicate slot or alter an active branch.
    3. If `twt list` reports `missing_config`, run `twt init` only when the user explicitly asks
       to configure the repository.
    4. If fewer entries have `isPoolSlot: true` and `exists: true` than `.twt.json`'s `pool.size`,
       use `twt setup --dry-run --json` then `twt setup --json` for absent entries, or
       `twt repair --dry-run --json` then `twt repair --json` for `exists: false` or stale
       registrations. Apply only when setup is in scope. Leave conflicts and extras untouched.

    ## Allocate and work

    Follow the repository's branch convention:

    ```bash
    twt start <branch> --from <ref> --json
    twt start <branch> --json
    ```

    `start` resumes a branch already active in a pool slot, switches an existing local or
    configured-remote branch into an idle slot, or creates an unknown branch. Creation uses the
    configured `baseBranch`; pass `--from` when it is empty or another ref is required. `--from`
    is ignored when the branch is resumed or switched. Pass `--slot <name-or-path>` when a
    specific clean, detached slot is required. Otherwise Treepool uses the configured `fingerprint`
    file to prefer an exact content match, then the smallest diff; without a usable fingerprint it
    chooses the oldest idle slot.
    A requested slot that conflicts with an already-active branch is refused. Use `new` or
    `switch` only when the user explicitly requires that precise operation.
    Read `data.action` (`resumed`, `switched`, or `created`) and use `data.path` for subsequent
    work. If `.twt.json` configures `copyPatterns`, a switching or creating `start` copies
    matching files from the primary checkout into the assigned slot at the same relative paths.
    A resumed `start` does not copy files or rerun assignment hooks. Report warning messages from
    command output, including patterns that matched no files.
    If `.twt.json` configures `hooks.postAssign`, Treepool runs those commands from the assigned
    slot before returning success. Report hook failures and do not continue work after a failed
    allocation command.
    Treepool does not fetch; fetch only when network changes are in scope. Use returned `data.path`
    for all work and verification. Keep concurrent tasks separate and do not edit the
    primary checkout after assignment. If capacity is exhausted, report `twt list --json`; never
    alter or release another task's slot.

    ## Hand off and release

    For software publication, follow the repository's release instructions. When CI creates
    version tags after a release PR merges, leave tagging to that workflow.

    Commit, push, and verify from the assigned worktree. Report its branch, path, verification,
    and Git state. Keep it active by default; release only when asked or explicitly required:

    ```bash
    twt release --json
    twt release <exact-branch-slot-or-path> --json
    ```

    Release refuses tracked changes or non-ignored untracked files by default, detaches the slot,
    and preserves the branch. Only when the user explicitly authorizes discarding unstaged changes,
    use `twt release --force --json` (with an exact query when outside the slot). Force release
    discards unstaged tracked edits and deletions; staged changes and non-ignored untracked files
    block it before any changes are discarded. Ignored files are kept. If `.twt.json` configures
    `hooks.preRelease`, Treepool runs those commands before discarding changes, checking cleanliness,
    and detaching. A failed hook stops force release too. Never alter work merely to make release
    succeed without explicit authorization. Do not bypass a Treepool operation lock.

    When the user requests a CLI upgrade, run `twt upgrade` from any directory. It installs the
    latest release and refreshes shell completions. Use `twt upgrade --to X.Y.Z` for a specific
    release. Repository configuration, worktrees, and installed agent guidance are preserved.

    Use `twt config --<harness> --remove` to remove one installed skill, or `twt uninstall` to
    remove Treepool and its unmodified skills. Neither changes repository worktrees or configuration.
    """#
}
