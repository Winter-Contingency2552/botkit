# shellcheck shell=bash
#
# Applied to every agent, including ones nobody wrote an adapter for.
# Writes ~/dev/AGENTS.md and regenerates the marked block. Nothing else.

AGENT_CONTEXT_FILE=AGENTS.md
AGENT_SKILLS_PATH=''

agent_label() { printf 'generic\n'; }
agent_detect() { return 0; }
agent_capabilities() { printf 'context\n'; }

agent_apply() {
    local src="$TEMPLATES_DIR/AGENTS.md" dst="$AGENTS_MD"

    step "Installing ~/dev/AGENTS.md"
    acting "create $DEV_DIR" && mkdir -p -- "$DEV_DIR"

    if [[ ! -f $dst ]]; then
        acting "write $dst" || return 0
        cp -- "$src" "$dst"
        ok "wrote $dst"
        note_change "created ~/dev/AGENTS.md"
    elif agents_static_differs "$src" "$dst"; then
        acting "write $dst.new (yours differs from the template)" || true
        if (( ! DRY_RUN )); then
            cp -- "$src" "$dst.new"
            warn "~/dev/AGENTS.md differs from the template — wrote ~/dev/AGENTS.md.new instead"
            note_change "wrote ~/dev/AGENTS.md.new (yours was left alone)"
            note_manual "diff ~/dev/AGENTS.md ~/dev/AGENTS.md.new  and merge what you want"
        fi
    else
        skip "~/dev/AGENTS.md static content is current"
    fi

    regenerate_agents_md
}

agent_revert() {
    skip "~/dev/AGENTS.md is left in place — it is yours once written"
}
