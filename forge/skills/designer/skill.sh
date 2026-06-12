#!/usr/bin/env bash
# skills/designer/skill.sh — The Designer DemiGawd.
#
# Purpose: Design work + image generation (Ideogram for graphics/logos/flat design;
#          MiniMax for photorealistic/people/scenes). Returns design direction and
#          optionally an image_path if image generation is requested.
#
# Contract (per demigawd-runtime.md §12):
#   $1 = TASK_ID           (required; assigned by spawn_demigawd)
#   $2 = TASK_DESCRIPTION  (required; the design brief: what to design, context, goal)
#   $3 = INJECTED_CONTEXT  (optional; brand assets, style refs, existing material)
#
# Optional env vars (set by caller before spawn if image generation is needed):
#   GAWD_DESIGNER_GENERATE_IMAGE=1  — request image generation (default: 0)
#   GAWD_DESIGNER_IMAGE_STYLE       — override style (DESIGN/GENERAL/REALISTIC/RENDER_3D)
#   GAWD_DESIGNER_IMAGE_RATIO       — override ratio (1:1/16:9/4:3/9:16)
#
# Tier: divine (image generation is cloud-expensive; top-tier cloud)
#
# Output: write_result_complete_obj → TASK_ID.result with:
#   { "design_output": <string>, "image_path": <string|null> }
#   image_path is null if no image was generated.
#
# Do NOT modify T0 anchors. Do NOT call OpenClaw directly.

set -euo pipefail

TASK_ID="${1:?TASK_ID required}"
TASK_DESCRIPTION="${2:?TASK_DESCRIPTION required}"
INJECTED_CONTEXT="${3:-}"

GENERATE_IMAGE="${GAWD_DESIGNER_GENERATE_IMAGE:-0}"
IMAGE_STYLE="${GAWD_DESIGNER_IMAGE_STYLE:-DESIGN}"
IMAGE_RATIO="${GAWD_DESIGNER_IMAGE_RATIO:-1:1}"

SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNTIME_LIB_DIR="${SKILL_DIR}/../../runtime/lib"
SKILLS_ROOT="${SKILL_DIR}/.."

# shellcheck source=../../runtime/lib/json-result.sh
source "${RUNTIME_LIB_DIR}/json-result.sh"
# shellcheck source=../../runtime/lib/dispatch.sh
source "${RUNTIME_LIB_DIR}/dispatch.sh"

TIER="divine"

PROMPT_TEMPLATE="${SKILL_DIR}/prompt.md"

PROMPT_FILE="$(mktemp "${GAWD_STATE_ROOT}/designer-prompt-XXXXXX.txt")"
trap 'rm -f -- "$PROMPT_FILE"' EXIT

{
    cat "${PROMPT_TEMPLATE}"
    printf '\n\n---\n\n## Design Brief\n\n%s\n' "${TASK_DESCRIPTION}"
    if [[ -n "${INJECTED_CONTEXT}" ]]; then
        printf '\n## Reference Material\n\n%s\n' "${INJECTED_CONTEXT}"
    fi
    if [[ "${GENERATE_IMAGE}" == "1" ]]; then
        printf '\nPlease generate an image for this. Output ONLY the JSON image block at the end of your response.\n'
    fi
} > "${PROMPT_FILE}"

RESPONSE="$(dispatch_demigawd_call "${TIER}" "${PROMPT_FILE}" 2000)" || {
    write_result_failed "${TASK_ID}" "designer: dispatch failed (tier=${TIER})"
    exit 0
}

if [[ -z "${RESPONSE}" ]]; then
    write_result_failed "${TASK_ID}" "designer: model returned empty response"
    exit 0
}

# Extract image generation JSON from the response if present.
# Expected format from model: {"generate": true, "tool": "ideogram"|"minimax",
#   "prompt": "...", "style": "...", "ratio": "..."}
IMAGE_PATH=""
if [[ "${GENERATE_IMAGE}" == "1" ]]; then
    GEN_JSON="$(printf '%s' "${RESPONSE}" | python3 -c "
import json, sys, re
text = sys.stdin.read()
m = re.search(r'\{[^{}]*\"generate\"[^{}]*\}', text, re.DOTALL)
if m:
    try:
        d = json.loads(m.group())
        if d.get('generate'):
            print(json.dumps(d))
    except Exception:
        pass
" 2>/dev/null || true)"

    if [[ -n "${GEN_JSON}" ]]; then
        TOOL="$(printf '%s' "${GEN_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool','minimax'))" 2>/dev/null || echo "minimax")"
        IMG_PROMPT="$(printf '%s' "${GEN_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('prompt',''))" 2>/dev/null || echo "")"
        IMG_STYLE="$(printf '%s' "${GEN_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('style','${IMAGE_STYLE}'))" 2>/dev/null || echo "${IMAGE_STYLE}")"
        IMG_RATIO="$(printf '%s' "${GEN_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ratio','${IMAGE_RATIO}'))" 2>/dev/null || echo "${IMAGE_RATIO}")"

        if [[ -n "${IMG_PROMPT}" ]]; then
            # Delegate to the appropriate image-generation skill.
            # These skills are expected to exist alongside this one in the skills root.
            if [[ "${TOOL}" == "ideogram" ]] && [[ -x "${SKILLS_ROOT}/ideogram-image/skill.sh" ]]; then
                IMAGE_PATH="$(PROMPT="${IMG_PROMPT}" STYLE="${IMG_STYLE}" \
                    bash "${SKILLS_ROOT}/ideogram-image/skill.sh" 2>/dev/null \
                    | grep '^image_path:' | sed 's/^image_path: //' || echo "")"
            elif [[ -x "${SKILLS_ROOT}/minimax-image/skill.sh" ]]; then
                IMAGE_PATH="$(PROMPT="${IMG_PROMPT}" ASPECT="${IMG_RATIO}" \
                    bash "${SKILLS_ROOT}/minimax-image/skill.sh" 2>/dev/null \
                    | grep '^image_path:' | sed 's/^image_path: //' || echo "")"
            fi
        fi

        # Strip the JSON block from the design output text.
        RESPONSE="$(printf '%s' "${RESPONSE}" | python3 -c "
import json, sys, re
text = sys.stdin.read()
cleaned = re.sub(r'\{[^{}]*\"generate\"[^{}]*\}', '', text, flags=re.DOTALL).strip()
print(cleaned)
" 2>/dev/null || printf '%s' "${RESPONSE}")"
    fi
fi

# Build the structured output object.
OUTPUT_OBJ="$(jq -nc \
    --arg design "${RESPONSE}" \
    --arg img "${IMAGE_PATH}" \
    '{
        design_output: $design,
        image_path: (if $img == "" then null else $img end)
    }')"

write_result_complete_obj "${TASK_ID}" "${OUTPUT_OBJ}"
exit 0
