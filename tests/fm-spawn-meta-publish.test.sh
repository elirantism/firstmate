#!/usr/bin/env bash
# Regression test for fail-closed publication of state/<id>.meta in
# bin/fm-spawn.sh (the `if { ... } > "$STATE/$ID.meta"; then` block).
#
# state/<id>.meta is the authoritative record every read-only consumer trusts:
# bin/fm-crew-state.sh resolves worktree/backend/kind from it, the fleet
# snapshot derives current state and endpoints from it, and bin/fm-learn.sh
# enumerates and selects learning candidates from those rows. If the write
# silently fails, spawn reports success while the fleet loses the task, so the
# failure must abort the spawn with a clear error instead of being swallowed,
# and that abort must release the endpoint and worktree it already created -
# with no meta record, nothing downstream can ever reap them.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-meta-publish)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  kill-window) [ -z "${FM_FAKE_LOG:-}" ] || printf 'tmux %s\n' "$*" >> "$FM_FAKE_LOG"; exit 0 ;;
  has-session|new-session|new-window) exit 0 ;;
  send-keys) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
[ -z "${FM_FAKE_LOG:-}" ] || printf 'treehouse %s\n' "$*" >> "$FM_FAKE_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_case <name> <id> builds a home, a project with a real worktree the fake
# pane reports as its cwd, and a brief - the minimum a tmux spawn needs.
make_case() {
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  printf '%s|%s|%s|%s\n' "$home" "$proj" "$wt" "$fakebin"
}

read_case() {
  IFS='|' read -r HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$WT_DIR" \
    FM_FAKE_LOG="$HOME_DIR/fake-calls.log" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" 2>&1
}

test_metadata_publication_is_reported() {
  local rec id out status
  id=meta-publish-ok-z1
  rec=$(make_case publish-ok "$id")
  read_case "$rec"

  out=$(run_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when metadata can be published"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "published metadata does not record the worktree the fleet reads"
  assert_not_contains "$(cat "$HOME_DIR/fake-calls.log" 2>/dev/null || true)" "treehouse return" \
    "a successful spawn released the worktree it had just handed to the crewmate"
  pass "a successful spawn publishes the authoritative task metadata record"
}

# An unwritable state/<id>.meta path stands in for any failed publication
# (full disk, read-only state dir, a stale directory left at the path).
test_unpublishable_metadata_fails_closed() {
  local rec id out status
  id=meta-publish-fail-z1
  rec=$(make_case publish-fail "$id")
  read_case "$rec"
  mkdir -p "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] \
    || fail "spawn reported success while task metadata could not be published: $out"
  assert_contains "$out" "could not publish metadata for $id" \
    "unpublishable metadata did not produce a clear error"
  assert_not_contains "$out" "spawned $id" \
    "spawn announced a task whose authoritative metadata was never published"
  pass "a failed metadata publication aborts the spawn instead of being swallowed"
}

# Without a meta record nothing downstream can find the endpoint or the worktree
# the aborted spawn already created - fm-teardown.sh keys off meta and there is
# no orphan reaper - so the abort itself has to release both.
test_unpublishable_metadata_releases_created_resources() {
  local rec id out calls
  id=meta-publish-leak-z1
  rec=$(make_case publish-leak "$id")
  read_case "$rec"
  mkdir -p "$HOME_DIR/state/$id.meta"

  out=$(run_spawn "$id")
  calls=$(cat "$HOME_DIR/fake-calls.log" 2>/dev/null || true)
  assert_contains "$calls" "kill-window" \
    "aborted spawn left its backend window running with no metadata record: $out"
  assert_contains "$calls" "treehouse return --force $WT_DIR" \
    "aborted spawn left its worktree checked out with no metadata record: $out"
  pass "a failed metadata publication releases the endpoint and worktree it created"
}

test_metadata_publication_is_reported
test_unpublishable_metadata_fails_closed
test_unpublishable_metadata_releases_created_resources
