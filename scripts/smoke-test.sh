#!/usr/bin/env bash
set -euo pipefail

TWT="${1:?usage: smoke-test.sh /path/to/twt}"
TWT="$(cd "$(dirname "$TWT")" && pwd)/$(basename "$TWT")"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/treepool-smoke.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
REPO="$STAGE/repository"
mkdir "$REPO"
git -C "$REPO" init -b main >/dev/null
git -C "$REPO" config user.name "Treepool Smoke Test"
git -C "$REPO" config user.email "smoke@example.invalid"
printf 'seed\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -m initial >/dev/null

cd "$REPO"
"$TWT" init --slots 1 --json | grep '"ok" : true' >/dev/null
"$TWT" setup --dry-run --json | grep '"created"' >/dev/null
"$TWT" start smoke/branch --from main --json | grep -F '"action" : "created"' >/dev/null
"$TWT" start smoke/branch --json | grep -F '"action" : "resumed"' >/dev/null
"$TWT" release smoke/branch --json | grep '"detached" : true' >/dev/null
test "$(git rev-parse --verify refs/heads/smoke/branch)" != ""
"$TWT" start smoke/branch --json | grep -F '"action" : "switched"' >/dev/null
"$TWT" release smoke/branch --json | grep '"detached" : true' >/dev/null

SLOT="$STAGE/repository.worktrees/tree-1"
"$TWT" start smoke/force --from main --json >/dev/null
printf 'discard\n' > "$SLOT/README.md"
set +e
"$TWT" release smoke/force --json >/dev/null 2> "$STAGE/dirty-error.json"
STATUS=$?
set -e
test "$STATUS" -eq 5
test "$(cat "$SLOT/README.md")" = discard
"$TWT" release smoke/force --force --json | grep '"detached" : true' >/dev/null
test "$(cat "$SLOT/README.md")" = seed
test "$(git rev-parse --verify refs/heads/smoke/force)" = "$(git rev-parse main)"

"$TWT" start smoke/force --json >/dev/null
printf 'staged\n' > "$SLOT/README.md"
git -C "$SLOT" add README.md
printf 'unstaged\n' > "$SLOT/README.md"
set +e
"$TWT" release smoke/force --force --json >/dev/null 2> "$STAGE/staged-error.json"
STATUS=$?
set -e
test "$STATUS" -eq 5
grep -q 'staged changes' "$STAGE/staged-error.json"
test "$(cat "$SLOT/README.md")" = unstaged
test "$(git -C "$SLOT" show :README.md)" = staged
git -C "$SLOT" restore --staged README.md
printf 'keep\n' > "$SLOT/new.txt"
set +e
"$TWT" release smoke/force --force --json >/dev/null 2> "$STAGE/untracked-error.json"
STATUS=$?
set -e
test "$STATUS" -eq 5
grep -q 'untracked files' "$STAGE/untracked-error.json"
test "$(cat "$SLOT/new.txt")" = keep
test "$(cat "$SLOT/README.md")" = unstaged
rm "$SLOT/new.txt"
mkdir "$SLOT/nested"
(cd "$SLOT/nested" && "$TWT" release --force --json) | grep '"detached" : true' >/dev/null
test "$(cat "$SLOT/README.md")" = seed

sed 's/"baseBranch" : ""/"baseBranch" : "main"/' .twt.json > .twt.json.tmp
mv .twt.json.tmp .twt.json
"$TWT" new smoke/default --json | grep -F '"branch" : "smoke\/default"' >/dev/null
set +e
"$TWT" new smoke/full --from main >/dev/null 2> "$STAGE/full-error.txt"
STATUS=$?
set -e
test "$STATUS" -eq 4
grep -q "Hint: Run 'twt list'" "$STAGE/full-error.txt"
"$TWT" release smoke/default --json | grep '"detached" : true' >/dev/null

sed 's/"baseBranch" : "main"/"baseBranch" : ""/' .twt.json > .twt.json.tmp
mv .twt.json.tmp .twt.json
set +e
"$TWT" new smoke/missing-base --json >/dev/null 2> "$STAGE/base-error.json"
STATUS=$?
set -e
test "$STATUS" -eq 3
grep -q '"code" : "invalid_config"' "$STAGE/base-error.json"
grep -q "pass '--from REF'" "$STAGE/base-error.json"
! grep -q '"suggestion"' "$STAGE/base-error.json"
"$TWT" new smoke/explicit --from main --json | grep -F '"branch" : "smoke\/explicit"' >/dev/null
"$TWT" release smoke/explicit --json | grep '"detached" : true' >/dev/null

