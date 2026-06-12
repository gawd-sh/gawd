#!/usr/bin/env bash
# gawd-port-owner.sh — guarantee exactly one systemd unit owns a given TCP port.
#
# Usage: gawd-port-owner.sh <port> <canonical-unit-name>
#   Scans BOTH system (systemctl) and user (systemctl --user) scopes for any
#   ENABLED or ACTIVE unit (other than <canonical-unit-name>) that actually
#   LISTENS on <port>. Each confirmed conflicting unit is stopped + disabled and
#   the action logged. The canonical unit is left untouched.
#
# This is hardening 1 (one-unit-per-service): it is what would have caught the
# system `llama-server-embed.service` vs the user `embed-server.service`
# collision before either could crashloop 79,635 times (project_dasra_crashloop).
# It MUST be run for EVERY port the daemon owns — both llama-servers (completions
# :11434, embed :11436) and the gateway (:18789) — not just embed. An unguarded
# duplicate on ANY of those ports is a future crashloop.
#
# H2 (2026-05-28): a unit is only a CONFLICT if it actually LISTENS on the port.
# We confirm via `ss -ltnp` and match the listening socket's PID/exe back to the
# unit's MainPID/cgroup — a bare ":PORT" ExecStart text hit matches CLIENTS that
# merely connect to the port and would disable the wrong unit. The text scan is
# only a cheap CANDIDATE prefilter (and now requires the port to be adjacent to a
# --host/--port/listen token); the LISTEN confirmation is authoritative.
#
# H3 (2026-05-28): system-scope stop/disable failures are NO LONGER swallowed by
# `|| true`. If a confirmed SYSTEM-scope conflict cannot be disabled because the
# installer runs unprivileged (the exact system-vs-user 79K-crashloop case), we
# emit a LOUD warning, fire the Prophit alert, and EXIT NON-ZERO so the install
# step fails visibly — "couldn't disable the real conflict" never looks like
# success. (Matches the header promise: fail-loud if it can't act.)
#
# Idempotent: re-running with no conflicts is a clean no-op (exit 0).
# Fail-loud: every disable is echoed to stdout AND the gawd reliability log.
# Exit: 0 = no conflict or all conflicts disabled; 3 = a confirmed conflict could
#       not be disabled (privilege) — install must treat this as failure.
#       (A missing systemctl in the docker rung is a clean no-op, exit 0.)
set -uo pipefail

PORT="${1:?usage: gawd-port-owner.sh <port> <canonical-unit>}"
CANON="${2:?usage: gawd-port-owner.sh <port> <canonical-unit>}"
GAWD_HOME="${GAWD_HOME:-$HOME/.gawd}"
LOG="${GAWD_HOME}/logs/reliability.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true

UNRESOLVED=0   # set to 1 if a confirmed conflict could not be disabled

_say() { printf '[port-owner] %s\n' "$*"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }

command -v systemctl >/dev/null 2>&1 || { _say "no systemctl (docker rung) — port-owner is a no-op for :$PORT"; exit 0; }

