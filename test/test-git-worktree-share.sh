#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_WT="$SCRIPT_DIR/../bin/git-worktree-share"
TMPDIR_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

pass=0
fail=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		echo "  PASS: $label"
		pass=$((pass + 1))
	else
		echo "  FAIL: $label"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		fail=$((fail + 1))
	fi
}

assert_file_exists() {
	local label="$1" path="$2"
	if [ -e "$path" ]; then
		echo "  PASS: $label"
		pass=$((pass + 1))
	else
		echo "  FAIL: $label (not found: $path)"
		fail=$((fail + 1))
	fi
}

assert_symlink() {
	local label="$1" path="$2"
	if [ -L "$path" ]; then
		echo "  PASS: $label"
		pass=$((pass + 1))
	else
		echo "  FAIL: $label (not a symlink: $path)"
		fail=$((fail + 1))
	fi
}

assert_not_exists() {
	local label="$1" path="$2"
	if [ ! -e "$path" ] && [ ! -L "$path" ]; then
		echo "  PASS: $label"
		pass=$((pass + 1))
	else
		echo "  FAIL: $label (exists: $path)"
		fail=$((fail + 1))
	fi
}

# Set up a repo with two worktrees
setup() {
	local dir="$TMPDIR_ROOT/test-$$-$RANDOM"
	mkdir -p "$dir"

	git init "$dir/main" --quiet
	cd "$dir/main"
	git commit --allow-empty -m "init" --quiet

	git worktree add "$dir/wt1" -b branch1 --quiet
	git worktree add "$dir/wt2" -b branch2 --quiet

	echo "$dir"
}

echo "test: add and sync"
dir="$(setup)"
cd "$dir/main"
echo "hello" >myconfig
"$GIT_WT" add myconfig >/dev/null

assert_symlink "main/myconfig is symlink" "$dir/main/myconfig"
assert_symlink "wt1/myconfig is symlink" "$dir/wt1/myconfig"
assert_symlink "wt2/myconfig is symlink" "$dir/wt2/myconfig"
assert_eq "content via symlink" "hello" "$(cat "$dir/wt2/myconfig")"

echo "test: add from non-main worktree"
dir="$(setup)"
cd "$dir/wt1"
echo "from-wt1" >localfile
"$GIT_WT" add localfile >/dev/null

assert_symlink "wt1/localfile is symlink" "$dir/wt1/localfile"
assert_symlink "main/localfile is symlink" "$dir/main/localfile"
assert_eq "content correct" "from-wt1" "$(cat "$dir/main/localfile")"

echo "test: list"
dir="$(setup)"
cd "$dir/main"
echo "a" >file_a && "$GIT_WT" add file_a >/dev/null
echo "b" >file_b && "$GIT_WT" add file_b >/dev/null
output="$("$GIT_WT" list)"
assert_eq "list shows both files" "file_a
file_b" "$output"

echo "test: rm"
dir="$(setup)"
cd "$dir/main"
echo "data" >shared
"$GIT_WT" add shared >/dev/null
"$GIT_WT" rm shared >/dev/null

assert_file_exists "restored to main" "$dir/main/shared"
assert_eq "restored content" "data" "$(cat "$dir/main/shared")"
# Should not be a symlink anymore
if [ -L "$dir/main/shared" ]; then
	echo "  FAIL: main/shared should be a real file"
	fail=$((fail + 1))
else
	echo "  PASS: main/shared is a real file"
	pass=$((pass + 1))
fi
assert_not_exists "removed from wt1" "$dir/wt1/shared"
assert_not_exists "removed from wt2" "$dir/wt2/shared"

echo "test: sync backs up existing real files"
dir="$(setup)"
cd "$dir/main"
echo "original" >conflict
echo "local-copy" >"$dir/wt1/conflict"
"$GIT_WT" add conflict >/dev/null

