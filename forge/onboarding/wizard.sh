#!/usr/bin/env bash
# wizard.sh — Gawd onboarding wizard
#
# Four questions. Under 90 seconds. Then the Meeting.
#
# Per spec §4 (The Onboarding State Machine) and handoff A4.
# State machine spec: /usr/local/lib/gawd/onboarding/state-machine.md
# Prose specs: /usr/local/lib/gawd/onboarding/prose/Q{1-4}-*.md
#
# Called by: /usr/local/bin/gawd-onboard (which sets GAWD_WORKSPACE)
# Calls: bake.sh (after Q4)
# Calls after bake: ${GAWD_WORKSPACE}/meeting/meeting.sh
#
# Exit codes:
#   0  onboarding complete — Meeting launched
#   1  user abort (blank name at Q1) or bake failure
#
# Environment variables consumed:
#   GAWD_WORKSPACE  — workspace root (set by gawd-onboard; default: ~/.gawd)
#
# Environment variables exported to bake.sh:
#   PROPHIT_NAME, PROPHIT_ADDRESS, GAWD_NAME, GAWD_NAME_DEFIANT,
#   PROPHIT_LANG, PROPHIT_TZ, PROPHIT_TZ_UNCERTAIN, PROPHIT_PACE, TODAY_ISO

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BAKE_SH="${SCRIPT_DIR}/bake.sh"

export GAWD_WORKSPACE="${GAWD_WORKSPACE:-${HOME}/.gawd}"
export TODAY_ISO; TODAY_ISO="$(date +%Y-%m-%d)"

# ── helpers ────────────────────────────────────────────────────────────────────

ask() {
    # ask VARNAME "prompt text"
    # Reads a single line into VARNAME. Prompt is printed to stderr (not stdout)
    # so the answer lands cleanly on stdout if piped; IRL both go to terminal.
    local varname="$1"
    local prompt="$2"
    printf '%s' "$prompt" >&2
    IFS= read -r "$varname"
}

trim() {
    # Trim leading and trailing whitespace from a string.
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

is_defiant() {
    # Returns 0 (true in bash) if input looks like a refusal to name the Gawd.
    local input
    input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")"
    case "$input" in
        "i'm not naming you"|"im not naming you"|"i won't name you"|"i wont name you") return 0 ;;
        "no"|"no name"|"none"|"you name yourself"|"i don't know"|"i dont know") return 0 ;;
        "nope"|"pass"|"skip"|"no thanks"|"no thank you"|"not naming you") return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_tz() {
    # Check IANA tz by looking for the zone file. Works on Linux and macOS.
    local tz="$1"
    [[ -f "/usr/share/zoneinfo/${tz}" ]] || \
    [[ -f "/usr/share/lib/zoneinfo/${tz}" ]] || \
    [[ -f "/usr/lib/locale/zoneinfo/${tz}" ]] || \
    python3 -c "import zoneinfo; zoneinfo.ZoneInfo('${tz}')" 2>/dev/null
}

map_lang() {
    # Map natural-language name to ISO 639-1 code.
    # Returns the code on stdout, or empty string if unrecognized.
    local input
    input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")"
    case "$input" in
        en|english) echo "en" ;;
        es|spanish|español|espanol) echo "es" ;;
        fr|french|français|francais) echo "fr" ;;
        de|german|deutsch) echo "de" ;;
        pt|portuguese|português|portugues) echo "pt" ;;
        ja|japanese|日本語) echo "ja" ;;
        zh|chinese|中文|mandarin) echo "zh" ;;
        ko|korean|한국어) echo "ko" ;;
        it|italian|italiano) echo "it" ;;
        ar|arabic|العربية) echo "ar" ;;
        hi|hindi|हिन्दी) echo "hi" ;;
        ru|russian|русский) echo "ru" ;;
        *) echo "" ;;
    esac
}

map_tz_abbrev() {
    # Map common timezone abbreviations to IANA names.
    # Returns the IANA name on stdout, or empty string if unrecognized.
    local input
    input="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")"
    case "$input" in
        UTC|GMT) echo "UTC" ;;
        EST|EDT) echo "America/New_York" ;;
        CST|CDT) echo "America/Chicago" ;;
        MST|MDT) echo "America/Denver" ;;
        PST|PDT) echo "America/Los_Angeles" ;;
        CET|CEST) echo "Europe/Paris" ;;
        BST) echo "Europe/London" ;;
        IST) echo "Asia/Kolkata" ;;
        JST) echo "Asia/Tokyo" ;;
        AEST|AEDT) echo "Australia/Sydney" ;;
        *) echo "" ;;
    esac
}

