#!/usr/bin/env bash
# Behavior tests for the harness-independent read-only learning-session core.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-learn)
LEARN="$ROOT/bin/fm-learn.sh"

make_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

make_home() {
  local home=$1
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' "$home"
}

run_learn() {
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" "$LEARN" "$@"
}

test_empty_list_is_explicit() {
  local home fakebin out
  home=$(make_home "$TMP_ROOT/empty")
  fakebin=$(make_fakebin "$home")
  out=$(run_learn "$home" "$fakebin" list --json)
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-learning-agent-list.v1"
      and .read_only == true
      and (.agents | length) == 0
  ' >/dev/null || fail "empty learning list was not explicit: $out"
  pass "learning list reports an explicit empty active-agent set"
}

write_agent_fixture() {
  local home=$1 worktree="$1/projects/agent-worktree"
  mkdir -p "$home/data/learn-agent" "$worktree"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] learn-agent - Improve the login flow (repo: alpha) (kind: ship) (since 2026-07-28)

## Queued

## Done
EOF
  cat > "$home/state/learn-agent.meta" <<EOF
window=firstmate:fm-learn-agent
worktree=$worktree
project=alpha
harness=codex
kind=ship
mode=ship
yolo=off
EOF
  printf 'working: implementing login flow\n' > "$home/state/learn-agent.status"
  cat > "$home/data/learn-agent/brief.md" <<'EOF'
# Learning fixture

Acceptance criteria: understand the login flow without changing it.
EOF
  printf 'private worktree content that must not be read\n' > "$worktree/README.md"
}

test_list_enumerates_snapshot_agents() {
  local home fakebin out
  home=$(make_home "$TMP_ROOT/list")
  write_agent_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(run_learn "$home" "$fakebin" list --json)
  printf '%s\n' "$out" | jq -e '
    .agents == [
      (.agents[0]
       | select(.id == "learn-agent")
       | select(.active == true)
       | select(.kind == "ship")
       | select(.project == "alpha")
       | select(.backend == "tmux")
       | select(.current_state.state == "working")
       | select(.endpoint.exists == true))
    ]
  ' >/dev/null || fail "learning list did not expose the authoritative task row: $out"
  pass "learning list enumerates active agents from the fleet snapshot"
}

test_start_is_read_only_and_contains_bounded_context() {
  local home fakebin out before_meta before_status before_brief before_worktree
  home=$(make_home "$TMP_ROOT/start")
  write_agent_fixture "$home"
  fakebin=$(make_fakebin "$home")
  before_meta=$(shasum -a 256 "$home/state/learn-agent.meta")
  before_status=$(shasum -a 256 "$home/state/learn-agent.status")
  before_brief=$(shasum -a 256 "$home/data/learn-agent/brief.md")
  before_worktree=$(shasum -a 256 "$home/projects/agent-worktree/README.md")

  out=$(run_learn "$home" "$fakebin" start learn-agent --json)
  printf '%s\n' "$out" | jq -e '
    .schema == "fm-learning-session.v1"
      and .selected_id == "learn-agent"
      and .selected_agent.id == "learn-agent"
      and .context.fleet_snapshot.schema == "fm-fleet-snapshot.v1"
      and .context.task_records.backlog.id == "learn-agent"
      and .context.task_records.brief.present == true
      and (.context.task_records.brief.content | contains("understand the login flow"))
      and .context.task_records.status_log.present == true
      and .learner.delivery == "inline"
      and .learner.separate_process == false
      and .learner.persistence == "none"
      and .boundary.read_only == true
      and .boundary.project_files_read == false
      and .boundary.selected_worktree_read == false
      and .boundary.task_lifecycle_unchanged == true
      and .boundary.spawned_agent == false
  ' >/dev/null || fail "learning session context or boundary contract was wrong: $out"
  assert_not_contains "$out" "private worktree content that must not be read" \
    "learning session read selected worktree content"

  [ "$(shasum -a 256 "$home/state/learn-agent.meta")" = "$before_meta" ] \
    || fail "learning session changed task metadata"
  [ "$(shasum -a 256 "$home/state/learn-agent.status")" = "$before_status" ] \
    || fail "learning session changed task status events"
  [ "$(shasum -a 256 "$home/data/learn-agent/brief.md")" = "$before_brief" ] \
    || fail "learning session changed task brief"
  [ "$(shasum -a 256 "$home/projects/agent-worktree/README.md")" = "$before_worktree" ] \
    || fail "learning session changed the selected worktree"
  pass "selected learning context is bounded, read-only, and does not read worktree content"
}

test_snapshot_alias_and_invalid_selection() {
  local home fakebin out status
  home=$(make_home "$TMP_ROOT/selection")
  write_agent_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(run_learn "$home" "$fakebin" snapshot learn-agent)
  assert_contains "$out" "Learning session (read-only)" "snapshot alias did not expose a learning session"
  assert_contains "$out" "Learner process: current Firstmate" "human learning session omitted the process seam"
  assert_contains "$out" "Persistence: none; Obsidian is not integrated" \
    "human learning session omitted the persistence seam"

  out=$(run_learn "$home" "$fakebin" start missing-agent 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "missing agent selection should fail"
  assert_contains "$out" "no active agent record" "missing selection error was unclear"

  out=$(run_learn "$home" "$fakebin" start ../outside 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "path traversal agent id should fail"
  assert_contains "$out" "invalid agent id" "unsafe agent id was not refused"
  pass "learning selection aliases and path-safe errors are covered"
}

test_adapter_seam_is_shared_by_pi_and_claude() {
  local skill
  skill="$ROOT/.agents/skills/learn/SKILL.md"
  assert_present "$skill" "learn skill is missing"
  assert_grep "user-invocable: true" "$skill" "learn skill is not user invocable"
  assert_grep "bin/fm-learn.sh list" "$skill" "learn skill does not use the shared list core"
  assert_grep "bin/fm-learn.sh start <agent-id>" "$skill" "learn skill does not use the shared start core"
  assert_grep 'Claude discovers this skill through `.claude/skills`' "$skill" \
    "learn skill does not document the Claude adapter seam"
  assert_grep "Pi discovers the same skill directory" "$skill" \
    "learn skill does not document the Pi adapter seam"
  [ "$(readlink "$ROOT/.claude/skills")" = "../.agents/skills" ] \
    || fail "Claude skill directory is not the shared agent skill directory"
  pass "Pi and Claude share the tested skill entry point without harness-specific spawning"
}

test_empty_list_is_explicit
test_list_enumerates_snapshot_agents
test_start_is_read_only_and_contains_bounded_context
test_snapshot_alias_and_invalid_selection
test_adapter_seam_is_shared_by_pi_and_claude
