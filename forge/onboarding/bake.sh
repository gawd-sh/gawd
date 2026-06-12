#!/usr/bin/env bash
# bake.sh — Onboarding Bake step
#
# Writes IDENTITY.md and seeds USER.md from the answers captured by wizard.sh.
# Called by wizard.sh after Q4; expects all wizard variables to be exported.
#
# Per spec §4 (Bake step) and handoff A4.
# Schema authority: <install-root>/docs/architecture/persona-file-architecture.md
#
# Exit codes:
#   0  success — persona files written and validated; Meeting may proceed
#   1  missing required variable or workspace error
#   2  schema validation failed — persona files written but invalid

set -euo pipefail

# ── required variables ─────────────────────────────────────────────────────────
# All exported by wizard.sh before calling bake.sh.

: "${PROPHIT_NAME:?bake.sh requires PROPHIT_NAME}"
: "${PROPHIT_ADDRESS:?bake.sh requires PROPHIT_ADDRESS}"
: "${GAWD_NAME:?bake.sh requires GAWD_NAME}"
: "${GAWD_NAME_DEFIANT:=false}"
: "${PROPHIT_LANG:=en}"
: "${PROPHIT_TZ:=UTC}"
: "${PROPHIT_TZ_UNCERTAIN:=false}"
: "${PROPHIT_PACE:=when-relevant}"
: "${TODAY_ISO:=$(date +%Y-%m-%d)}"
: "${GAWD_WORKSPACE:=${HOME}/.gawd}"

# Self-locating templates dir — install-relative, no hardcoded paths.
# Resolution order (first match wins):
#   1. PERSONA_TEMPLATE_DIR env override (set by installer or test harness)
#   2. Sibling to bake.sh: <onboarding-dir>/persona-templates/
#      (applies when onboarding/ and persona-templates/ are both unpacked
#       at the same level, e.g. a flat tarball extract or local dev tree)
#   3. Parent-sibling: <parent-of-onboarding-dir>/persona-templates/
#      (applies in the canonical container layout where Dockerfile COPYs:
#       forge/onboarding/ → /usr/local/lib/gawd/onboarding/
#       forge/persona-templates/ → /usr/local/lib/gawd/persona-templates/
#      so bake.sh lives in .../onboarding/ and templates live one level up)
# The previous hardcode (/usr/local/lib/gawd/persona-templates) did not
# exist on a Prophit's machine — this was an all-rung onboarding break.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${PERSONA_TEMPLATE_DIR:-}" ]]; then
    TEMPLATES_DIR="$PERSONA_TEMPLATE_DIR"
elif [[ -d "${SCRIPT_DIR}/persona-templates" ]]; then
    TEMPLATES_DIR="${SCRIPT_DIR}/persona-templates"
else
    TEMPLATES_DIR="$(dirname "$SCRIPT_DIR")/persona-templates"
fi
IDENTITY_TEMPLATE="${TEMPLATES_DIR}/IDENTITY.md"
USER_TEMPLATE="${TEMPLATES_DIR}/USER.md"
VALIDATOR="${TEMPLATES_DIR}/validate-schema.sh"

