#!/usr/bin/env bash
#
# PostToolUse / after-edit hook. When the file just written is user-facing
# prose, tell the agent to apply the unslop skill to it before moving on.
#
# This is a nudge, not a guarantee. A hook runs a shell command; skills are
# prompts. All this can do is inject an instruction into the context and rely on
# the agent to follow it. Anyone who needs determinism runs unslop explicitly.
#
# It exits 0 on every path, including bad input and a missing jq. A hook that
# fails is a hook that gets in the way of editing, and this one is not important
# enough to ever do that.

set -u

# ------------------------------------------------------------- what counts ----
#
# Edit these two lists to change what the hook considers prose. Exclusions win
# over inclusions.

INCLUDE_GLOBS=(
    '*.md'
    '*.rst'
    '*.txt'
    '*/docs/*'
)

EXCLUDE_GLOBS=(
    # Touched constantly by the agent, and nobody reads either for style.
    '*/notes/*/progress.md'
    '*/notes/*/inbox/*'
    '*/notes/*/scratch/*'

    '*/CHANGELOG.md'
    'CHANGELOG.md'

    # Lockfiles: generated, occasionally .txt-adjacent, never prose.
    '*/package-lock.json'
    '*/yarn.lock'
    '*/pnpm-lock.yaml'
    '*/Cargo.lock'
    '*/poetry.lock'
    '*/uv.lock'
    '*/requirements.txt'
)

MESSAGE='This file is user-facing prose. Apply the unslop skill to what you just wrote before continuing.'

# Mount points and search exclusions come from a file that install.sh and
# `bot up` regenerate. The hook fires on every Write and Edit, so it sources one
# small generated file rather than reading every bots/*.conf itself.
BOTKIT_MOUNTS=()
BOTKIT_EXCLUDES=()
_conf_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
# shellcheck source=/dev/null
[[ -r "$_conf_dir/botkit-unslop.conf" ]] && source "$_conf_dir/botkit-unslop.conf"
# Your own additions live here; this file is never regenerated.
# shellcheck source=/dev/null
[[ -r "$_conf_dir/botkit-unslop.local" ]] && source "$_conf_dir/botkit-unslop.local"

# ------------------------------------------------------------------- logic ----

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat || true)"

matches_any() {
    local subject="$1"; shift
    local glob
    for glob in "$@"; do
        # shellcheck disable=SC2053  # right side is a pattern on purpose
        [[ $subject == $glob ]] && return 0
    done
    return 1
}

# Return 0 if this path is user-facing prose the nudge should fire on.
is_prose() {
    local path="$1" base
    [[ -n $path ]] || return 1
    [[ $path == /* ]] || path="$PWD/$path"
    base="${path##*/}"

    local mount
    for mount in ${BOTKIT_MOUNTS[@]+"${BOTKIT_MOUNTS[@]}"}; do
        [[ -n $mount && $path == "$mount"/* ]] && return 1
    done

    local pattern
    for pattern in ${BOTKIT_EXCLUDES[@]+"${BOTKIT_EXCLUDES[@]}"}; do
        [[ -n $pattern ]] || continue
        case "$pattern" in
            *'*'*) matches_any "$base" "$pattern" && return 1 ;;
            *)     [[ $path == *"/$pattern/"* ]] && return 1 ;;
        esac
    done

    matches_any "$path" ${EXCLUDE_GLOBS[@]+"${EXCLUDE_GLOBS[@]}"} && return 1
    matches_any "$path" ${INCLUDE_GLOBS[@]+"${INCLUDE_GLOBS[@]}"}
}

should_nudge=0
path="$(printf '%s' "$input" | jq -r 'try (.tool_input.file_path // .tool_input.path // .file_path) // empty' 2>/dev/null)"
if is_prose "$path"; then
    should_nudge=1
else
    # Codex apply_patch sends the patch in tool_input.command, not a file_path.
    while IFS= read -r path; do
        is_prose "$path" && { should_nudge=1; break; }
    done < <(printf '%s' "$input" | jq -r 'try .tool_input.command // empty' 2>/dev/null |
        sed -n 's/\r$//; s/^\*\*\* \(Add\|Update\) File: //p')
fi
[[ $should_nudge == 1 ]] || exit 0

# stdout carries the JSON and nothing else. Claude Code reads
# hookSpecificOutput.additionalContext. Cursor's postToolUse reads
# additional_context. Extra keys are ignored by each side.
jq -n --arg ctx "$MESSAGE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $ctx
  },
  additional_context: $ctx
}'
exit 0
