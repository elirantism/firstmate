#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
# A second private socket hosting the client that ATTACHES to $SOCKET, so the
# attached-session resolution can be exercised against a real client.
VIEW_SOCKET="fm-backend-smoke-view-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$VIEW_SOCKET" kill-server >/dev/null 2>&1 || true
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- primary-session resolution ----------------------------------------------
# The task window is created in the captain's CURRENT session. Resolution:
# $TMUX-set -> own #S; else the most-recently-active attached client's session;
# else a dedicated detached "firstmate" fallback.

# Selection + attached-session logic is exercised with a shell-function tmux
# that shadows the PATH shim, so multi-client ordering and spaced session names
# are deterministic without needing a real attached client (which needs a tty).
# Each override lives inside a command substitution that yields only the
# resolved value: the shadowing stays scoped, the assertion runs at top level so
# a wrong result aborts the whole suite, and the PATH shim is never torn down
# mid-run (a `fail` from a subshell would rm -rf it and drop the remaining real
# tmux calls onto the host's default socket).
got=$(
  # shellcheck disable=SC2329 # invoked indirectly by the sourced fm_backend_tmux_* function.
  tmux() { [ "$1" = list-clients ] && printf '100 session-a\n300 team work\n200 session-b\n'; return 0; }
  fm_backend_tmux_primary_session
)
[ "$got" = "team work" ] || fail "primary_session must pick the most-recently-active client's session (spaces intact), got '$got'"
got=$(
  export TMUX="fake,1,0"
  # shellcheck disable=SC2329 # invoked indirectly by the sourced fm_backend_tmux_* function.
  tmux() { [ "$1" = display-message ] && printf 'own-session\n'; return 0; }
  fm_backend_tmux_container_ensure
)
[ "$got" = own-session ] || fail "container_ensure with \$TMUX set must return its own #S, got '$got'"
got=$(
  unset TMUX TMUX_PANE
  # shellcheck disable=SC2329 # invoked indirectly by the sourced fm_backend_tmux_* function.
  tmux() { [ "$1" = list-clients ] && printf '7 lets-learn\n'; return 0; }
  fm_backend_tmux_container_ensure
)
[ "$got" = lets-learn ] || fail "container_ensure with empty \$TMUX must target the attached client's session, got '$got'"
pass "tmux backend: primary-session resolution prefers own #S then the most-recently-active attached client's session"

# Real-server fallback: on this private socket no client is attached, so an
# empty-$TMUX resolution finds no primary session and must fall back to a
# dedicated detached "firstmate" session (deterministic, fail-closed).
tmux kill-session -t firstmate 2>/dev/null || true
# shellcheck disable=SC2016 # $1 expands inside the isolated child shell, not here.
empty_primary=$(env -u TMUX -u TMUX_PANE bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_primary_session' _ "$ROOT")
[ -z "$empty_primary" ] || fail "primary_session must be empty when no client is attached, got '$empty_primary'"
# shellcheck disable=SC2016 # $1 expands inside the isolated child shell, not here.
fallback_session=$(env -u TMUX -u TMUX_PANE bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' _ "$ROOT")
[ "$fallback_session" = firstmate ] || fail "container_ensure must fall back to 'firstmate' with no attached client, got '$fallback_session'"
tmux has-session -t firstmate 2>/dev/null || fail "the fallback must have created the detached 'firstmate' session"
tmux kill-session -t firstmate 2>/dev/null || true
pass "real tmux: with no attached client, primary_session is empty and container_ensure creates the 'firstmate' fallback session"

# Real ATTACHED client - the scenario this resolution order exists for: the
# spawning shell has an empty $TMUX while the captain is attached to a live
# session. The shell-function stubs above cannot cover it, because they assert
# against text the test itself printed; only a real server proves what tmux's
# own `-F` output actually looks like. An attach needs a tty, so the client is
# manufactured by attaching to this private socket from inside a SECOND private
# tmux server. The viewer is sized like the smoke session and killed again at
# the end of the block, so the later capture-bounds assertions still run
# against an unattached session of the original geometry.
"$REAL_TMUX" -L "$VIEW_SOCKET" new-session -d -s viewer -x 200 -y 50 \
  "TERM=xterm-256color '$REAL_TMUX' -L '$SOCKET' attach -t '$SESSION'" \
  || fail "could not start the viewer server that attaches a real client"
attached=
for _ in $(seq 1 100); do
  attached=$(tmux list-clients -F '#{client_session}' 2>/dev/null | head -n1)
  [ -n "$attached" ] && break
  sleep 0.1
done
[ "$attached" = "$SESSION" ] || fail "could not manufacture a real attached client on the smoke socket, got '$attached'"
tmux kill-session -t firstmate 2>/dev/null || true
# shellcheck disable=SC2016 # $1 expands inside the isolated child shell, not here.
live_primary=$(env -u TMUX -u TMUX_PANE bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_primary_session' _ "$ROOT")
[ "$live_primary" = "$SESSION" ] \
  || fail "primary_session must return the real attached client's session name '$SESSION', got '$live_primary'"
# shellcheck disable=SC2016 # $1 expands inside the isolated child shell, not here.
live_session=$(env -u TMUX -u TMUX_PANE bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_tmux_container_ensure' _ "$ROOT")
[ "$live_session" = "$SESSION" ] \
  || fail "container_ensure with empty \$TMUX must target the real attached session '$SESSION', got '$live_session'"
# The resolved name must be a usable target: this is what fm-spawn.sh hands to
# fm_backend_tmux_create_task as "<session>:fm-<id>".
fm_backend_tmux_create_task "$live_session" "fm-smoke-attached" "$HOME" \
  || fail "the resolved attached session '$live_session' is not a usable new-window target"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "fm-smoke-attached" \
  || fail "the task window did not land in the attached session '$SESSION'"
if tmux has-session -t firstmate 2>/dev/null; then
  fail "container_ensure must not create the detached 'firstmate' fallback while a client is attached"
fi
tmux kill-window -t "$SESSION:fm-smoke-attached" 2>/dev/null || true
"$REAL_TMUX" -L "$VIEW_SOCKET" kill-server >/dev/null 2>&1 || true
pass "real tmux: with a real attached client, container_ensure targets that session and the task window lands there"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT
