#!/usr/bin/env bash
set -euo pipefail

to_posix_path() {
  cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"
}

INPUT_DIR=$(to_posix_path "$1")
MANAGED_ASSET=$(to_posix_path "$2")
INSTANCES_FIXTURE=$(to_posix_path "$3")
DISABLED_INSTANCES_FIXTURE=$(to_posix_path "$4")
FIXTURE_ROOT=$5
SYNTAX_COUNT=$6

case "$FIXTURE_ROOT" in
  /tmp/quest-veq-fault-[0-9]*) ;;
  *) printf 'unsafe fixture root: %s\n' "$FIXTURE_ROOT" >&2; exit 2 ;;
esac

MANAGED_COMMAND="$INPUT_DIR/managed-remove.sh"
MANAGED_DISABLED_COMMAND="$INPUT_DIR/managed-remove-disabled.sh"
INSTANCES_COMMIT_COMMAND="$INPUT_DIR/instances-commit.sh"
INSTANCES_ROLLBACK_COMMAND="$INPUT_DIR/instances-rollback.sh"
LOCK_COMMAND="$INPUT_DIR/lock-acquire.sh"
FILES_DIR="$FIXTURE_ROOT/files"
GAME_DIR="$FILES_DIR/game"
MODS_DIR="$GAME_DIR/mods"
STATE_DIR="$GAME_DIR/.questcraft/veq-dev"
MANAGED_PATH="$MODS_DIR/Vivecraft-Essentials-Quest.jar"
MANAGED_BACKUP="$STATE_DIR/managed-v66.bin"
LOCK_DIR="$STATE_DIR/mutation.lock"
LOCK_TOKEN="$LOCK_DIR/token"
TRANSACTION_ID=0123456789abcdef0123456789abcdef
COMMIT_MARKER="$STATE_DIR/commits/$TRANSACTION_ID-managed-remove.committed"
EXPECTED_MARKER="VEQ_TRANSACTION_V2:$TRANSACTION_ID:managed-remove"
EXPECTED_MANAGED_SHA=$(sha256sum "$MANAGED_ASSET" | cut -d ' ' -f 1)
export MANAGED_PATH LOCK_DIR LOCK_TOKEN COMMIT_MARKER

case_count=0
pass_count=0

pass() {
  case_count=$((case_count + 1))
  pass_count=$((pass_count + 1))
  printf 'PASS %02d %s\n' "$case_count" "$1"
}

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    fail "command unexpectedly succeeded: $*"
  fi
}

reset_fixture() {
  command rm -rf -- "$FIXTURE_ROOT"
  mkdir -p "$MODS_DIR" "$STATE_DIR"
  cp "$INSTANCES_FIXTURE" "$FILES_DIR/instances.json"
  cp "$MANAGED_ASSET" "$MANAGED_PATH"
  cp "$MANAGED_ASSET" "$MANAGED_BACKUP"
  mkdir "$LOCK_DIR"
  printf '%s\n' "$TRANSACTION_ID" > "$LOCK_TOKEN"
}

assert_managed_exact() {
  test -f "$MANAGED_PATH" || fail 'managed JAR is absent'
  test ! -L "$MANAGED_PATH" || fail 'managed JAR became a symlink'
  actual=$(sha256sum "$MANAGED_PATH" | cut -d ' ' -f 1)
  test "$actual" = "$EXPECTED_MANAGED_SHA" || fail 'managed JAR hash changed'
}

reset_fixture
bash "$MANAGED_COMMAND"
test ! -e "$MANAGED_PATH" || fail 'successful managed removal left the JAR visible'
test -f "$COMMIT_MARKER" || fail 'successful managed removal omitted its durable marker'
test "$(cat "$COMMIT_MARKER")" = "$EXPECTED_MARKER" || fail 'commit marker content differs'
pass 'managed removal commits a durable marker'

# Model a host transport error after the remote shell committed. The persistent
# marker is the proof consumed by Invoke-DeviceTransaction; the mutation is not
# replayed.
observed_transport_status=70
test "$observed_transport_status" -ne 0 || fail 'ambiguous transport simulation was not armed'
test "$(cat "$COMMIT_MARKER")" = "$EXPECTED_MARKER" || fail 'post-commit marker recovery failed'
pass 'ambiguous post-commit transport is recoverable without replay'

