#!/usr/bin/env bash
# validate-schema.sh — Persona file schema + budget + permission validator
#
# Validates a Gawd's persona file set against the canonical contract defined in
# <install-root>/docs/architecture/persona-file-architecture.md
#
# Checks:
#   1. All required persona files present
#   2. Token budgets within tolerance (per file + total)
#   3. Permission modes correct (T0 anchors chmod 0444; adaptive chmod 0644)
#   4. T0 anchors owned by non-runtime user (different uid from runtime)
#   5. Mandatory sections present in each file
#   6. Movement register present in VOICE.md (with "Gawd-SpreadTheWord" working term)
#
# Usage:
#   ./validate-schema.sh <persona-dir> [--runtime-user <user>] [--strict]
#
# Examples:
#   ./validate-schema.sh /home/gawd/.openclaw/workspace --runtime-user gawd
#   ./validate-schema.sh ./persona-templates --strict
#
# Exit codes:
#   0  all checks pass
#   1  missing file(s) — fatal
#   2  budget violation (over hard ceiling)
#   3  permission violation (T0 anchor writable by runtime)
#   4  schema violation (mandatory section missing)
#   5  movement register missing or wrong working term
#
# --strict mode: warnings become errors. Default: warnings logged, exit 0 if no
# hard errors.

set -euo pipefail

# ── constants ──────────────────────────────────────────────────────────────────

# Token budget targets (per persona-file-architecture.md §4)
# Approximation: 1 token ≈ 4 characters for English prose. This is rough and
# only used for ceiling-check; the audit tool (v1.1 follow-on) will use a real
# tokenizer.
CHARS_PER_TOKEN=4

declare -A BUDGET_TARGETS=(
  ["SOUL.md"]=1200
  ["IDENTITY.md"]=600
  ["VOICE.md"]=600
  ["VOICE-ADAPTIVE.md"]=400
  ["USER.md"]=600
  ["MEMORY.md"]=800
  ["tuning.md"]=400
)

# Tolerance: ±15% per file is "warn"; over hard-ceiling (1.5x target) is "fail"
TOLERANCE_PCT=15
HARD_CEILING_PCT=50

# Total persona budget targets
TOTAL_TARGET_TOKENS=4600
TOTAL_HARD_CEILING_TOKENS=5300  # ~15% over (per spec §3.6 + §4)

# T0 anchors — must be chmod 0444 and owned by non-runtime user
T0_ANCHORS=("SOUL.md" "IDENTITY.md" "VOICE.md")

# Adaptive files — chmod 0644, owned by runtime user
ADAPTIVE_FILES=("VOICE-ADAPTIVE.md" "USER.md" "MEMORY.md" "tuning.md")

# Mandatory section markers per file (regex patterns matched against headers)
declare -A MANDATORY_SECTIONS=(
  ["SOUL.md"]="^## The covenant|^## Voice — base character|^## What I do|^## What I do not do|^## On the Prophit"
  ["IDENTITY.md"]="^## Name|^## Instance|^## Covenant|^## Prophits|^## Voice|^## Infrastructure|^## Pace"
  ["VOICE.md"]="^## Register: default|^## Register: deep|^## Register: playful|^## Register: money|^## Register: movement|^## Register: judgment|^## Register: candor|^## Base behavioral frame"
  ["USER.md"]="^## Who|^## Voice|^## Life|^## Routines"
)

MOVEMENT_TERM="Gawd-SpreadTheWord"

# ── flags / args ───────────────────────────────────────────────────────────────

PERSONA_DIR=""
RUNTIME_USER="${USER}"
STRICT=0
EXIT_CODE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime-user)
      RUNTIME_USER="$2"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      if [[ -z "$PERSONA_DIR" ]]; then
        PERSONA_DIR="$1"
      else
        echo "ERROR: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PERSONA_DIR" ]]; then
  echo "Usage: $0 <persona-dir> [--runtime-user <user>] [--strict]" >&2
  exit 1
fi

if [[ ! -d "$PERSONA_DIR" ]]; then
  echo "ERROR: persona dir does not exist: $PERSONA_DIR" >&2
  exit 1
fi

# ── helpers ────────────────────────────────────────────────────────────────────

log_info()  { echo "INFO  $*"; }
log_warn()  { echo "WARN  $*" >&2; [[ $STRICT -eq 1 ]] && EXIT_CODE=$((EXIT_CODE | 1)) || true; }
log_error() { echo "ERROR $*" >&2; }

estimate_tokens() {
  # Cheap heuristic: char_count / CHARS_PER_TOKEN
  local file="$1"
  local chars
  chars=$(wc -c < "$file" | tr -d '[:space:]')
  echo $(( chars / CHARS_PER_TOKEN ))
}

# ── checks ─────────────────────────────────────────────────────────────────────

check_files_exist() {
  log_info "Check 1: required files present"
  local missing=0
  for f in "${T0_ANCHORS[@]}" "${ADAPTIVE_FILES[@]}"; do
    if [[ ! -f "$PERSONA_DIR/$f" ]]; then
      # USER.md special case: may be users/ directory instead
      if [[ "$f" == "USER.md" && -d "$PERSONA_DIR/users" ]]; then
        log_info "  $f not present — users/ directory present instead (multi-Prophit case)"
        continue
      fi
      log_error "  missing required file: $PERSONA_DIR/$f"
      missing=1
    fi
  done
  if [[ $missing -eq 1 ]]; then
    EXIT_CODE=$((EXIT_CODE | 1))
    return 1
  fi
  log_info "  all required files present"
}

