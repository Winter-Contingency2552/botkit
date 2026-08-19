# shellcheck shell=bash
#
# Codex adapter. Personal skills and a PostToolUse hook.
# Search exclusions are not a Codex capability here: writing default_permissions
# into config.toml would replace the user's sandbox profile, and a project
# .codex/ inside the mount would land on the robot. Those rules stay in
# AGENTS.md.

AGENT_CONTEXT_FILE=AGENTS.md
AGENT_SKILLS_PATH="$HOME/.agents/skills"
CODEX_DIR="$HOME/.codex"
CODEX_HOOKS="$CODEX_DIR/hooks.json"

agent_label() { printf 'Codex\n'; }
agent_detect() {
    command -v codex >/dev/null 2>&1 && return 0
    [[ -d $HOME/.codex ]]
}
agent_capabilities() { printf 'context skills hooks\n'; }

agent_apply() {
    _codex_install_skills
    _codex_merge_hook
}

agent_revert() {
    _codex_remove_skills
    _codex_restore_hooks
}

_codex_install_skills() {
    [[ -n ${BOTKIT_SKILLS_STAGE:-} ]] || return 0
    step "Installing skills for Codex"
    install_skills_from_stage "$AGENT_SKILLS_PATH" "Codex"
}

_codex_merge_hook() {
    local hook="$HOOKS_DIR/unslop-gate.sh"
    [[ -x $hook ]] || die "hook script is not executable: $hook"

    step "Merging hook config into ~/.codex/hooks.json"
    acting "back up hooks.json and merge the PostToolUse hook" || return 0

    mkdir -p -- "$CODEX_DIR"
    # If we create the file, back up empty JSON so uninstall can restore the
    # pre-botkit state instead of a copy taken after our first write.
    if [[ ! -f $CODEX_HOOKS ]]; then
        printf '{}\n' > "$CODEX_HOOKS"
    fi
    backup_once "$CODEX_HOOKS"

    local before; before="$(file_hash "$CODEX_HOOKS")"
    json_file_edit "$CODEX_HOOKS" '
        .hooks //= {}
        | .hooks.PostToolUse = (
            ((.hooks.PostToolUse // []) | map(select(
                ((.hooks // []) | map(.command // "") | any(test("unslop-gate\\.sh"))) | not
            )))
            + [{matcher: "Write|Edit|apply_patch", hooks: [{type: "command", command: $cmd}]}]
          )
    ' --arg cmd "$hook"
    if [[ $before == "$(file_hash "$CODEX_HOOKS")" ]]; then
        skip "PostToolUse hook already configured"
    else
        ok "PostToolUse hook -> $hook"
        note_change "merged the unslop PostToolUse hook into ~/.codex/hooks.json"
        note_manual "Codex will skip this hook until you trust it: run /hooks in a Codex session"
    fi
}

_codex_remove_skills() {
    step "Removing Codex skills"
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
            skip "no Codex skills provenance"
        fi
    else
        skip "no $AGENT_SKILLS_PATH"
    fi
}

_codex_restore_hooks() {
    step "Restoring ~/.codex/hooks.json"
    if restore_json_backup "$CODEX_HOOKS"; then
        return 0
    fi
    if command -v jq >/dev/null 2>&1 && [[ -f $CODEX_HOOKS ]]; then
        json_file_edit "$CODEX_HOOKS" '
            if (.hooks | type) == "object" then
              .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(select(
                ((.hooks // []) | map(.command // "") | any(test("unslop-gate\\.sh"))) | not
              )))
            else . end
        '
        ok "removed the botkit hook from ~/.codex/hooks.json"
    else
        skip "no hooks.json to restore"
    fi
}
