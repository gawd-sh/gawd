#!/usr/bin/env bash
# select-template.sh — Map (channel, situation) -> template file path.
#
# Hardcoded routing per spec §19.5. No LLM. Deterministic.
#
# Usage:
#   select-template.sh <channel> <situation>
#
# Channels:   telegram | dashboard | desktop | voice
# Situations: degraded | extended-degraded | recovered
#
# Voice degradation: per spec §19.6 and acceptance criteria — when voice
# TTS is itself down, the voice channel falls back to telegram-degraded.
# That fall-through is performed by deliver/voice.sh, not by selection;
# this script returns the canonical voice template path.

set -euo pipefail

FALLBACK_DIR="${GAWD_FALLBACK_DIR:-${HOME}/.gawd/fallbacks/templates}"

channel="${1:-}"
situation="${2:-}"

if [[ -z "$channel" || -z "$situation" ]]; then
    printf 'usage: select-template.sh <channel> <situation>\n' >&2
    exit 2
fi

# Map to file basename.
case "$channel:$situation" in
    telegram:degraded)            file="telegram-degraded.md" ;;
    telegram:extended-degraded)   file="telegram-extended-degraded.md" ;;
    telegram:recovered)           file="telegram-recovered.md" ;;

    dashboard:degraded)           file="dashboard-degraded.html" ;;
    dashboard:extended-degraded)  file="dashboard-extended-degraded.html" ;;
    dashboard:recovered)          file="dashboard-recovered.html" ;;

    desktop:degraded)             file="desktop-degraded.txt" ;;
    desktop:extended-degraded)    file="desktop-degraded.txt" ;;   # desktop has one degraded variant only
    desktop:recovered)            file="desktop-recovered.txt" ;;

    voice:degraded)               file="voice-degraded.txt" ;;
    voice:extended-degraded)      file="voice-degraded.txt" ;;     # voice has one degraded variant only
    voice:recovered)              file="voice-recovered.txt" ;;

    *)
        printf 'select-template: no mapping for channel=%s situation=%s\n' "$channel" "$situation" >&2
        exit 3
        ;;
esac

path="$FALLBACK_DIR/$file"

# Caller (engine.sh) checks existence/emptiness. We still emit a stderr hint
# if the file is missing — useful for ops.
if [[ ! -e "$path" ]]; then
    printf 'select-template: WARN template does not exist on disk: %s\n' "$path" >&2
fi

printf '%s' "$path"
