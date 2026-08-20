#!/usr/bin/env bash
#
# botkit installer. Idempotent: re-running upgrades scripts and skills, and
# never overwrites ~/dev/AGENTS.md or anything under ~/dev/notes/.
#
# Ubuntu + bash. No macOS, no zsh.

set -uo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

# ------------------------------------------------------------------ pins ----

PSTACK_REPO='https://github.com/cursor/plugins'
PSTACK_SKILLS=(unslop blast-radius bro)

ROBOTICS_REPO='https://github.com/arpitg1304/robotics-agent-skills'
# Audited at this commit: no injection patterns, no hidden or bidi Unicode, no
# hidden text in HTML comments, and an installer that validates skill names and
# guards its delete with ${target:?}. Do not track main. Re-audit before bumping
# this, and record the new commit in docs/SKILLS.md.
ROBOTICS_COMMIT='f9bc5467ff9ee3d23f1a1b0b29a649843bb6ad11'
ROBOTICS_SKILLS=(ros2 robot-bringup robot-perception robotics-testing ros2-web-integration)

DEPENDENCIES=(sshfs jq git ssh)

# ----------------------------------------------------------------- flags ----

DO_PLUGINS=1
DO_SKILLS=1
DRY_RUN=0
FORCE_AGENT=''

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-plugins) DO_PLUGINS=0 ;;
        --no-skills)  DO_SKILLS=0 ;;
        --dry-run)    DRY_RUN=1 ;;
        --agent)
            [[ -n ${2:-} ]] || die "--agent needs a name"
            FORCE_AGENT="$2"
            shift ;;
        -h|--help)
            cat <<'USAGE'
usage: ./install.sh [options]

  --agent NAME   configure only this adapter (plus the generic layer)
  --no-plugins   skip the mattpocock marketplace plugin step
  --no-skills    skip all third-party skill downloads (offline install)
  --dry-run      report what would change, change nothing
USAGE
            exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ------------------------------------------------------------- preflight ----

preflight() {
    step "Checking dependencies"
    local missing=() cmd
    for cmd in "${DEPENDENCIES[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            ok "$cmd"
        else
            missing+=("$cmd")
        fi
    done

    if (( ${#missing[@]} )); then
        printf '\n' >&2
        for cmd in "${missing[@]}"; do
            case "$cmd" in
                sshfs)  warn "missing sshfs  — install with: sudo apt install sshfs" ;;
                jq)     warn "missing jq     — install with: sudo apt install jq" ;;
                git)    warn "missing git    — install with: sudo apt install git" ;;
                ssh)    warn "missing ssh    — install with: sudo apt install openssh-client" ;;
                *)      warn "missing $cmd" ;;
            esac
        done
        die "install the commands above and re-run"
    fi

    step "Checking PATH"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ok "$BIN_DIR is on PATH" ;;
        *)
            warn "$BIN_DIR is not on PATH — the 'bot' command will not be found"
            note_manual "add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac

    check_no_tracked_real_bot_confs
}

# ------------------------------------------------------------- workspace ----

init_notes() {
    step "Setting up ~/dev/notes"
    local src="$TEMPLATES_DIR/notes-repo" f

    acting "create $NOTES_DIR" && mkdir -p -- "$NOTES_DIR"

    # Seed only what is missing. TEMPLATE/ stays in botkit; `bot notes` copies
    # it per repo, so there is only ever one copy of it to drift.
    for f in README.md .gitignore; do
        if [[ -e "$NOTES_DIR/$f" ]]; then
            skip "notes/$f exists"
        elif acting "write notes/$f"; then
            cp -- "$src/$f" "$NOTES_DIR/$f"
            ok "wrote notes/$f"
            note_change "seeded ~/dev/notes/$f"
        fi
    done

    # git init only when .git is absent. Never reinitialize, never touch a
    # remote — this repo may already be shared with teammates.
    if [[ -d "$NOTES_DIR/.git" ]]; then
        skip "~/dev/notes is already a git repo (left completely alone)"
        return 0
    fi

    acting "git init ~/dev/notes and make an initial commit" || return 0

    git init -q -- "$NOTES_DIR" || die "git init failed in $NOTES_DIR"
    ok "git init ~/dev/notes"
    note_change "initialized ~/dev/notes as a git repo (no remote)"

    local -a ident=()
    if [[ -z "$(git -C "$NOTES_DIR" config user.email 2>/dev/null)" ]]; then
        ident=(-c user.name=botkit -c user.email=botkit@localhost)
        warn "no git identity configured — committing as botkit@localhost"
        note_manual "set a git identity in ~/dev/notes:  git -C ~/dev/notes config user.email you@example.com"
    fi

    git -C "$NOTES_DIR" add -A
    git "${ident[@]+"${ident[@]}"}" -C "$NOTES_DIR" commit -q -m 'notes: initial commit' ||
        warn "initial commit in ~/dev/notes failed — commit by hand"
}