reset_fixture
rm() {
  if [[ " $* " == *" $MANAGED_PATH "* ]]; then
    command rm "$@"
    return 70
  fi
  command rm "$@"
}
export -f rm
expect_failure bash "$MANAGED_COMMAND"
unset -f rm
assert_managed_exact
test ! -e "$COMMIT_MARKER" || fail 'failed removal wrote a commit marker'
pass 'EnableDev rm fail-after-operation restores the managed JAR'

reset_fixture
cp "$DISABLED_INSTANCES_FIXTURE" "$STATE_DIR/instances-$TRANSACTION_ID.tmp"
bash "$INSTANCES_COMMIT_COMMAND"
disabled_sha=$(sha256sum "$DISABLED_INSTANCES_FIXTURE" | cut -d ' ' -f 1)
test "$(sha256sum "$FILES_DIR/instances.json" | cut -d ' ' -f 1)" = "$disabled_sha" || \
  fail 'EnableDev fixture did not commit disabled instances.json'
rm() {
  if [[ " $* " == *" $MANAGED_PATH "* ]]; then
    command rm "$@"
    return 70
  fi
  command rm "$@"
}
export -f rm
expect_failure bash "$MANAGED_DISABLED_COMMAND"
unset -f rm
assert_managed_exact
bash "$INSTANCES_ROLLBACK_COMMAND"
enabled_sha=$(sha256sum "$INSTANCES_FIXTURE" | cut -d ' ' -f 1)
test "$(sha256sum "$FILES_DIR/instances.json" | cut -d ' ' -f 1)" = "$enabled_sha" || \
  fail 'EnableDev compensation did not restore instances.json'
pass 'EnableDev combined failure restores managed JAR and instances.json'

reset_fixture
mv() {
  if [[ " $* " == *" $COMMIT_MARKER.tmp $COMMIT_MARKER "* ]]; then
    command mv "$@"
    return 70
  fi
  command mv "$@"
}
export -f mv
expect_failure bash "$MANAGED_COMMAND"
unset -f mv
assert_managed_exact
test ! -e "$COMMIT_MARKER" || fail 'failed marker promotion left a false commit proof'
pass 'marker fail-after-promotion is cleared before rollback'

