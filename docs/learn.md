# Read-only learning sessions

`/learn` opens a read-only conversation about one active Firstmate agent.
It is intended for understanding work under way without steering the agent or entering its project files.

## Current slice

`bin/fm-learn.sh list` is the harness-independent candidate enumeration command.
It calls `bin/fm-fleet-snapshot.sh --json`, the authoritative read-only fleet snapshot, and renders each task metadata row as a candidate with its task kind, project, current state, harness, backend, and endpoint availability.
The command does not infer current state from the last status event.
A candidate remains selectable when its endpoint is unavailable so the firstmate can learn from a recorded task that needs recovery.
Selectability is therefore not the same as liveness: the JSON `active` field is derived from the authoritative record rather than asserted, and is true only when the current state is neither `done` nor `failed` and the recorded endpoint is present.
A candidate that is not active is still listed and can still be selected.

`bin/fm-learn.sh start <agent-id>` opens the first learning-session exposure path.
The `snapshot` subcommand is an alias for `start`.
The JSON result has schema `fm-learning-session.v1` and includes the complete fleet snapshot, the selected agent row, its matching backlog record, and bounded metadata, brief, status-event, and report records.
The human result shows the selected task brief and recent task events with the same read-only boundary.
`FM_LEARN_RECORD_LINES` bounds each task-record excerpt and defaults to 120 lines.

The core reads task records under the Firstmate home only.
It does not open project files or selected-agent worktree content, and it never writes any project, task, backlog, status, or learning-session file.
The authoritative fleet snapshot may perform its existing bounded read-only current-state probes before the learning context is assembled.

## Lifecycle and persistence boundary

The current slice keeps the learning conversation inside the running firstmate process.
It does not spawn a learner, create a worker, alter supervision, steer an agent, merge work, or change any task lifecycle state.
It does not implement Obsidian integration or write a learning-session artifact.

The JSON result is the seam for a future separate learner process.
Its `learner` object identifies the current inline delivery, the reserved separate-process seam, and the absent persistence adapter.
If a future learner becomes an agent, it must use the existing isolated spawn lifecycle and the primary session's one-new-agent-per-tmux-window behavior rather than adding pane placement.

## Harness entry points

Claude and Pi share the same `/learn` skill at `.agents/skills/learn/SKILL.md`.
Claude discovers it through the `.claude/skills` symlink, and Pi discovers it through its normal `.agents/skills` loading path.
No harness-specific extension or runtime backend is required for this slice.
