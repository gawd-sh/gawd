#!/usr/bin/env bash
# render.sh — Deterministic template renderer.
#
# Substitutes ONLY two variables:
#   {{address_name}}        -> the Prophit's address name
#   {{prophit_local_time}}  -> the Prophit-local time as a short string
#
# No LLM. No shell expansion of template contents. Same inputs -> same output bytes.
#
# Usage:
#   render.sh <template_path> <address_name> <prophit_local_time>
#
# Output: rendered template to stdout. Exit non-zero on error.
#
# Substitution is performed with awk to avoid shell interpolation, regex
# escaping pitfalls, and accidental command execution. The template is
# treated as opaque bytes; only the two variable markers are replaced.

set -euo pipefail

template_path="${1:-}"
address_name="${2:-}"
prophit_local_time="${3:-}"

if [[ -z "$template_path" || -z "$address_name" || -z "$prophit_local_time" ]]; then
    printf 'usage: render.sh <template_path> <address_name> <prophit_local_time>\n' >&2
    exit 2
fi

if [[ ! -r "$template_path" ]]; then
    printf 'render: cannot read template: %s\n' "$template_path" >&2
    exit 3
fi

# Use awk for byte-faithful substitution. Pass values via -v and use gsub.
# We escape any backslash and ampersand in the value because awk gsub treats
# those specially in the replacement string.
escape_for_gsub() {
    # Awk gsub replacement: backslash and ampersand are special.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    printf '%s' "$s"
}

esc_addr="$(escape_for_gsub "$address_name")"
esc_time="$(escape_for_gsub "$prophit_local_time")"

# Substitute. We process the file line-by-line; awk reads bytes correctly.
# Use a fixed-string match via index() loop to avoid any regex surprises in
# the search pattern (no special chars in our two placeholders, but be defensive).
awk -v addr="$esc_addr" -v ptime="$esc_time" '
{
    line = $0
    # Replace all occurrences of {{address_name}}
    out = ""
    while ( (i = index(line, "{{address_name}}")) > 0 ) {
        out = out substr(line, 1, i-1) addr
        line = substr(line, i + length("{{address_name}}"))
    }
    out = out line
    line = out

    # Replace all occurrences of {{prophit_local_time}}
    out = ""
    while ( (i = index(line, "{{prophit_local_time}}")) > 0 ) {
        out = out substr(line, 1, i-1) ptime
        line = substr(line, i + length("{{prophit_local_time}}"))
    }
    out = out line

    print out
}
' "$template_path"
