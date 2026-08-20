# shellcheck shell=bash
#
# Claude Code adapter. CLAUDE.md symlink, personal skills, PostToolUse hook,
# Read() deny rules, mattpocock plugin.

AGENT_CONTEXT_FILE=CLAUDE.md
AGENT_SKILLS_PATH="$HOME/.claude/skills"

agent_label() { printf 'Claude Code\n'; }
agent_detect() { command -v claude >/dev/null 2>&1; }
agent_capabilities() { printf 'context skills hooks exclusions\n'; }

agent_apply() {
    _claude_link_instructions
    _claude_install_skills
    _claude_merge_hook
    _claude_apply_exclusions
    _claude_install_plugins
}

agent_revert() {
    _claude_remove_skills
    _claude_remove_plugins
    _claude_restore_settings
}

_claude_link_instructions() {
    local dst="$DEV_DIR/CLAUDE.md"

    step "Linking ~/dev/CLAUDE.md -> AGENTS.md"

    [[ -f $AGENTS_MD ]] || {
        warn "~/dev/AGENTS.md is missing, cannot symlink CLAUDE.md"
        return 0
    }

    if [[ -L $dst && "$(readlink -f -- "$dst")" == "$(readlink -f -- "$AGENTS_MD")" ]]; then
        skip "~/dev/CLAUDE.md already points at AGENTS.md"
        return 0
    fi

    if [[ -d $dst && ! -L $dst ]]; then
        warn "~/dev/CLAUDE.md is a directory, cannot symlink it"
        note_manual "move ~/dev/CLAUDE.md out of the way, then re-run install.sh or bot up"
        return 0
    fi

    if [[ -f $dst && ! -L $dst ]]; then
        acting "back up $dst and replace it with a symlink to AGENTS.md" || return 0
        backup_once "$dst"
    else
        acting "symlink $dst -> AGENTS.md" || return 0
    fi

    ln -sfn -- AGENTS.md "$dst"
    ok "~/dev/CLAUDE.md -> AGENTS.md"
    note_change "symlinked ~/dev/CLAUDE.md -> AGENTS.md"
}

_claude_install_skills() {
    [[ -n ${BOTKIT_SKILLS_STAGE:-} ]] || return 0
    step "Installing skills for Claude Code"
    install_skills_from_stage "$AGENT_SKILLS_PATH" "Claude Code"
}