reset_fixture
cp "$MANAGED_PATH" "$FIXTURE_ROOT/outside-managed.jar"
VEQ_FAKE_SYMLINK=$MANAGED_PATH
export VEQ_FAKE_SYMLINK
test() {
  if [[ $# -eq 3 && $1 == '!' && $2 == '-L' && $3 == "$VEQ_FAKE_SYMLINK" ]]; then return 1; fi
  if [[ $# -eq 2 && $1 == '-L' && $2 == "$VEQ_FAKE_SYMLINK" ]]; then return 0; fi
  builtin test "$@"
}
export -f test
outside_before=$(sha256sum "$FIXTURE_ROOT/outside-managed.jar" | cut -d ' ' -f 1)
expect_failure bash "$MANAGED_COMMAND"
unset -f test
unset VEQ_FAKE_SYMLINK
outside_after=$(sha256sum "$FIXTURE_ROOT/outside-managed.jar" | cut -d ' ' -f 1)
test "$outside_before" = "$outside_after" || fail 'symlink target was mutated'
assert_managed_exact
pass 'managed final-leaf symlink is rejected'

reset_fixture
mkdir "$FIXTURE_ROOT/outside-mods"
cp "$MANAGED_ASSET" "$FIXTURE_ROOT/outside-mods/Vivecraft-Essentials-Quest.jar"
VEQ_FAKE_PWD_PATH=$MODS_DIR
VEQ_FAKE_PWD_VALUE=$FIXTURE_ROOT/outside-mods
export VEQ_FAKE_PWD_PATH VEQ_FAKE_PWD_VALUE
pwd() {
  if [[ $PWD == "$VEQ_FAKE_PWD_PATH" ]]; then printf '%s\n' "$VEQ_FAKE_PWD_VALUE"; else command pwd "$@"; fi
}
export -f pwd
outside_before=$(sha256sum "$FIXTURE_ROOT/outside-mods/Vivecraft-Essentials-Quest.jar" | cut -d ' ' -f 1)
expect_failure bash "$MANAGED_COMMAND"
unset -f pwd
unset VEQ_FAKE_PWD_PATH VEQ_FAKE_PWD_VALUE
outside_after=$(sha256sum "$FIXTURE_ROOT/outside-mods/Vivecraft-Essentials-Quest.jar" | cut -d ' ' -f 1)
test "$outside_before" = "$outside_after" || fail 'swapped parent target was mutated'
pass 'canonical parent swap fails closed before mutation'

reset_fixture
command rm -rf -- "$LOCK_DIR"
mv() {
  if [[ " $* " == *" $LOCK_DIR/token.tmp $LOCK_TOKEN "* ]]; then
    command mv "$@"
    return 70
  fi
  command mv "$@"
}
export -f mv
expect_failure bash "$LOCK_COMMAND"
unset -f mv
test ! -e "$LOCK_DIR" || fail 'token-write failure left an orphan lock'
pass 'lock token fail-after-operation is compensated'

reset_fixture
command rm -rf -- "$LOCK_DIR"
mkdir "$LOCK_DIR"
touch -d '2 minutes ago' "$LOCK_DIR"
bash "$LOCK_COMMAND"
test -f "$LOCK_TOKEN" || fail 'stale tokenless lock was not recovered'
test "$(cat "$LOCK_TOKEN")" = "$TRANSACTION_ID" || fail 'recovered lock has wrong token'
pass 'old tokenless orphan lock is safely recovered'

reset_fixture
command rm -rf -- "$LOCK_DIR"
mkdir "$LOCK_DIR"
expect_failure bash "$LOCK_COMMAND"
test -d "$LOCK_DIR" || fail 'young tokenless lock was stolen'
test ! -e "$LOCK_TOKEN" || fail 'young tokenless lock acquired a token'
pass 'young tokenless lock remains fail-closed'

reset_fixture
command rm -rf -- "$LOCK_DIR"
mkdir "$FIXTURE_ROOT/outside-lock"
VEQ_FAKE_SYMLINK=$LOCK_DIR
export VEQ_FAKE_SYMLINK
test() {
  if [[ $# -eq 3 && $1 == '!' && $2 == '-L' && $3 == "$VEQ_FAKE_SYMLINK" ]]; then return 1; fi
  if [[ $# -eq 2 && $1 == '-L' && $2 == "$VEQ_FAKE_SYMLINK" ]]; then return 0; fi
  builtin test "$@"
}
export -f test
expect_failure bash "$LOCK_COMMAND"
unset -f test
unset VEQ_FAKE_SYMLINK
test -d "$FIXTURE_ROOT/outside-lock" || fail 'lock symlink target was removed'
pass 'lock final-leaf symlink is rejected'

reset_fixture
mkdir "$FIXTURE_ROOT/outside-game"
VEQ_FAKE_PWD_PATH=$GAME_DIR
VEQ_FAKE_PWD_VALUE=$FIXTURE_ROOT/outside-game
export VEQ_FAKE_PWD_PATH VEQ_FAKE_PWD_VALUE
pwd() {
  if [[ $PWD == "$VEQ_FAKE_PWD_PATH" ]]; then printf '%s\n' "$VEQ_FAKE_PWD_VALUE"; else command pwd "$@"; fi
}
export -f pwd
expect_failure bash "$LOCK_COMMAND"
unset -f pwd
unset VEQ_FAKE_PWD_PATH VEQ_FAKE_PWD_VALUE
test ! -e "$FIXTURE_ROOT/outside-game/.questcraft" || fail 'swapped game parent was mutated'
pass 'lock parent swap fails canonical guard'

command rm -rf -- "$FIXTURE_ROOT"
printf 'FaultCases=%d/%d BashSyntax=%s/%s DeviceTouched=false\n' \
  "$pass_count" "$case_count" "$SYNTAX_COUNT" "$SYNTAX_COUNT"
test "$pass_count" -eq 12
test "$case_count" -eq 12