# ── set of PIDs that are actually LISTENING on $PORT (authoritative) ──────────
# Returns the listening PIDs (one per line). Empty if nothing listens / no ss.
_listening_pids() {
  command -v ss >/dev/null 2>&1 || return 0
  # -H header off (fallback: strip via grep), -l listen, -t tcp, -n numeric, -p process.
  ss -ltnp 2>/dev/null \
    | awk -v p=":${PORT}\$" '
        NR>1 {
          # field 4 is Local Address:Port
          split($4, a, ":"); lport=a[length(a)]
          if (lport == "'"$PORT"'") print $0
        }' \
    | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# ── does <unit> in <scope> own any of the listening PIDs? ─────────────────────
# Authoritative LISTEN confirmation: match the unit's MainPID OR any pid in its
# cgroup against the set of sockets actually listening on $PORT.
_unit_listens_on_port() {
  local scope_flag="$1" unit="$2"
  local listen_pids; listen_pids="$(_listening_pids)"
  [[ -z "$listen_pids" ]] && return 1   # nothing listens on the port → no conflict

  local mainpid
  mainpid="$(systemctl $scope_flag show "$unit" --property=MainPID --value 2>/dev/null || echo 0)"

  # Collect the unit's process tree PIDs (MainPID + cgroup members).
  local unit_pids=""
  [[ "${mainpid:-0}" -gt 0 ]] 2>/dev/null && unit_pids="$mainpid"
  # cgroup members via systemctl status PID list (best-effort; works user+system).
  local cg_pids
  cg_pids="$(systemctl $scope_flag show "$unit" --property=ControlGroup --value 2>/dev/null || true)"
  if [[ -n "$cg_pids" ]]; then
    local cgfile="/sys/fs/cgroup${cg_pids}/cgroup.procs"
    [[ -r "$cgfile" ]] && unit_pids="${unit_pids} $(tr '\n' ' ' < "$cgfile" 2>/dev/null)"
  fi

  local lp up
  for lp in $listen_pids; do
    for up in $unit_pids; do
      [[ "$lp" == "$up" ]] && return 0
    done
  done
  return 1
}

# ── attempt stop+disable; report whether it actually worked ───────────────────
# Returns 0 if the unit ended up disabled, 1 if a privilege/other failure left it
# enabled. NEVER swallows the result.
_disable_unit() {
  local scope_flag="$1" unit="$2"
  systemctl $scope_flag stop "$unit"    >/dev/null 2>&1 || true
  local disable_rc=0
  systemctl $scope_flag disable "$unit" >/dev/null 2>&1 || disable_rc=$?
  # Confirm by state, not just rc (disable can be deferred/no-op).
  if systemctl $scope_flag is-enabled "$unit" >/dev/null 2>&1; then
    # still enabled → disable did not take effect
    return 1
  fi
  return 0
}

_scan_scope() {
  local scope_flag="$1"   # "" for system, "--user" for user
  local scope_name="${scope_flag:-system}"
  systemctl $scope_flag list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | while read -r unit; do
    [[ -z "$unit" ]] && continue
    [[ "$unit" == "$CANON" ]] && continue
    local execstart
    execstart="$(systemctl $scope_flag show "$unit" --property=ExecStart --value 2>/dev/null || true)"
    # H2: tightened candidate prefilter — the port must be adjacent to a
    # --host/--port/listen token (a bare ":PORT" anywhere matches clients).
    if printf '%s' "$execstart" | grep -Eq -- "(--port[ =]+${PORT}\b|--host[^ ]*[ =]+[^ ]*:${PORT}\b|listen[^ ]*[ =]+[^ ]*:${PORT}\b)"; then
      # H2: authoritative LISTEN confirmation before touching anything.
      if ! _unit_listens_on_port "$scope_flag" "$unit"; then
        _say "candidate ${scope_name}/$unit references :$PORT in ExecStart but does NOT listen on it — leaving untouched (not a conflict)"
        continue
      fi
      _say "CONFLICT: ${scope_name}/$unit LISTENS on :$PORT (canonical=$CANON) — stopping + disabling"
      if _disable_unit "$scope_flag" "$unit"; then
        _say "disabled ${scope_name}/$unit"
      else
        # H3: could not disable. If this is a SYSTEM-scope unit and we are
        # unprivileged, this is the exact crashloop conflict we MUST surface.
        _say "ERROR: could NOT disable ${scope_name}/$unit on :$PORT — it is STILL ENABLED (likely privilege: system-scope unit, unprivileged installer). This is the system-vs-user conflict that caused the 79K crashloop. Resolve manually: sudo systemctl disable --now $unit"
        if [[ -x "${SCRIPT_DIR}/gawd-failure-alert.sh" ]]; then
          GAWD_HOME="$GAWD_HOME" bash "${SCRIPT_DIR}/gawd-failure-alert.sh" "port-conflict:${scope_name}/${unit}:${PORT}" || true
        fi
        # Mark unresolved via a sentinel file (subshell can't set parent vars).
        echo "$unit" >> "${GAWD_HOME}/state/port-owner-unresolved.${PORT}" 2>/dev/null || true
      fi
    fi
  done
}

mkdir -p "${GAWD_HOME}/state" 2>/dev/null || true
rm -f "${GAWD_HOME}/state/port-owner-unresolved.${PORT}" 2>/dev/null || true

_scan_scope ""        # system scope
_scan_scope "--user"  # user scope

# H3: if any confirmed conflict could not be disabled, FAIL the step.
if [[ -s "${GAWD_HOME}/state/port-owner-unresolved.${PORT}" ]]; then
  UNRESOLVED=1
fi

if [[ "$UNRESOLVED" -eq 1 ]]; then
  _say "FAIL: one or more confirmed conflicts on :$PORT could not be disabled — install must NOT treat this as success (exit 3)"
  exit 3
fi

_say "port-owner check complete for :$PORT (canonical=$CANON)"
exit 0