_claude_merge_hook() {
    local hook="$HOOKS_DIR/unslop-gate.sh"
    [[ -x $hook ]] || die "hook script is not executable: $hook"

    step "Merging hook config into ~/.claude/settings.json"
    acting "back up settings.json and merge the PostToolUse hook" || return 0

    mkdir -p -- "$CLAUDE_DIR"
    backup_once "$SETTINGS_JSON"

    local before; before="$(file_hash "$SETTINGS_JSON")"
    settings_json_edit '
        .hooks //= {}
        | .hooks.PostToolUse = (
            ((.hooks.PostToolUse // []) | map(select(
                ((.hooks // []) | map(.command // "") | any(test("unslop-gate\\.sh"))) | not
            )))
            + [{matcher: "Write|Edit", hooks: [{type: "command", command: $cmd}]}]
          )
    ' --arg cmd "$hook"
    if [[ $before == "$(file_hash "$SETTINGS_JSON")" ]]; then
        skip "PostToolUse hook already configured"
    else
        ok "PostToolUse hook -> $hook"
        note_change "merged the unslop PostToolUse hook into settings.json"
    fi
}

_claude_apply_exclusions() {
    step "Applying Claude Code search exclusions"
    local name any=0

    while read -r name; do
        any=1
        if ! ( load_bot_conf "$name" ) >/dev/null 2>&1; then
            warn "bots/$name.conf is incomplete — no exclusions applied for it"
            continue
        fi
        load_bot_conf "$name"
        acting "write deny rules for $MOUNT_POINT" || continue
        local before; before="$(file_hash "$SETTINGS_JSON")"
        write_search_denies "$MOUNT_POINT" "$SEARCH_EXCLUDE"
        if [[ $before == "$(file_hash "$SETTINGS_JSON")" ]]; then
            skip "$name exclusions unchanged"
        else
            ok "$name -> $MOUNT_POINT"
            note_change "search exclusions for $name"
        fi
    done < <(list_bots)

    (( any )) || skip "no bots configured yet"
}

_claude_install_plugins() {
    (( BOTKIT_INSTALLING )) || return 0

    local MP_SOURCE='mattpocock/skills'
    local MP_MARKETPLACE='mattpocock'
    local MP_PLUGIN='mattpocock-skills@mattpocock'

    step "Installing mattpocock skills"

    if (( ! DO_PLUGINS )); then
        skip "--no-plugins given"
        return 0
    fi

    local paste="/plugin marketplace add $MP_SOURCE
  /plugin install $MP_PLUGIN"

    acting "claude plugin marketplace add $MP_SOURCE; claude plugin install $MP_PLUGIN" || return 0

    if ! command -v claude >/dev/null 2>&1; then
        warn "claude is not on PATH — cannot install the marketplace plugin"
        note_manual "paste into a Claude Code session:
  $paste"
        return 0
    fi

    if ! claude plugin marketplace --help >/dev/null 2>&1; then
        warn "this claude build has no 'plugin marketplace' subcommand"
        note_manual "paste into a Claude Code session:
  $paste"
        return 0
    fi

    if claude plugin marketplace add "$MP_SOURCE" >/dev/null 2>&1 ||
       claude plugin marketplace list 2>/dev/null | grep -q "$MP_MARKETPLACE"; then
        ok "marketplace $MP_MARKETPLACE"
    else
        warn "could not add the $MP_SOURCE marketplace"
        note_manual "paste into a Claude Code session:
  $paste"
        return 0
    fi

    if claude plugin install "$MP_PLUGIN" -y --scope user >/dev/null 2>&1; then
        ok "$MP_PLUGIN"
        note_change "installed plugin: $MP_PLUGIN"
    else
        warn "could not install $MP_PLUGIN non-interactively"
        note_manual "paste into a Claude Code session:
  /plugin install $MP_PLUGIN"
    fi
}

_claude_remove_skills() {
    step "Removing Claude Code skills"
    if [[ -f $AGENT_SKILLS_PATH/.botkit-provenance ]]; then
        remove_skills_from_provenance "$AGENT_SKILLS_PATH"
    elif [[ -d $AGENT_SKILLS_PATH ]]; then
        warn "no provenance file at $AGENT_SKILLS_PATH/.botkit-provenance — no skills removed"
        warn "remove them by hand if you want them gone: ls $AGENT_SKILLS_PATH"
    else
        skip "no $AGENT_SKILLS_PATH"
    fi
}

_claude_remove_plugins() {
    local MP_MARKETPLACE='mattpocock'
    local MP_PLUGIN='mattpocock-skills@mattpocock'

    step "Removing the mattpocock plugin"
    if (( ${KEEP_PLUGINS:-0} )); then
        skip "--keep-plugins given"
    elif ! command -v claude >/dev/null 2>&1; then
        skip "claude not on PATH"
    else
        claude plugin uninstall "$MP_PLUGIN" >/dev/null 2>&1 &&
            ok "uninstalled $MP_PLUGIN" || skip "$MP_PLUGIN was not installed"
        claude plugin marketplace remove "$MP_MARKETPLACE" >/dev/null 2>&1 &&
            ok "removed marketplace $MP_MARKETPLACE" || skip "marketplace $MP_MARKETPLACE was not configured"
    fi
}

_claude_restore_settings() {
    step "Restoring settings.json"
    if restore_json_backup "$SETTINGS_JSON"; then
        return 0
    fi
    warn "no settings.json.botkit-bak found — removing the hook and deny rules in place"
    if command -v jq >/dev/null 2>&1 && [[ -f $SETTINGS_JSON ]]; then
        settings_json_edit '
            (.hooks.PostToolUse? // []) as $p
            | if (.hooks | type) == "object" then
                .hooks.PostToolUse = ($p | map(select(
                    ((.hooks // []) | map(.command // "") | any(test("unslop-gate\\.sh"))) | not
                )))
              else . end
            | if (.permissions.deny? | type) == "array" then
                .permissions.deny = (.permissions.deny | map(select(test("^Read\\(//.*/\\*\\*/") | not)))
              else . end
        '
        ok "removed the botkit hook and deny rules"
    fi
}
