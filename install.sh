#!/usr/bin/env bash
#
# botkit installer. Idempotent: re-running upgrades scripts and skills, and
# never overwrites ~/dev/CLAUDE.md or anything under ~/dev/notes/.
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

# The marketplace manifest names itself "mattpocock", so the plugin id is
# mattpocock-skills@mattpocock -- not @skills.
MP_SOURCE='mattpocock/skills'
MP_MARKETPLACE='mattpocock'
MP_PLUGIN='mattpocock-skills@mattpocock'

DEPENDENCIES=(sshfs jq git ssh claude)

# ----------------------------------------------------------------- flags ----

DO_PLUGINS=1
DO_SKILLS=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-plugins) DO_PLUGINS=0 ;;
        --no-skills)  DO_SKILLS=0 ;;
        --dry-run)    DRY_RUN=1 ;;
        -h|--help)
            cat <<'USAGE'
usage: ./install.sh [options]

  --no-plugins   skip the mattpocock marketplace plugin step
  --no-skills    skip all third-party skill downloads (offline install)
  --dry-run      report what would change, change nothing
USAGE
            exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

CHANGED=()
MANUAL=()
note_change() { CHANGED+=("$1"); }
note_manual() { MANUAL+=("$1"); }

# A single place to ask "am I allowed to touch the disk". Each step detects and
# reports its own state first, then calls this.
acting() {
    if (( DRY_RUN )); then
        printf '  %swould%s %s\n' "$C_YELLOW" "$C_RESET" "$1"
        return 1
    fi
    return 0
}

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
                claude) warn "missing claude — install Claude Code: https://claude.com/claude-code" ;;
                *)      warn "missing $cmd" ;;
            esac
        done
        die "install the commands above and re-run"
    fi

    # jq in particular is load-bearing: the settings merge refuses to do text
    # surgery on JSON without it.
    step "Checking PATH"
    case ":$PATH:" in
        *":$BIN_DIR:"*) ok "$BIN_DIR is on PATH" ;;
        *)
            warn "$BIN_DIR is not on PATH — the 'bot' command will not be found"
            note_manual "add to ~/.bashrc:  export PATH=\"\$HOME/.local/bin:\$PATH\""
            ;;
    esac
}

# ------------------------------------------------------------- workspace ----

install_claude_md() {
    step "Installing ~/dev/CLAUDE.md"
    local src="$TEMPLATES_DIR/CLAUDE.md" dst="$DEV_DIR/CLAUDE.md"

    acting "create $DEV_DIR" && mkdir -p -- "$DEV_DIR"

    if [[ ! -f $dst ]]; then
        acting "write $dst" || return 0
        cp -- "$src" "$dst"
        ok "wrote $dst"
        note_change "created ~/dev/CLAUDE.md"
    elif cmp -s -- "$src" "$dst"; then
        skip "~/dev/CLAUDE.md is current"
    else
        # Never clobber. It may have been edited on purpose.
        acting "write $dst.new (yours differs from the template)" || return 0
        cp -- "$src" "$dst.new"
        warn "~/dev/CLAUDE.md differs from the template — wrote ~/dev/CLAUDE.md.new instead"
        note_change "wrote ~/dev/CLAUDE.md.new (yours was left alone)"
        note_manual "diff ~/dev/CLAUDE.md ~/dev/CLAUDE.md.new  and merge what you want"
    fi
}

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

# ---------------------------------------------------------------- skills ----

PROV_LINES=()

# Copy one skill directory into ~/.claude/skills, replacing any previous copy.
# Returns 0 if the skill changed on disk, 3 if it was already identical,
# 1 if it could not be installed at all.
copy_skill() {
    local name="$1" src="$2" before after
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "refusing to install skill with odd name: $name"
    [[ -d $src ]] || { warn "skill '$name' not found at $src — skipped"; return 1; }
    before="$(dir_hash "$SKILLS_DIR/$name")"
    rm -rf -- "${SKILLS_DIR:?}/$name"
    cp -R -- "$src" "$SKILLS_DIR/$name" || { warn "failed to copy skill $name"; return 1; }
    after="$(dir_hash "$SKILLS_DIR/$name")"
    [[ $before == "$after" ]] && return 3
    return 0
}

# One place to turn a copy_skill result into output and a change record.
report_skill() {
    local rc="$1" name="$2" source="$3" commit="$4"
    case "$rc" in
        0) ok "$name"; note_change "installed skill: $name" ;;
        3) skip "$name is up to date" ;;
        *) return 1 ;;
    esac
    PROV_LINES+=("$name	$source	$commit")
    return 0
}

