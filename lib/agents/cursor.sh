# shellcheck shell=bash
#
# Cursor adapter. Skills and a postToolUse hook that injects additional_context.
# Search exclusions are not a Cursor capability: a .cursorignore inside the
# mount would land on the robot, and the global ignore list in user settings
# replaces the default list rather than merging with it. Those rules are folded
# into AGENTS.md instead.

AGENT_CONTEXT_FILE=AGENTS.md
AGENT_SKILLS_PATH="$HOME/.cursor/skills"
CURSOR_DIR="$HOME/.cursor"
CURSOR_HOOKS="$CURSOR_DIR/hooks.json"

agent_label() { printf 'Cursor\n'; }
agent_detect() {
    command -v cursor >/dev/null 2>&1 && return 0
    command -v cursor-agent >/dev/null 2>&1 && return 0
    [[ -d $HOME/.cursor ]]
}
agent_capabilities() { printf 'context skills hooks\n'; }

agent_apply() {
    _cursor_install_skills
    _cursor_merge_hook
}

agent_revert() {
    _cursor_remove_skills
    _cursor_restore_hooks
}

_cursor_install_skills() {
    [[ -n ${BOTKIT_SKILLS_STAGE:-} ]] || return 0
    step "Installing skills for Cursor"
    install_skills_from_stage "$AGENT_SKILLS_PATH" "Cursor"
}

_cursor_merge_hook() {
    local hook="$HOOKS_DIR/unslop-gate.sh"
    [[ -x $hook ]] || die "hook script is not executable: $hook"

    step "Merging hook config into ~/.cursor/hooks.json"
    acting "back up hooks.json and merge the postToolUse hook" || return 0

    mkdir -p -- "$CURSOR_DIR"
    if [[ ! -f $CURSOR_HOOKS ]]; then
        printf '{}\n' > "$CURSOR_HOOKS"
    fi
    backup_once "$CURSOR_HOOKS"

    local before; before="$(file_hash "$CURSOR_HOOKS")"
    json_file_edit "$CURSOR_HOOKS" '
        .version = 1
        | .hooks //= {}
        | .hooks.postToolUse = (
            ((.hooks.postToolUse // []) | map(select(
                (.command // "" | test("unslop-gate\\.sh")) | not
            )))
            + [{command: $cmd}]
          )
    ' --arg cmd "$hook"
    if [[ $before == "$(file_hash "$CURSOR_HOOKS")" ]]; then
        skip "postToolUse hook already configured"
    else
        ok "postToolUse hook -> $hook"
        note_change "merged the unslop postToolUse hook into hooks.json"
    fi
}

_cursor_remove_skills() {
    step "Removing Cursor skills"
    if [[ -f $AGENT_SKILLS_PATH/.botkit-provenance ]]; then
        remove_skills_from_provenance "$AGENT_SKILLS_PATH"
    elif [[ -d $AGENT_SKILLS_PATH ]]; then
        local leftover=0 path
        shopt -s nullglob
        for path in "$AGENT_SKILLS_PATH"/*/SKILL.md; do leftover=1; break; done
        shopt -u nullglob
        if (( leftover )); then
            warn "no provenance file at $AGENT_SKILLS_PATH/.botkit-provenance — no skills removed"
            warn "remove them by hand if you want them gone: ls $AGENT_SKILLS_PATH"
        else
            skip "no Cursor skills provenance"
        fi
    else
        skip "no $AGENT_SKILLS_PATH"
    fi
}

_cursor_restore_hooks() {
    step "Restoring ~/.cursor/hooks.json"
    if restore_json_backup "$CURSOR_HOOKS"; then
        return 0
    fi
    if command -v jq >/dev/null 2>&1 && [[ -f $CURSOR_HOOKS ]]; then
        json_file_edit "$CURSOR_HOOKS" '
            if (.hooks | type) == "object" then
              .hooks.postToolUse = ((.hooks.postToolUse // []) | map(select(
                (.command // "" | test("unslop-gate\\.sh")) | not
              )))
            else . end
        '
        ok "removed the botkit hook from hooks.json"
    else
        skip "no hooks.json to restore"
    fi
}