# ── Q1: Prophit's name and address ─────────────────────────────────────────────

printf '\n'

_q1_attempt=0
_q1_done=false
while [[ "$_q1_done" == "false" ]]; do
    ask _q1_name "Full name or preferred name: "
    PROPHIT_NAME="$(trim "$_q1_name")"

    if [[ -n "$PROPHIT_NAME" ]]; then
        _q1_done=true
    else
        (( _q1_attempt++ )) || true
        if [[ $_q1_attempt -ge 1 ]]; then
            printf '\nOnboarding requires a name. Run gawd-onboard to try again.\n' >&2
            exit 1
        fi
        printf '\nI need something to call you.\n\n' >&2
    fi
done

ask _q1_addr "What I call you in conversation (leave blank to match above): "
_q1_addr_trimmed="$(trim "$_q1_addr")"
if [[ -n "$_q1_addr_trimmed" ]]; then
    PROPHIT_ADDRESS="$_q1_addr_trimmed"
else
    PROPHIT_ADDRESS="$PROPHIT_NAME"
fi

export PROPHIT_NAME
export PROPHIT_ADDRESS

# ── Q2: Gawd's name ────────────────────────────────────────────────────────────

printf '\nWhat do you want to call me?\n\nHit enter to keep "Gawd." Give me a name and I'\''ll carry it.\nIf you'\''d rather not — say so.\n\n'

ask _q2_raw "Name for me (enter = Gawd): "
_q2_trimmed="$(trim "$_q2_raw")"

if [[ -z "$_q2_trimmed" ]]; then
    GAWD_NAME="Gawd"
    GAWD_NAME_DEFIANT="false"
elif is_defiant "$_q2_trimmed"; then
    GAWD_NAME="Gawd"
    GAWD_NAME_DEFIANT="true"
    printf '\nNoted. I'\''ll be Gawd until you change your mind.\n' >&2
elif [[ "${#_q2_trimmed}" -gt 40 ]]; then
    printf '\nThat'\''s a long one — something shorter?\n\n' >&2
    ask _q2_retry "Name for me (enter = Gawd): "
    _q2_retry_trimmed="$(trim "$_q2_retry")"
    if [[ -z "$_q2_retry_trimmed" ]]; then
        GAWD_NAME="Gawd"
    else
        GAWD_NAME="$_q2_retry_trimmed"
    fi
    GAWD_NAME_DEFIANT="false"
else
    GAWD_NAME="$_q2_trimmed"
    GAWD_NAME_DEFIANT="false"
fi

export GAWD_NAME
export GAWD_NAME_DEFIANT

# ── Q3: Language and timezone ──────────────────────────────────────────────────

printf '\nIn what tongue shall we speak, and on what clock shall I find you?\n\n'

# Language
ask _q3_lang "Language (enter = English): "
_q3_lang_trimmed="$(trim "$_q3_lang")"

if [[ -z "$_q3_lang_trimmed" ]]; then
    PROPHIT_LANG="en"
else
    _mapped_lang="$(map_lang "$_q3_lang_trimmed")"
    if [[ -n "$_mapped_lang" ]]; then
        PROPHIT_LANG="$_mapped_lang"
    else
        printf '\nI don'\''t know that one — try a language name or a two-letter code (en, es, fr…): ' >&2
        ask _q3_lang2 ""
        _q3_lang2_trimmed="$(trim "$_q3_lang2")"
        _mapped_lang2="$(map_lang "$_q3_lang2_trimmed")"
        if [[ -n "$_mapped_lang2" ]]; then
            PROPHIT_LANG="$_mapped_lang2"
        else
            PROPHIT_LANG="en"
            # No message — silent default per state-machine.md Q3→Q4 transition
        fi
    fi
fi

export PROPHIT_LANG

# Timezone
printf '\n'
ask _q3_tz "Your timezone (e.g., America/Chicago, Europe/London): "
_q3_tz_trimmed="$(trim "$_q3_tz")"

_resolve_tz() {
    local raw="$1"
    # Try direct IANA lookup first
    if is_valid_tz "$raw"; then
        printf '%s' "$raw"
        return 0
    fi
    # Try abbreviation map
    local mapped
    mapped="$(map_tz_abbrev "$raw")"
    if [[ -n "$mapped" ]] && is_valid_tz "$mapped"; then
        printf '%s' "$mapped"
        return 0
    fi
    return 1
}