set +e
"$TWT" init --slots 2 --json >/dev/null 2> "$STAGE/error.json"
STATUS=$?
set -e
test "$STATUS" -eq 3
grep -q '"code" : "already_configured"' "$STAGE/error.json"

# Fingerprint selection must prefer a warm match over the oldest idle slot.
printf 'base\n' > dependencies.lock
git add dependencies.lock
git commit -m 'add fingerprint' >/dev/null
git switch -c smoke/fingerprint >/dev/null
printf 'target\n' > dependencies.lock
git add dependencies.lock
git commit -m 'change fingerprint' >/dev/null
git switch main >/dev/null
sed -e 's/"size" : 1/"size" : 2/' \
    -e '/"schemaVersion"/i\
  "fingerprint" : "dependencies.lock",\
' .twt.json > .twt.json.tmp
mv .twt.json.tmp .twt.json
"$TWT" setup --json >/dev/null
"$TWT" switch smoke/fingerprint --slot tree-2 --json >/dev/null
"$TWT" release tree-2 --json >/dev/null
"$TWT" switch smoke/fingerprint --json | grep '"name" : "tree-2"' >/dev/null
"$TWT" release tree-2 --json >/dev/null
"$TWT" new smoke/fingerprint-new --from smoke/fingerprint --json | grep '"name" : "tree-2"' >/dev/null
"$TWT" release tree-2 --json >/dev/null

INSTALL="$STAGE/install"
mkdir -p "$INSTALL/bin" "$INSTALL/zsh" "$INSTALL/bash" "$INSTALL/fish"
install -m 0755 "$TWT" "$INSTALL/bin/twt"
touch "$INSTALL/zsh/_twt" "$INSTALL/bash/twt" "$INSTALL/fish/twt.fish"
SKILLS=(
  "$INSTALL/home/.codex/skills/use-treepool-worktrees/SKILL.md"
  "$INSTALL/home/.claude/skills/use-treepool-worktrees/SKILL.md"
  "$INSTALL/home/.config/opencode/skills/use-treepool-worktrees/SKILL.md"
  "$INSTALL/home/.pi/agent/skills/use-treepool-worktrees/SKILL.md"
)
for harness in codex claude-code opencode pi; do
  HOME="$INSTALL/home" "$INSTALL/bin/twt" config "--$harness" >/dev/null
done
HOME="$INSTALL/home" "$INSTALL/bin/twt" config --show | grep 'Codex: current' >/dev/null
HOME="$INSTALL/home" "$INSTALL/bin/twt" config --codex --remove --dry-run >/dev/null
test -f "${SKILLS[0]}"
printf '\nuser change\n' >> "${SKILLS[0]}"
set +e
HOME="$INSTALL/home" "$INSTALL/bin/twt" config --codex --remove >/dev/null 2>&1
STATUS=$?
set -e
test "$STATUS" -ne 0
test -f "${SKILLS[0]}"
HOME="$INSTALL/home" "$INSTALL/bin/twt" config --codex --remove --force >/dev/null
HOME="$INSTALL/home" "$INSTALL/bin/twt" config --codex >/dev/null
if [[ "$(uname -s)" == "Darwin" ]]; then
  mkdir -p "$INSTALL/apps/Treepool.app"
fi
TREEPOOL_BIN_DIR="$INSTALL/bin" \
TREEPOOL_COMPLETION_DIR="$INSTALL/zsh" \
TREEPOOL_BASH_COMPLETION_DIR="$INSTALL/bash" \
TREEPOOL_FISH_COMPLETION_DIR="$INSTALL/fish" \
TREEPOOL_APP_DIR="$INSTALL/apps" \
HOME="$INSTALL/home" \
  "$INSTALL/bin/twt" uninstall >/dev/null
test ! -e "$INSTALL/bin/twt"
test ! -e "$INSTALL/zsh/_twt"
test ! -e "$INSTALL/bash/twt"
test ! -e "$INSTALL/fish/twt.fish"
test ! -e "$INSTALL/apps/Treepool.app"
for skill in "${SKILLS[@]}"; do test ! -e "$skill"; done
test -f "$REPO/.twt.json"