init_references() {
    step "Setting up ~/dev/references"
    local src="$TEMPLATES_DIR/references/README.md"

    acting "create $REFERENCES_DIR" && mkdir -p -- "$REFERENCES_DIR"

    if [[ -e "$REFERENCES_DIR/README.md" ]]; then
        skip "references/README.md exists"
    elif acting "write references/README.md"; then
        cp -- "$src" "$REFERENCES_DIR/README.md"
        ok "wrote references/README.md"
        note_change "seeded ~/dev/references/README.md"
    fi
}

install_bot() {
    step "Installing the bot command"
    local target="$BIN_DIR/bot" src="$BOTKIT_ROOT/scripts/bot"

    if [[ -L $target && "$(readlink -f -- "$target")" == "$(readlink -f -- "$src")" ]]; then
        skip "$target already points at this checkout"
        return 0
    fi

    acting "symlink $target -> $src" || return 0
    mkdir -p -- "$BIN_DIR"
    ln -sfn -- "$src" "$target" || die "could not create $target"
    ok "$target -> $src"
    note_change "installed bot -> $src"
}

install_precommit_hook() {
    local src="$HOOKS_DIR/pre-commit" dest="$BOTKIT_ROOT/.git/hooks/pre-commit"
    [[ -d $BOTKIT_ROOT/.git/hooks ]] || return 0

    step "Installing git pre-commit hook"
    chmod +x -- "$src" 2>/dev/null || true

    if [[ -L $dest && "$(readlink -f -- "$dest")" == "$(readlink -f -- "$src")" ]]; then
        skip "pre-commit hook already points at this checkout"
        return 0
    fi
    if [[ -e $dest || -L $dest ]]; then
        warn "pre-commit hook already exists — not overwriting"
        note_manual "ln -sfn -- $src $dest   # blocks real bot confs from being committed"
        return 0
    fi
    acting "symlink $dest -> $src" || return 0
    ln -sfn -- "$src" "$dest" || die "could not install pre-commit hook"
    ok "pre-commit hook -> $src"
    note_change "installed git pre-commit hook"
}

# ---------------------------------------------------------------- skills ----

stage_one_skill() {
    local name="$1" src="$2" source="$3" commit="$4"
    copy_skill_to "$BOTKIT_SKILLS_STAGE" "$name" "$src"
    local rc=$?
    case "$rc" in
        0|3) PROV_LINES+=("$name	$source	$commit") ;;
    esac
    return 0
}