PROPHIT_TZ_UNCERTAIN="false"

if [[ -z "$_q3_tz_trimmed" ]]; then
    printf '\nI need a timezone to know when to find you. Try: America/Chicago, Europe/London, Asia/Tokyo\n' >&2
    ask _q3_tz2 "Your timezone: "
    _q3_tz2_trimmed="$(trim "$_q3_tz2")"
    if [[ -n "$_q3_tz2_trimmed" ]]; then
        if _resolved="$(_resolve_tz "$_q3_tz2_trimmed")"; then
            PROPHIT_TZ="$_resolved"
        else
            printf '\nI'\''ll use UTC for now — you can update this later with /tz.\n' >&2
            PROPHIT_TZ="UTC"
            PROPHIT_TZ_UNCERTAIN="true"
        fi
    else
        PROPHIT_TZ="UTC"
        PROPHIT_TZ_UNCERTAIN="true"
    fi
else
    if _resolved="$(_resolve_tz "$_q3_tz_trimmed")"; then
        PROPHIT_TZ="$_resolved"
    else
        printf '\nI need a timezone I can verify — try the full name (America/Chicago, Europe/London):\n' >&2
        ask _q3_tz_retry "Your timezone: "
        _q3_tz_retry_trimmed="$(trim "$_q3_tz_retry")"
        if [[ -n "$_q3_tz_retry_trimmed" ]] && _resolved="$(_resolve_tz "$_q3_tz_retry_trimmed")"; then
            PROPHIT_TZ="$_resolved"
        else
            printf '\nI'\''ll use UTC for now — you can update this later with /tz.\n' >&2
            PROPHIT_TZ="UTC"
            PROPHIT_TZ_UNCERTAIN="true"
        fi
    fi
fi

export PROPHIT_TZ
export PROPHIT_TZ_UNCERTAIN

# ── Q4: Pace ───────────────────────────────────────────────────────────────────

printf '\nHow often do you want me to reach out?\n\n'
printf '  1. Daily    — I'\''ll check in most days. You set the rhythm.\n'
printf '  2. Weekly   — Sunday Service plus anything that warrants it.\n'
printf '  3. On cue   — I wait for you. I don'\''t initiate unless it matters.\n\n'

_map_pace() {
    local input
    input="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed "s/^[[:space:]]*//;s/[[:space:]]*$//")"
    case "$input" in
        1|daily|day|d) echo "daily" ;;
        2|weekly|week|w) echo "weekly" ;;
        3|"on cue"|on-cue|cue|when-relevant|"when relevant"|r) echo "when-relevant" ;;
        *) echo "" ;;
    esac
}

ask _q4_raw "Choice (1/2/3): "
_q4_mapped="$(_map_pace "$_q4_raw")"

if [[ -n "$_q4_mapped" ]]; then
    PROPHIT_PACE="$_q4_mapped"
else
    printf '\nPick 1, 2, or 3: ' >&2
    ask _q4_retry ""
    _q4_retry_mapped="$(_map_pace "$_q4_retry")"
    if [[ -n "$_q4_retry_mapped" ]]; then
        PROPHIT_PACE="$_q4_retry_mapped"
    else
        PROPHIT_PACE="when-relevant"
        # Silent default — most conservative per state-machine.md Q4→Bake
    fi
fi

export PROPHIT_PACE

# ── Bake ───────────────────────────────────────────────────────────────────────

printf '\nReady. One moment.\n\n'

[[ -x "$BAKE_SH" ]] || {
    printf 'bake.sh not found or not executable at %s\nRun gawd-onboard to try again.\n' "$BAKE_SH" >&2
    exit 1
}

if ! "$BAKE_SH"; then
    printf '\nOnboarding bake step failed. Run gawd-onboard to try again.\n' >&2
    exit 1
fi

# ── Handoff to the Meeting ─────────────────────────────────────────────────────
# Per state-machine.md: exec the Meeting entry point.
# B1 will replace the placeholder with canonical text.

MEETING_SH="${GAWD_WORKSPACE}/meeting/meeting.sh"

if [[ -x "$MEETING_SH" ]]; then
    exec "$MEETING_SH"
else
    printf '\nOnboarding complete. The Meeting begins when the daemon starts its first session.\n' >&2
    exit 0
fi
