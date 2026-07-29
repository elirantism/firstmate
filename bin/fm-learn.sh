#!/usr/bin/env bash
# fm-learn.sh - read-only learning-session core over the authoritative fleet snapshot.
#
# Usage:
#   fm-learn.sh list [--json]
#   fm-learn.sh start <agent-id> [--json]
#   fm-learn.sh snapshot <agent-id> [--json]
#
# `list` enumerates every direct-report metadata row in the fresh fleet
# snapshot as a learning candidate; `agents` is an accepted alias.
# `start` and `snapshot` expose one selected candidate's bounded context without
# spawning a process, editing task state, or reading the selected worktree;
# `context` is an accepted alias, and the selected id may also be given as
# `--agent <agent-id>`.
# `list --json` emits schema fm-learning-agent-list.v1 and the selected-context
# commands emit fm-learning-session.v1; both are the stable handoff contract for
# a future separate learner process and persistence adapter.
# FM_LEARN_RECORD_LINES bounds each task-record excerpt and defaults to 120
# lines; a non-numeric or zero value falls back to that default.
# docs/learn.md owns the operator-facing contract and its safety boundary.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

FM_LEARN_RECORD_LINES=${FM_LEARN_RECORD_LINES:-120}
case "$FM_LEARN_RECORD_LINES" in
  ''|*[!0-9]*|0) FM_LEARN_RECORD_LINES=120 ;;
esac

usage() {
  cat <<'EOF'
usage: fm-learn.sh list|agents [--json]
       fm-learn.sh start|snapshot|context <agent-id> [--json]

Expose a read-only learning-session view of Firstmate's active agent records.

list prints learning candidates from bin/fm-fleet-snapshot.sh; agents is an
accepted alias.
Every candidate is selectable; active is true only for a record in a known
non-terminal state (working, parked, paused, blocked) with a present endpoint.
start, snapshot, and context are aliases that print the selected agent's
bounded learning context.
--json prints the machine-readable contract: fm-learning-agent-list.v1 for the
candidate list, fm-learning-session.v1 for the selected agent's context.
The selected agent's project files and worktree are never read or changed.
No learner process or persistence adapter is created in this slice.
--agent <agent-id> is accepted as an alternate selection spelling.
FM_LEARN_RECORD_LINES bounds task-record content and defaults to 120 lines.
EOF
}

command -v jq >/dev/null 2>&1 || {
  echo "fm-learn: jq not found" >&2
  exit 1
}

COMMAND=
ID=
JSON=0
POSITIONAL=()
while [ "$#" -gt 0 ]; do
  arg=$1
  shift
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --json) JSON=1 ;;
    --agent)
      [ "$#" -gt 0 ] || { echo "fm-learn: --agent requires a value" >&2; exit 2; }
      POSITIONAL+=("$1")
      shift
      ;;
    --agent=*) POSITIONAL+=("${arg#--agent=}") ;;
    list|agents)
      [ -z "$COMMAND" ] || { echo "fm-learn: more than one command" >&2; exit 2; }
      COMMAND=list
      ;;
    start|snapshot|context)
      [ -z "$COMMAND" ] || { echo "fm-learn: more than one command" >&2; exit 2; }
      COMMAND=$arg
      ;;
    *) POSITIONAL+=("$arg") ;;
  esac
done

if [ "${#POSITIONAL[@]}" -gt 1 ]; then
  echo "fm-learn: expected one agent id" >&2
  exit 2
fi
if [ "${#POSITIONAL[@]}" -eq 1 ]; then
  ID=${POSITIONAL[0]}
fi
COMMAND=${COMMAND:-list}
case "$COMMAND" in
  list)
    [ -z "$ID" ] || { echo "fm-learn: list does not take an agent id" >&2; exit 2; }
    ;;
  start|snapshot|context)
    [ -n "$ID" ] || { echo "fm-learn: $COMMAND requires an agent id" >&2; exit 2; }
    ;;
  *)
    echo "fm-learn: unknown command '$COMMAND'" >&2
    exit 2
    ;;
esac

# Keep the task id path-safe before constructing any task-record path.
case "$ID" in
  .*|*[!A-Za-z0-9._-]*)
    [ -z "$ID" ] || { echo "fm-learn: invalid agent id" >&2; exit 2; }
    ;;
esac
if [ "${#ID}" -gt 64 ]; then
  echo "fm-learn: invalid agent id" >&2
  exit 2
fi

SNAPSHOT=$(FM_ROOT_OVERRIDE="$FM_ROOT" \
  FM_HOME="$FM_HOME" \
  FM_STATE_OVERRIDE="$STATE" \
  FM_DATA_OVERRIDE="$DATA" \
  "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || {
  echo "fm-learn: could not read the authoritative fleet snapshot" >&2
  exit 1
}