stage_own_skills() {
    # Every directory under skills/ is staged. Adding a skill is adding a
    # folder; install.sh does not name them individually.
    local src name
    step "Staging botkit's own skills"
    acting "copy $SKILLS_SRC_DIR -> stage" || return 0
    mkdir -p -- "$BOTKIT_SKILLS_STAGE"
    shopt -s nullglob
    for src in "$SKILLS_SRC_DIR"/*/; do
        [[ -f "$src/SKILL.md" ]] || continue
        name="$(basename -- "$src")"
        stage_one_skill "$name" "$src" "botkit (this repo)" local
        ok "$name"
    done
    shopt -u nullglob
}

stage_pstack_skills() {
    step "Staging pstack skills (${PSTACK_SKILLS[*]})"
    acting "clone $PSTACK_REPO and copy ${PSTACK_SKILLS[*]}" || return 0

    local tmp; tmp="$(mktemp -d)" || die "mktemp -d failed"

    local dir="$tmp/plugins"
    if git clone --depth 1 --filter=blob:none --sparse -q -- "$PSTACK_REPO" "$dir" 2>/dev/null &&
       git -C "$dir" sparse-checkout set pstack/skills >/dev/null 2>&1; then
        :
    elif git clone --depth 1 -q -- "$PSTACK_REPO" "$dir" 2>/dev/null; then
        warn "sparse checkout unavailable — used a full shallow clone instead"
    else
        warn "could not clone $PSTACK_REPO — skipping pstack skills"
        note_manual "pstack skills not installed. Re-run install.sh when you have network."
        rm -rf -- "$tmp"
        return 0
    fi

    local commit; commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    mkdir -p -- "$BOTKIT_SKILLS_STAGE"

    local name
    for name in "${PSTACK_SKILLS[@]}"; do
        stage_one_skill "$name" "$dir/pstack/skills/$name" "$PSTACK_REPO" "$commit"
        ok "$name"
    done
    rm -rf -- "$tmp"
}

stage_robotics_skills() {
    step "Staging robotics skills (${ROBOTICS_SKILLS[*]})"
    acting "fetch $ROBOTICS_REPO at $ROBOTICS_COMMIT and run its installer" || return 0

    local tmp; tmp="$(mktemp -d)" || die "mktemp -d failed"
    local dir="$tmp/robotics"
    if ! ( git init -q -- "$dir" &&
           git -C "$dir" remote add origin "$ROBOTICS_REPO" &&
           git -C "$dir" fetch -q --depth 1 origin "$ROBOTICS_COMMIT" &&
           git -C "$dir" checkout -q FETCH_HEAD ) 2>/dev/null; then
        warn "shallow fetch of the pinned commit failed — falling back to a full clone"
        rm -rf -- "$dir"
        if ! ( git clone -q -- "$ROBOTICS_REPO" "$dir" &&
               git -C "$dir" checkout -q "$ROBOTICS_COMMIT" ) 2>/dev/null; then
            warn "could not fetch $ROBOTICS_REPO — skipping robotics skills"
            note_manual "robotics skills not installed. Re-run install.sh when you have network."
            rm -rf -- "$tmp"
            return 0
        fi
    fi

    local head; head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    [[ $head == "$ROBOTICS_COMMIT" ]] ||
        die "robotics repo checked out $head, expected the audited $ROBOTICS_COMMIT — refusing to install"

    mkdir -p -- "$BOTKIT_SKILLS_STAGE"

    if bash "$dir/install.sh" --target "$BOTKIT_SKILLS_STAGE" --skills "${ROBOTICS_SKILLS[@]}" >/dev/null; then
        local name
        for name in "${ROBOTICS_SKILLS[@]}"; do
            if [[ -d "$BOTKIT_SKILLS_STAGE/$name" ]]; then
                PROV_LINES+=("$name	$ROBOTICS_REPO	$ROBOTICS_COMMIT")
                ok "$name"
            else
                warn "$name is MISSING after the robotics installer ran"
            fi
        done
    else
        warn "the robotics repo's installer failed"
        note_manual "robotics skills not installed. Re-run install.sh."
    fi
    rm -rf -- "$tmp"
}

# ---------------------------------------------------------------- report ----

print_capability_report() {
    local id label context skills hook excl n

    printf '\n%sCapability report%s\n\n' "$C_BOLD" "$C_RESET"
    printf '%-14s %-12s %-8s %-14s %s\n' Agent Context Skills Hook Exclusions
    for id in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
        label="${AGENT_LABEL[$id]}"
        context="${AGENT_CONTEXT[$id]}"
        if agent_has_cap "$id" skills && [[ -n ${AGENT_SKILLS_PATHS[$id]:-} ]]; then
            n="$(count_skill_dirs "${AGENT_SKILLS_PATHS[$id]}")"
            skills="$n"
        else
            skills='-'
        fi
        if agent_has_cap "$id" hooks; then
            hook='enforced'
        else
            hook='written down'
        fi
        if agent_has_cap "$id" exclusions; then
            excl='enforced'
        else
            excl='written down'
        fi
        printf '%-14s %-12s %-8s %-14s %s\n' "$label" "$context" "$skills" "$hook" "$excl"
    done
    printf '%-14s %-12s %-8s %-14s %s\n' "Unknown agent" "AGENTS.md" "-" "-" "written down"

    cat <<'EOF'

A rule written into AGENTS.md is an instruction the agent may ignore. A hook
or a deny rule is enforced by the agent. They are not equivalent. "written
down" in the table means the rule exists only as text in AGENTS.md.

EOF
}

print_restart_notes() {
    local id path existed
    for id in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
        agent_has_cap "$id" skills || continue
        path="${AGENT_SKILLS_PATHS[$id]:-}"
        [[ -n $path ]] || continue
        existed="${SKILLS_DIR_EXISTED[$id]:-0}"
        if [[ $id == claude && $existed == 0 ]]; then
            printf '\n%s%sRestart Claude Code before the new skills load.%s\n' \
                "$C_BOLD" "$C_YELLOW" "$C_RESET"
            cat <<'EOF'
  ~/.claude/skills/ did not exist when your current session started, so Claude
  Code is not watching it. Skills added later are normally picked up live, but
  only in a directory that was there at startup. Quit and restart, then check
  with /context or /skills.
EOF
        elif [[ $id == cursor && $existed == 0 ]]; then
            printf '\n%s%sReload Cursor so it sees ~/.cursor/skills/.%s\n' \
                "$C_BOLD" "$C_YELLOW" "$C_RESET"
            cat <<'EOF'
  Cursor discovers skills at startup. A first install creates ~/.cursor/skills/,
  so a reload or restart is the sure way to pick them up. Hooks in
  ~/.cursor/hooks.json reload on their own.
EOF
        elif [[ $id == codex && $existed == 0 ]]; then
            printf '\n%s%sRestart Codex so it sees ~/.agents/skills/.%s\n' \
                "$C_BOLD" "$C_YELLOW" "$C_RESET"
            cat <<'EOF'
  Codex loads personal skills from ~/.agents/skills. Trust the new PostToolUse
  hook with /hooks before it will run; untrusted hooks are skipped.
EOF
        fi
    done
}

# ----------------------------------------------------------------- main ----

main() {
    declare -gA SKILLS_DIR_EXISTED=()

    printf '%sbotkit%s — installing into %s\n\n' "$C_BOLD" "$C_RESET" "$HOME"
    (( DRY_RUN )) && info "dry run: nothing will be written" && info ""

    BOTKIT_INSTALLING=1
    preflight
    init_notes
    init_references
    install_bot
    install_precommit_hook

    select_agents

    if (( ${#APPLIED_AGENTS[@]} == 0 )); then
        warn "no known agent found on this machine"
        if (( ${#LOOKED_FOR_AGENTS[@]} )); then
            info "looked for: ${LOOKED_FOR_AGENTS[*]}"
        else
            info "looked for: none"
        fi
        info "installing the agent-neutral pieces anyway (AGENTS.md, bot, notes)"
    else
        step "Detected agents"
        local id
        for id in "${APPLIED_AGENTS[@]}"; do
            ok "${AGENT_LABEL[$id]}"
            if agent_has_cap "$id" skills && [[ -n ${AGENT_SKILLS_PATHS[$id]:-} ]]; then
                [[ -d ${AGENT_SKILLS_PATHS[$id]} ]] && SKILLS_DIR_EXISTED[$id]=1 || SKILLS_DIR_EXISTED[$id]=0
            fi
        done
    fi

    BOTKIT_SKILLS_STAGE="$(mktemp -d)" || die "mktemp -d failed"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$BOTKIT_SKILLS_STAGE'" EXIT

    stage_own_skills
    if (( DO_SKILLS )); then
        stage_pstack_skills
        stage_robotics_skills
    else
        step "Skipping third-party skills (--no-skills)"
    fi

    apply_generic_agent
    apply_selected_agents

    acting "write $UNSLOP_CONF" && write_unslop_conf

    if (( ! DRY_RUN )); then
        local id
        for id in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
            agent_has_cap "$id" skills || continue
            [[ -n ${AGENT_SKILLS_PATHS[$id]:-} ]] || continue
            step "Skills present in ${AGENT_SKILLS_PATHS[$id]}"
            local expected name
            expected=()
            local src
            shopt -s nullglob
            for src in "$SKILLS_SRC_DIR"/*/; do
                [[ -f "$src/SKILL.md" ]] && expected+=("$(basename -- "$src")")
            done
            shopt -u nullglob
            (( DO_SKILLS )) && expected+=("${PSTACK_SKILLS[@]}" "${ROBOTICS_SKILLS[@]}")
            for name in "${expected[@]}"; do
                if [[ -f "${AGENT_SKILLS_PATHS[$id]}/$name/SKILL.md" ]]; then
                    ok "$name"
                else
                    warn "$name is MISSING"
                fi
            done
        done
    fi

    printf '\n%s==> Done%s\n\n' "$C_BOLD" "$C_RESET"

    if (( DRY_RUN )); then
        info "Dry run: nothing was written."
    elif (( ${#CHANGED[@]} )); then
        info "Changed:"
        printf "  - %s\n" "${CHANGED[@]}"
    else
        info "Nothing changed. Everything was already in place."
    fi

    (( DRY_RUN )) || print_capability_report
    (( DRY_RUN )) || print_restart_notes

    printf '\n%sStill yours to do:%s\n' "$C_BOLD" "$C_RESET"
    if (( ${#MANUAL[@]} )); then
        printf '  - %s\n' "${MANUAL[@]}"
    fi
    cat <<EOF
  - Add a robot:  cp bots/example.conf bots/<name>.conf
                  # gitignored. do not commit it. do not edit example.conf.
                  bot probe <name>      # then choose REMOTE_MOUNT yourself
                  bot up <name>
  - Start the agent from ~/dev/<name>/, never from mount/, and not from this
    checkout.

Keep this checkout where it is: ~/.local/bin/bot and the settings hook both
point at $BOTKIT_ROOT. If you move it, re-run ./install.sh.
EOF
}

main "$@"
