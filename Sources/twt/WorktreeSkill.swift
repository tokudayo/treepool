import Foundation

enum WorktreeSkill {
    static let contents = #"""
    ---
    name: use-treepool-worktrees
    description: Manage isolated tasks with Treepool's reusable Git worktrees. Use in repositories with .twt.json to allocate or resume worktrees and set up, repair, or release pool slots. Do not use for ordinary Git branching.
    ---

    # Use Treepool Worktrees

    Use `twt` for pool lifecycle changes, not raw `git worktree` commands or the menu-bar app.
    Treepool does not fetch remotes or install dependencies.

    ## Select a slot

    1. Run `command -v twt`, `git rev-parse --show-toplevel`, and `twt list --json`. If `twt` is
       unavailable, report that it must be installed or added to `PATH`.
    2. In `data`, match the current root or task branch to a pool entry (`isPoolSlot: true`).
       Reuse it when `exists: true` and `detached: false`. Check all entries for branch occupancy;
       never allocate a duplicate slot or an active branch.
    3. If `twt list` reports `missing_config`, run `twt init` only when the user explicitly asks
       to configure the repository.
    4. If fewer entries have `isPoolSlot: true` and `exists: true` than `.twt.json`'s `pool.size`,
       use `twt setup --dry-run --json` then `twt setup --json` for absent entries, or
       `twt repair --dry-run --json` then `twt repair --json` for `exists: false` or stale
       registrations. Apply only when setup is in scope. Leave conflicts and extras untouched.

    ## Allocate and work

    Follow the repository's branch convention:

    ```bash
    twt new <branch> --from <ref> --json
    twt new <branch> --json
    twt switch <branch> --json
    ```

    `new` uses configured `baseBranch`; pass `--from` when it is empty or another ref is required.
    Pass `--slot <name-or-path>` to either command when a specific clean, detached slot is
    required; otherwise Treepool chooses the oldest idle slot. Use `switch` with an unqualified
    name for an existing local or configured-remote branch.
    Treepool does not fetch; fetch only when network changes are in scope. Use returned `data.path`
    for all work, setup, and verification. Keep concurrent tasks separate and do not edit the
    primary checkout after assignment. If capacity is exhausted, report `twt list --json`; never
    alter or release another task's slot.

    ## Hand off and release

    Commit, push, and verify from the assigned worktree. Report its branch, path, verification,
    and Git state. Keep it active by default; release only when asked or explicitly required:

    ```bash
    twt release --json
    twt release <exact-branch-slot-or-path> --json
    ```

    Release refuses tracked changes or non-ignored untracked files, detaches the slot, and
    preserves the branch. Never alter work merely to make release succeed. Do not bypass a
    Treepool operation lock.

    Use `twt config --<harness> --remove` to remove one installed skill, or `twt uninstall` to
    remove Treepool and its unmodified skills. Neither changes repository worktrees or configuration.
    """#
}