assert_symlink "wt1/conflict is now symlink" "$dir/wt1/conflict"
assert_file_exists "backup created" "$dir/wt1/conflict.shared-backup"
assert_eq "backup has old content" "local-copy" "$(cat "$dir/wt1/conflict.shared-backup")"

echo "test: sync is idempotent"
dir="$(setup)"
cd "$dir/main"
echo "data" >idempotent
"$GIT_WT" add idempotent >/dev/null
output="$("$GIT_WT" sync)"
assert_eq "no changes on re-sync" "All worktrees up to date" "$output"

echo "test: hook install"
dir="$(setup)"
cd "$dir/main"
"$GIT_WT" hook install >/dev/null
common="$(git rev-parse --git-common-dir)"
assert_file_exists "hook file created" "$common/hooks/post-checkout"
if grep -q "git-worktree-share" "$common/hooks/post-checkout"; then
	echo "  PASS: hook contains git-worktree-share"
	pass=$((pass + 1))
else
	echo "  FAIL: hook missing git-worktree-share"
	fail=$((fail + 1))
fi
# Install again should be idempotent
output="$("$GIT_WT" hook install)"
count=$(grep -c "git worktree-share sync" "$common/hooks/post-checkout")
assert_eq "hook not duplicated" "1" "$count"

echo "test: hook install upgrades an old hook block"
dir="$(setup)"
cd "$dir/main"
common="$(git rev-parse --git-common-dir)"
mkdir -p "$common/hooks"
cat >"$common/hooks/post-checkout" <<'OLD'
#!/bin/bash
echo user-hook

# git-worktree-share: auto-sync shared files into new worktrees
if [ "$1" = "0000000000000000000000000000000000000000" ]; then
    command -v git-worktree-share >/dev/null 2>&1 && git worktree-share sync
fi
OLD
chmod +x "$common/hooks/post-checkout"
"$GIT_WT" hook install >/dev/null
assert_eq "old block replaced, user content kept" '#!/bin/bash
echo user-hook

# git-worktree-share: auto-sync shared files into new worktrees
if [ "$1" = "0000000000000000000000000000000000000000" ]; then
    if command -v git-worktree-share >/dev/null 2>&1; then git worktree-share sync; fi
fi' "$(cat "$common/hooks/post-checkout")"
before="$(cat "$common/hooks/post-checkout")"
"$GIT_WT" hook install >/dev/null
assert_eq "reinstall is stable" "$before" "$(cat "$common/hooks/post-checkout")"

echo "test: hook syncs a new worktree when git-worktree-share is on PATH"
dir="$(setup)"
cd "$dir/main"
echo "data" >hooked
"$GIT_WT" add hooked >/dev/null
"$GIT_WT" hook install >/dev/null
mkdir -p "$dir/bin"
ln -s "$GIT_WT" "$dir/bin/git-worktree-share"
PATH="$dir/bin:$PATH" git worktree add "$dir/wt3" -b branch3 --quiet 2>/dev/null && status=0 || status=$?
assert_eq "worktree add succeeds" "0" "$status"
assert_symlink "new worktree linked" "$dir/wt3/hooked"

echo "test: hook does not fail checkout when git-worktree-share is not on PATH"
dir="$(setup)"
cd "$dir/main"
"$GIT_WT" hook install >/dev/null
git_dir="$(dirname "$(command -v git)")"
PATH="$git_dir" git worktree add "$dir/wt3" -b branch3 --quiet 2>/dev/null && status=0 || status=$?
assert_eq "worktree add succeeds" "0" "$status"

echo "test: add rejects git-tracked files"
dir="$(setup)"
cd "$dir/main"
echo "committed" >tracked-file
git add tracked-file && git commit -m "add tracked-file" --quiet
output="$("$GIT_WT" add tracked-file 2>&1)" && status=0 || status=$?
assert_eq "exits with error" "1" "$status"
assert_eq "error message" "Error: tracked-file is tracked by git — only untracked files can be shared" "$output"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