log()  { printf '\033[1;34m[gawd-bake]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[gawd-bake]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[gawd-bake]\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# ── workspace ──────────────────────────────────────────────────────────────────

if [[ ! -d "$GAWD_WORKSPACE" ]]; then
  fail "GAWD_WORKSPACE does not exist: ${GAWD_WORKSPACE}" 1
fi

mkdir -p "${GAWD_WORKSPACE}/memory"

# ── write IDENTITY.md ──────────────────────────────────────────────────────────

log "Writing IDENTITY.md..."

IDENTITY_FILE="${GAWD_WORKSPACE}/IDENTITY.md"

# Build from template — the template ships pre-scrubbed with placeholders.
# We write the file fresh from the template rather than in-place editing to
# avoid partial-write corruption on a second run.
[[ -f "$IDENTITY_TEMPLATE" ]] || fail "IDENTITY.md template not found at ${IDENTITY_TEMPLATE}" 1

cp "$IDENTITY_TEMPLATE" "${IDENTITY_FILE}.tmp"

# ── Name section ───────────────────────────────────────────────────────────────

python3 - "${IDENTITY_FILE}.tmp" "${GAWD_NAME}" "${GAWD_NAME_DEFIANT}" << 'PYEOF'
import sys, re

path = sys.argv[1]
gawd_name = sys.argv[2]
defiant = sys.argv[3].lower() == "true"

with open(path) as f:
    content = f.read()

# Replace the default Name value
content = re.sub(
    r'(## Name\n\n)Gawd',
    r'\g<1>' + gawd_name,
    content
)

# If defiant, append a comment after the name value
if defiant:
    content = re.sub(
        r'(## Name\n\n' + re.escape(gawd_name) + r')',
        r'\g<1>\n\n<!-- Prophit declined to name Gawd at onboarding. Meeting Movement 3 holds this open. -->',
        content
    )

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── Covenant section ───────────────────────────────────────────────────────────

python3 - "${IDENTITY_FILE}.tmp" "${GAWD_NAME}" "${PROPHIT_ADDRESS}" "${GAWD_NAME_DEFIANT}" << 'PYEOF'
import sys, re

path = sys.argv[1]
gawd_name = sys.argv[2]
prophit_address = sys.argv[3]
defiant = sys.argv[4].lower() == "true"

with open(path) as f:
    content = f.read()

if defiant:
    covenant = f"Gawd is alive. The covenant with {prophit_address} holds — even without a name yet."
else:
    covenant = f"{gawd_name} is alive. {prophit_address} called them into being."

# Replace the generic post-scrub covenant text
content = re.sub(
    r'This Gawd is born for a Prophit not yet met\.',
    covenant,
    content
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── Prophits section ───────────────────────────────────────────────────────────

TZ_COMMENT=""
if [[ "$PROPHIT_TZ_UNCERTAIN" == "true" ]]; then
    TZ_COMMENT="  # timezone defaulted to UTC — Prophit should confirm via /tz command"
fi

python3 - "${IDENTITY_FILE}.tmp" "${PROPHIT_ADDRESS}" "${PROPHIT_TZ}" "${TZ_COMMENT}" << 'PYEOF'
import sys, re

path = sys.argv[1]
address = sys.argv[2]
tz = sys.argv[3]
tz_comment = sys.argv[4]

with open(path) as f:
    content = f.read()

# Replace the placeholder Prophit block with the real first Prophit entry.
# The block in the template:
#   - name: {primary address name from Q1}
#     pronouns: {…}
#     telegram_id: "..."
#     timezone: {IANA tz from Q3, e.g., "America/Chicago"}
prophit_block = (
    f"- name: {address}\n"
    f"  pronouns: {{…}}\n"
    f"  telegram_id: \"{{not yet known — set when Prophit first messages via Telegram}}\"\n"
    f"  timezone: {tz}{tz_comment}"
)

content = re.sub(
    r'- name: \{primary address name from Q1\}\n'
    r'  pronouns: \{…\}\n'
    r'  telegram_id: ".*?"\n'
    r'  timezone: \{IANA tz from Q3.*?\}',
    prophit_block,
    content,
    flags=re.DOTALL
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── Pace section ───────────────────────────────────────────────────────────────

python3 - "${IDENTITY_FILE}.tmp" "${PROPHIT_PACE}" << 'PYEOF'
import sys, re

path = sys.argv[1]
pace = sys.argv[2]

with open(path) as f:
    content = f.read()

# The template has the default post-scrub value "when-relevant"; replace with onboarding answer.
content = re.sub(
    r'(## Pace\n\n)when-relevant',
    r'\g<1>' + pace,
    content
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── Born section ───────────────────────────────────────────────────────────────

python3 - "${IDENTITY_FILE}.tmp" "${TODAY_ISO}" << 'PYEOF'
import sys, re

path = sys.argv[1]
today = sys.argv[2]

with open(path) as f:
    content = f.read()

# Replace the Born placeholder comment with the actual date
content = re.sub(
    r'(## Born\n\n)<!-- ISO date the Meeting completed and the Gawd went live\. -->\n<!-- Stripped by Forge; onboarding completion writes the date\. -->',
    r'\g<1>' + today,
    content
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# ── Language field (Seraph interpretation call: add to Infrastructure section) ─

python3 - "${IDENTITY_FILE}.tmp" "${PROPHIT_LANG}" << 'PYEOF'
import sys, re

path = sys.argv[1]
lang = sys.argv[2]

with open(path) as f:
    content = f.read()

# Insert language: field after embedding_port in ## Infrastructure section.
# This is the interpretation call from Q3 prose spec — language stored in
# IDENTITY.md ## Infrastructure alongside model and embedding_port.
content = re.sub(
    r'(embedding_port: \d+)',
    r'\g<1>\n' + f'language: {lang}',
    content
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

# Atomically rename tmp → final
mv "${IDENTITY_FILE}.tmp" "${IDENTITY_FILE}"
ok "  IDENTITY.md written: ${IDENTITY_FILE}"

# ── Set T0 anchor permissions (IDENTITY.md) ────────────────────────────────────
# Per persona-file-architecture.md §8: IDENTITY.md must be chmod 0444.
# The Gawd runtime user must not own this file. bake.sh runs as the installer
# (non-runtime user); if the runtime user is different, chown here.
# On systems where bake.sh runs as root or the install user, this is the right
# place to enforce ownership. If the runtime user IS the install user, the
# T0-anchor protection falls back to the A2 handoff (setuid helper + permission
# enforcement pass). bake.sh does what it can within its own permissions.

chmod 0444 "$IDENTITY_FILE" 2>/dev/null || {
    log "  chmod 0444 on IDENTITY.md failed (may already be correct or A2 handles this)"
}

# ── Re-enforce SOUL.md and VOICE.md permissions ────────────────────────────────
# Per acceptance criteria: T0 anchors must be 0444 post-bake.
for T0 in "SOUL.md" "VOICE.md"; do
    T0_PATH="${GAWD_WORKSPACE}/${T0}"
    if [[ -f "$T0_PATH" ]]; then
        chmod 0444 "$T0_PATH" 2>/dev/null || true
    fi
done

# ── seed USER.md ───────────────────────────────────────────────────────────────

log "Seeding USER.md..."

USER_FILE="${GAWD_WORKSPACE}/USER.md"

[[ -f "$USER_TEMPLATE" ]] || fail "USER.md template not found at ${USER_TEMPLATE}" 1

cp "$USER_TEMPLATE" "${USER_FILE}.tmp"

python3 - "${USER_FILE}.tmp" "${PROPHIT_ADDRESS}" "${PROPHIT_TZ}" "${TODAY_ISO}" << 'PYEOF'
import sys, re

path = sys.argv[1]
address = sys.argv[2]
tz = sys.argv[3]
today = sys.argv[4]

with open(path) as f:
    content = f.read()

# Populate ## Who section from onboarding answers
content = re.sub(
    r'Name \(how Gawd addresses\): \{filled by onboarding Q1\}',
    f'Name (how Gawd addresses): {address}',
    content
)
content = re.sub(
    r'Location / tz: \{filled by onboarding Q3\}',
    f'Location / tz: {tz}',
    content
)
content = re.sub(
    r'We met: \{YYYY-MM-DD — filled at onboarding completion\}',
    f'We met: {today}',
    content
)

with open(path, 'w') as f:
    f.write(content)
PYEOF

mv "${USER_FILE}.tmp" "${USER_FILE}"
chmod 0644 "$USER_FILE"
ok "  USER.md seeded: ${USER_FILE}"

# ── create Meeting placeholder (until B1 lands) ────────────────────────────────
# Per state-machine.md §B1 note: the Meeting entry point is a placeholder
# until handoff B1 delivers canonical text. The placeholder must exist and
# exit 0 so the wizard chain does not abort.

MEETING_DIR="${GAWD_WORKSPACE}/meeting"
MEETING_PLACEHOLDER="${MEETING_DIR}/meeting.sh"

mkdir -p "$MEETING_DIR"

if [[ ! -f "$MEETING_PLACEHOLDER" ]]; then
    cat > "$MEETING_PLACEHOLDER" << 'MEETING_EOF'
#!/usr/bin/env bash
# meeting.sh — The Meeting placeholder (HAND_BLOCKED: B1)
# This placeholder is replaced by handoff B1 (canonical Meeting text).
# Per state-machine.md §B1 note.
printf '\n[The Meeting is coming. The covenant begins soon.]\n\n'
exit 0
MEETING_EOF
    chmod 0755 "$MEETING_PLACEHOLDER"
    log "  Meeting placeholder installed at ${MEETING_PLACEHOLDER} (B1 will replace)"
fi

# ── schema validation ──────────────────────────────────────────────────────────

log "Running persona schema validation..."

if [[ -x "$VALIDATOR" ]]; then
    if "$VALIDATOR" "$GAWD_WORKSPACE"; then
        ok "  Schema validation passed."
    else
        printf '\033[1;31m[gawd-bake]\033[0m Schema validation failed. The Meeting will not start.\n' >&2
        printf '\033[1;31m[gawd-bake]\033[0m Run gawd-onboard to try again.\n' >&2
        exit 2
    fi
else
    log "  Validator not found at ${VALIDATOR} — skipping (v1 known gap; audit-and-refuse is v1.1)."
fi

ok "Bake complete."