install_wiring() {
    step "Installing the wiring skill"
    acting "copy skills/wiring -> $SKILLS_DIR/wiring" || return 0
    mkdir -p -- "$SKILLS_DIR"
    copy_skill wiring "$SKILLS_SRC_DIR/wiring"
    report_skill "$?" wiring "botkit (this repo)" local
}

install_pstack_skills() {
    step "Installing pstack skills (${PSTACK_SKILLS[*]})"
    # These are Cursor plugin skills, not a Claude Code marketplace, so there is
    # no plugin install path. They are portable SKILL.md directories, so copying
    # them is the whole job.
    acting "clone $PSTACK_REPO and copy ${PSTACK_SKILLS[*]}" || return 0

    local tmp; tmp="$(mktemp -d)" || die "mktemp -d failed"
    # shellcheck disable=SC2064  # expand tmp now, not at trap time
    trap "rm -rf -- '$tmp'" RETURN

    local dir="$tmp/plugins"
    if git clone --depth 1 --filter=blob:none --sparse -q -- "$PSTACK_REPO" "$dir" 2>/dev/null &&
       git -C "$dir" sparse-checkout set pstack/skills >/dev/null 2>&1; then
        :
    elif git clone --depth 1 -q -- "$PSTACK_REPO" "$dir" 2>/dev/null; then
        warn "sparse checkout unavailable — used a full shallow clone instead"
    else
        warn "could not clone $PSTACK_REPO — skipping pstack skills"
        note_manual "pstack skills not installed. Re-run install.sh when you have network."
        return 0
    fi

    local commit; commit="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    mkdir -p -- "$SKILLS_DIR"

    local name
    for name in "${PSTACK_SKILLS[@]}"; do
        copy_skill "$name" "$dir/pstack/skills/$name"
        report_skill "$?" "$name" "$PSTACK_REPO" "$commit"
    done
}

install_robotics_skills() {
    step "Installing robotics skills (${ROBOTICS_SKILLS[*]})"
    acting "fetch $ROBOTICS_REPO at $ROBOTICS_COMMIT and run its installer" || return 0

    local tmp; tmp="$(mktemp -d)" || die "mktemp -d failed"
    # shellcheck disable=SC2064
    trap "rm -rf -- '$tmp'" RETURN

    local dir="$tmp/robotics"
    # Fetch exactly the pinned commit rather than cloning a branch, so the pin
    # is what is downloaded, not just what is checked out afterwards.
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
            return 0
        fi
    fi

    # The pin is a security control, so verify it rather than assuming it.
    local head; head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)"
    [[ $head == "$ROBOTICS_COMMIT" ]] ||
        die "robotics repo checked out $head, expected the audited $ROBOTICS_COMMIT — refusing to install"

    mkdir -p -- "$SKILLS_DIR"

    # The upstream installer copies unconditionally, so hash each skill before
    # and after to find out what genuinely changed.
    local name
    declare -A before=()
    for name in "${ROBOTICS_SKILLS[@]}"; do before[$name]="$(dir_hash "$SKILLS_DIR/$name")"; done

    if bash "$dir/install.sh" --target "$SKILLS_DIR" --skills "${ROBOTICS_SKILLS[@]}" >/dev/null; then
        for name in "${ROBOTICS_SKILLS[@]}"; do
            if [[ "${before[$name]}" == "$(dir_hash "$SKILLS_DIR/$name")" ]]; then
                report_skill 3 "$name" "$ROBOTICS_REPO" "$ROBOTICS_COMMIT"
            else
                report_skill 0 "$name" "$ROBOTICS_REPO" "$ROBOTICS_COMMIT"
            fi
        done
    else
        warn "the robotics repo's installer failed"
        note_manual "robotics skills not installed. Re-run install.sh."
    fi
}