list_json() {
  # Every task metadata row is listed as a selectable learning candidate. active
  # is derived from the authoritative current state and endpoint presence, and is
  # claimed only for a KNOWN non-terminal state with a present endpoint. A
  # terminal (done/failed) record, an unestablished (unknown) state, or an absent
  # or unrecorded endpoint stays selectable for learning but is not active.
  printf '%s\n' "$SNAPSHOT" | jq '
    {
      schema:"fm-learning-agent-list.v1",
      generated:.generated,
      read_only:true,
      agents:[
        .tasks[]
        | {
            id,
            active:(
              (.current_state.state // "") as $state
              | (["working","parked","paused","blocked"] | index($state) != null)
                and (.endpoint.exists == true)
            ),
            kind,
            project,
            repo:(.backlog.repo // null),
            harness,
            backend,
            current_state,
            endpoint,
            worktree:{path:(.paths.worktree.path // null),present:.paths.worktree.present},
            task:(.backlog.title // null)
          }
      ] | sort_by(.id)
    }
  '
}

record_json() {  # <name> <path>
  local name=$1 path=$2 present=0 truncated=false bytes=0 lines=0 content=
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    present=1
    bytes=$(wc -c < "$path" | tr -d '[:space:]')
    lines=$(awk 'END { print NR + 0 }' "$path")
    content=$(awk -v max="$FM_LEARN_RECORD_LINES" 'NR <= max { print }' "$path")
    if [ "$lines" -gt "$FM_LEARN_RECORD_LINES" ]; then
      truncated=true
    fi
  fi
  local present_json=false
  [ "$present" -eq 1 ] && present_json=true
  jq -n \
    --arg name "$name" \
    --arg path "$path" \
    --arg content "$content" \
    --argjson present "$present_json" \
    --argjson truncated "$truncated" \
    --argjson bytes "${bytes:-0}" \
    --argjson lines "${lines:-0}" \
    '{name:$name,path:$path,present:$present,truncated:$truncated,bytes:$bytes,lines:$lines,content:(if $present then $content else null end)}'
}

if [ "$COMMAND" = list ]; then
  if [ "$JSON" -eq 1 ]; then
    list_json
    exit 0
  fi
  printf 'Learning candidates (read-only)\n\n'
  printf '%s\n' "$SNAPSHOT" | jq -r '
    if (.tasks | length) == 0 then
      "No active First Mate agents found."
    else
      (.tasks | to_entries[]
       | "\(.key + 1). \(.value.id) [\(.value.kind)] - \(.value.backlog.repo // .value.project // "unknown project") - state \(.value.current_state.state) / \(.value.current_state.source) - \(.value.harness // "unknown harness") / \(.value.backend) - endpoint "
         + (if .value.endpoint.exists == true then "present" elif .value.endpoint.exists == false then "absent" else "unknown" end))
    end
  '
  exit 0
fi

SELECTED=$(printf '%s\n' "$SNAPSHOT" | jq -c --arg id "$ID" '[.tasks[] | select(.id == $id)][0] // empty')
if [ -z "$SELECTED" ]; then
  echo "fm-learn: no active agent record for '$ID'" >&2
  exit 1
fi

BACKLOG=$(printf '%s\n' "$SELECTED" | jq -c '.backlog // null')
META_RECORD=$(record_json metadata "$STATE/$ID.meta")
BRIEF_RECORD=$(record_json brief "$DATA/$ID/brief.md")
STATUS_RECORD=$(record_json status_log "$STATE/$ID.status")
REPORT_RECORD=$(record_json report "$DATA/$ID/report.md")
SESSION=$(jq -n \
  --arg generated "$(printf '%s\n' "$SNAPSHOT" | jq -r '.generated')" \
  --arg selected_id "$ID" \
  --argjson fleet_snapshot "$SNAPSHOT" \
  --argjson selected_agent "$SELECTED" \
  --argjson backlog "$BACKLOG" \
  --argjson metadata "$META_RECORD" \
  --argjson brief "$BRIEF_RECORD" \
  --argjson status_log "$STATUS_RECORD" \
  --argjson report "$REPORT_RECORD" \
  '{
    schema:"fm-learning-session.v1",
    generated:$generated,
    selected_id:$selected_id,
    selected_agent:$selected_agent,
    context:{
      fleet_snapshot:$fleet_snapshot,
      task_records:{backlog:$backlog,metadata:$metadata,brief:$brief,status_log:$status_log,report:$report}
    },
    learner:{
      delivery:"inline",
      process:"current-firstmate",
      separate_process:false,
      future_process_seam:"consume this context contract in a separate learner process",
      persistence:"none",
      future_persistence_seam:"Obsidian adapter"
    },
    boundary:{
      read_only:true,
      project_files_read:false,
      selected_worktree_read:false,
      task_lifecycle_unchanged:true,
      spawned_agent:false
    }
  }')

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$SESSION" | jq .
  exit 0
fi

printf '%s\n' "$SESSION" | jq -r '
  "Learning session (read-only)",
  "Selected agent: \(.selected_agent.id) [\(.selected_agent.kind)]",
  "Project: \(.selected_agent.backlog.repo // .selected_agent.project // "unknown project")",
  "Current state: \(.selected_agent.current_state.state) / \(.selected_agent.current_state.source)",
  "Harness and backend: \(.selected_agent.harness // "unknown harness") / \(.selected_agent.backend)",
  "Worktree content: not read",
  "Learner process: current Firstmate; separate-process seam is reserved",
  "Persistence: none; Obsidian is not integrated",
  "",
  "Task brief:",
  (if .context.task_records.brief.present then .context.task_records.brief.content else "(absent)" end),
  "",
  "Recent task events:",
  (if .context.task_records.status_log.present then .context.task_records.status_log.content else "(absent)" end)
'
