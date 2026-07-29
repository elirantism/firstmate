---
name: learn
description: Open a read-only learning session for one active Firstmate agent. Use when the captain invokes /learn or asks to learn from, inspect, understand, or study an active agent's work without changing it.
user-invocable: true
metadata:
  internal: true
---

# learn

`/learn` is a read-only context exposure path, not a second task lifecycle.
It uses the shared `bin/fm-learn.sh` core, so Claude and Pi use the same adapter seam.

## Procedure

1. Run `bin/fm-learn.sh list`.
2. Present the numbered learning candidates with their id, task kind, current state, project, harness, backend, and endpoint availability.
3. If there are no candidates, say that no First Mate agent records are available and stop.
4. If the captain did not identify one agent, ask them to choose an id before opening context.
5. Run `bin/fm-learn.sh start <agent-id>` for the selected candidate.
6. Use the returned task brief, bounded status events, backlog record, and fleet snapshot to explain the selected agent's work.

The command reads the authoritative fleet snapshot and task records only.
It never reads or edits project files or the selected agent's worktree.
It does not dispatch, steer, merge, tear down, alter the backlog, or change any task lifecycle state.
The current learning conversation stays in the firstmate process.
The session JSON is the seam for a future separate learner process and future Obsidian persistence, neither of which is implemented here.
If a future learner becomes an agent, it must use the normal isolated spawn path and the primary session's one-window-per-agent behavior rather than introducing pane placement.

## Adapter boundary

Claude discovers this skill through `.claude/skills`, which points to `.agents/skills`.
Pi discovers the same skill directory through its normal `.agents/skills` loading path.
No harness-specific extension or pane command is needed for this slice.