install_plugins() {
    step "Installing mattpocock skills"

    if (( ! DO_PLUGINS )); then
        skip "--no-plugins given"
        return 0
    fi

    local paste="/plugin marketplace add $MP_SOURCE
  /plugin install $MP_PLUGIN"

    acting "claude plugin marketplace add $MP_SOURCE; claude plugin install $MP_PLUGIN" || return 0

    # Probe for the non-interactive path rather than assuming a flag exists.
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

# The provenance file is what uninstall.sh reads to decide what it may remove,
# so it has to describe everything botkit currently has installed -- not just
# what this run happened to touch. A run with --no-skills must not erase the
# record of skills installed by an earlier run, or uninstall would orphan them.
write_provenance() {
    acting "write $PROVENANCE" || return 0

    local -A handled=()
    local line name
    for line in ${PROV_LINES[@]+"${PROV_LINES[@]}"}; do
        handled["${line%%$'\t'*}"]=1
    done

    local -a kept=()
    if [[ -f $PROVENANCE ]]; then
        while IFS= read -r line; do
            [[ -z $line || $line == \#* ]] && continue
            name="${line%%$'\t'*}"
            # Drop what this run rewrote, and anything no longer on disk.
            [[ -n ${handled[$name]:-} ]] && continue
            [[ -d "$SKILLS_DIR/$name" ]] || continue
            kept+=("$line")
        done < "$PROVENANCE"
    fi

    (( ${#kept[@]} + ${#PROV_LINES[@]} )) || return 0

    mkdir -p -- "$SKILLS_DIR"
    {
        printf '# Installed by botkit. Last updated %s\n' "$(date -Iseconds)"
        printf '# skill\tsource\tcommit\n'
        printf '%s\n' ${kept[@]+"${kept[@]}"} ${PROV_LINES[@]+"${PROV_LINES[@]}"}
    } > "$PROVENANCE"
}

report_skills() {
    step "Skills present in $SKILLS_DIR"
    local expected=(wiring "${PSTACK_SKILLS[@]}" "${ROBOTICS_SKILLS[@]}") name
    for name in "${expected[@]}"; do
        if [[ -f "$SKILLS_DIR/$name/SKILL.md" ]]; then
            ok "$name"
        else
            warn "$name is MISSING"
        fi
    done
}

# -------------------------------------------------------------- settings ----

merge_settings() {
    step "Merging hook config into ~/.claude/settings.json"
    local hook="$HOOKS_DIR/unslop-gate.sh"

    [[ -x $hook ]] || die "hook script is not executable: $hook"

    acting "back up settings.json and merge the PostToolUse hook" || return 0

    mkdir -p -- "$CLAUDE_DIR"
    if [[ -f $SETTINGS_JSON ]]; then
        # The .botkit-bak is the genuine pre-botkit state and is what
        # uninstall.sh restores, so it is written once and never overwritten.
        if [[ ! -f "$SETTINGS_JSON.botkit-bak" ]]; then
            cp -- "$SETTINGS_JSON" "$SETTINGS_JSON.botkit-bak"
            ok "backed up settings.json -> settings.json.botkit-bak"
        else
            skip "settings.json.botkit-bak already exists (kept — it is the pre-botkit state)"
        fi
        cp -- "$SETTINGS_JSON" "$SETTINGS_JSON.botkit-prev"
    fi

    # Replace any previous botkit hook entry rather than stacking a duplicate.
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

apply_exclusions() {
    step "Applying search exclusions"
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

    acting "write $UNSLOP_CONF" || return 0
    write_unslop_conf
}

# ----------------------------------------------------------------- main ----

main() {
    printf '%sbotkit%s — installing into %s\n\n' "$C_BOLD" "$C_RESET" "$HOME"
    (( DRY_RUN )) && info "dry run: nothing will be written" && info ""

    preflight
    install_claude_md
    init_notes
    install_bot

    # wiring is botkit's own skill, not a download, so --no-skills does not
    # apply to it. An offline install still gets it.
    install_wiring
    if (( DO_SKILLS )); then
        install_pstack_skills
        install_robotics_skills
    else
        step "Skipping third-party skills (--no-skills)"
    fi
    install_plugins
    write_provenance
    (( DRY_RUN )) || report_skills

    merge_settings
    apply_exclusions

    printf '\n%s==> Done%s\n\n' "$C_BOLD" "$C_RESET"

    if (( DRY_RUN )); then
        info "Dry run: nothing was written."
    elif (( ${#CHANGED[@]} )); then
        info "Changed:"
        printf "  - %s\n" "${CHANGED[@]}"
    else
        info "Nothing changed. Everything was already in place."
    fi

    printf '\n%sStill yours to do:%s\n' "$C_BOLD" "$C_RESET"
    if (( ${#MANUAL[@]} )); then
        printf '  - %s\n' "${MANUAL[@]}"
    fi
    cat <<EOF
  - Add a robot:  cp bots/example.conf bots/<name>.conf
                  bot probe <name>      # then choose REMOTE_MOUNT yourself
                  bot up <name>
  - Start Claude Code from ~/dev, not from a repo below it.

Keep this checkout where it is: ~/.local/bin/bot and the settings hook both
point at $BOTKIT_ROOT. If you move it, re-run ./install.sh.
EOF
}

main "$@"