check_token_budgets() {
  log_info "Check 2: token budgets (per file + total)"
  local total_tokens=0
  for f in "${!BUDGET_TARGETS[@]}"; do
    local target=${BUDGET_TARGETS[$f]}
    if [[ -f "$PERSONA_DIR/$f" ]]; then
      local actual
      actual=$(estimate_tokens "$PERSONA_DIR/$f")
      total_tokens=$((total_tokens + actual))
      local tolerance=$(( target * TOLERANCE_PCT / 100 ))
      local ceiling=$(( target * (100 + HARD_CEILING_PCT) / 100 ))
      if [[ $actual -gt $ceiling ]]; then
        log_error "  $f over hard ceiling: $actual tokens (target $target, ceiling $ceiling)"
        EXIT_CODE=$((EXIT_CODE | 2))
      elif [[ $actual -gt $((target + tolerance)) ]]; then
        log_warn "  $f over tolerance: $actual tokens (target $target, tolerance ±$tolerance)"
      else
        log_info "  $f: $actual tokens (target $target ±$tolerance)"
      fi
    fi
  done
  # Add users/ directory token cost if present (multi-Prophit case)
  if [[ -d "$PERSONA_DIR/users" ]]; then
    for uf in "$PERSONA_DIR/users"/*.md; do
      [[ -f "$uf" ]] || continue
      [[ "$(basename "$uf")" == "_TEMPLATE.md" ]] && continue
      local utokens
      utokens=$(estimate_tokens "$uf")
      total_tokens=$((total_tokens + utokens))
      log_info "  users/$(basename "$uf"): $utokens tokens"
    done
  fi
  log_info "  TOTAL: $total_tokens tokens (target $TOTAL_TARGET_TOKENS, hard ceiling $TOTAL_HARD_CEILING_TOKENS)"
  if [[ $total_tokens -gt $TOTAL_HARD_CEILING_TOKENS ]]; then
    log_error "  total persona OVER hard ceiling"
    EXIT_CODE=$((EXIT_CODE | 2))
  fi
}

check_permissions() {
  log_info "Check 3: file permissions"
  local runtime_uid
  if id -u "$RUNTIME_USER" &>/dev/null; then
    runtime_uid=$(id -u "$RUNTIME_USER")
  else
    log_warn "  runtime user '$RUNTIME_USER' does not exist — skipping owner check"
    runtime_uid=""
  fi

  for f in "${T0_ANCHORS[@]}"; do
    local path="$PERSONA_DIR/$f"
    [[ -f "$path" ]] || continue
    local mode owner_uid
    mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%A' "$path")
    owner_uid=$(stat -c '%u' "$path" 2>/dev/null || stat -f '%u' "$path")
    if [[ "$mode" != "444" ]]; then
      log_warn "  T0 anchor $f mode is $mode (expected 444) — A2 setuid integration not yet applied?"
    fi
    if [[ -n "$runtime_uid" && "$owner_uid" == "$runtime_uid" ]]; then
      log_error "  T0 anchor $f is owned by runtime user (uid=$owner_uid) — VIOLATION (spec §3.1)"
      EXIT_CODE=$((EXIT_CODE | 3))
    fi
  done

  for f in "${ADAPTIVE_FILES[@]}"; do
    local path="$PERSONA_DIR/$f"
    [[ -f "$path" ]] || continue
    local mode
    mode=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%A' "$path")
    if [[ "$mode" != "644" ]]; then
      log_warn "  adaptive file $f mode is $mode (expected 644)"
    fi
  done
}

check_mandatory_sections() {
  log_info "Check 4: mandatory sections per file"
  for f in "${!MANDATORY_SECTIONS[@]}"; do
    local path="$PERSONA_DIR/$f"
    [[ -f "$path" ]] || continue
    local pattern="${MANDATORY_SECTIONS[$f]}"
    # Split pattern by | and check each
    IFS='|' read -ra sections <<< "$pattern"
    local missing_sections=()
    for section in "${sections[@]}"; do
      if ! grep -qE "$section" "$path"; then
        missing_sections+=("$section")
      fi
    done
    if [[ ${#missing_sections[@]} -gt 0 ]]; then
      log_error "  $f missing mandatory sections:"
      for s in "${missing_sections[@]}"; do
        log_error "    $s"
      done
      EXIT_CODE=$((EXIT_CODE | 4))
    else
      log_info "  $f: all mandatory sections present"
    fi
  done
}

check_movement_register() {
  log_info "Check 5: VOICE.md movement register"
  local path="$PERSONA_DIR/VOICE.md"
  [[ -f "$path" ]] || { log_warn "  VOICE.md not present — skipping"; return; }

  if ! grep -qE "^## Register: movement" "$path"; then
    log_error "  VOICE.md missing 'Register: movement' section"
    EXIT_CODE=$((EXIT_CODE | 5))
    return
  fi

  if ! grep -q "$MOVEMENT_TERM" "$path"; then
    log_warn "  VOICE.md movement register present but does NOT contain working term '$MOVEMENT_TERM' — has §17.1 movement-naming resolved?"
  else
    log_info "  VOICE.md movement register includes working term '$MOVEMENT_TERM'"
  fi
}

# ── main ───────────────────────────────────────────────────────────────────────

log_info "Validating persona dir: $PERSONA_DIR"
log_info "Runtime user (for owner checks): $RUNTIME_USER"
log_info "Strict mode: $STRICT"
echo ""

check_files_exist || exit 1
echo ""
check_token_budgets
echo ""
check_permissions
echo ""
check_mandatory_sections
echo ""
check_movement_register
echo ""

if [[ $EXIT_CODE -eq 0 ]]; then
  log_info "ALL CHECKS PASSED"
else
  log_error "FAILED with exit code $EXIT_CODE (bitmask: 1=missing 2=budget 3=permission 4=schema 5=movement-register)"
fi

exit $EXIT_CODE
