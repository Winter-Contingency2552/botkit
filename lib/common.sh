# shellcheck shell=bash
#
# botkit shared library. Sourced by install.sh, uninstall.sh, and scripts/bot.
# Ubuntu + bash only. Not sh-compatible, not tested on macOS or zsh.

# Paths are derived from HOME at source time so that running with an overridden
# HOME (the sandboxed install test) redirects everything consistently.
BOTKIT_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)"
BOTS_DIR="$BOTKIT_ROOT/bots"
TEMPLATES_DIR="$BOTKIT_ROOT/templates"
SKILLS_SRC_DIR="$BOTKIT_ROOT/skills"
HOOKS_DIR="$BOTKIT_ROOT/hooks"

DEV_DIR="$HOME/dev"
NOTES_DIR="$DEV_DIR/notes"
AGENTS_MD="$DEV_DIR/AGENTS.md"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"
SKILLS_DIR="$CLAUDE_DIR/skills"
PROVENANCE="$SKILLS_DIR/.botkit-provenance"
UNSLOP_CONF="$CLAUDE_DIR/botkit-unslop.conf"
BIN_DIR="$HOME/.local/bin"
AGENTS_DIR="$BOTKIT_ROOT/lib/agents"

# Defaults applied when a bot config leaves a field out.
DEFAULT_SEARCH_EXCLUDE="build install log .ros bags *.bag *.mcap *.pt *.onnx .cache .git"

BOTKIT_BEGIN='<!-- botkit:begin generated -->'
BOTKIT_END='<!-- botkit:end generated -->'

# Installer state. install.sh sets these; bot and uninstall leave the defaults.
DRY_RUN="${DRY_RUN:-0}"
FORCE_AGENT="${FORCE_AGENT:-}"
BOTKIT_INSTALLING="${BOTKIT_INSTALLING:-0}"
BOTKIT_SKILLS_STAGE="${BOTKIT_SKILLS_STAGE:-}"
DO_PLUGINS="${DO_PLUGINS:-1}"
CHANGED=()
MANUAL=()
PROV_LINES=()
APPLIED_AGENTS=()
LOOKED_FOR_AGENTS=()
declare -A AGENT_LABEL=() AGENT_CAPS=() AGENT_CONTEXT=() AGENT_SKILLS_PATHS=()

# ---------------------------------------------------------------- output ----

if [[ -t 1 && -z ${NO_COLOR:-} ]]; then
    C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BOLD=$'\033[1m'
else
    C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BOLD=''
fi

info() { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_BOLD" "$C_RESET" "$*"; }
ok()   { printf '  %sok%s   %s\n' "$C_GREEN" "$C_RESET" "$*"; }
skip() { printf '  %s--%s   %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '  %swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }

# Every failure exits nonzero with a single line. No silent partial states.
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

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

# ------------------------------------------------------------ bot configs ----

list_bots() {
    local path name
    shopt -s nullglob
    for path in "$BOTS_DIR"/*.conf; do
        name="$(basename -- "$path" .conf)"
        [[ $name == example ]] && continue
        printf '%s\n' "$name"
    done
    shopt -u nullglob
}

# example.conf is the tracked template. Using it as a live bot would put a
# real host in a file git is willing to commit.
check_not_example_bot() {
    [[ $1 != example ]] ||
        die "example.conf is the tracked template. Copy it to bots/<name>.conf and use that name"
}

# Die if a real bot conf is tracked in this checkout. gitignore is the fence;
# this is the alarm if the fence was climbed.
check_no_tracked_real_bot_confs() {
    local f base
    command -v git >/dev/null 2>&1 || return 0
    [[ -d $BOTKIT_ROOT/.git ]] || return 0
    while IFS= read -r f; do
        [[ -n $f ]] || continue
        base="$(basename -- "$f")"
        [[ $base == example.conf ]] && continue
        die "tracked bot config $f — that publishes a hostname. Untrack it with: git rm --cached -- $f"
    done < <(git -C "$BOTKIT_ROOT" ls-files -- 'bots/*.conf')
}

# Source bots/<name>.conf and validate it. Sets the BOT_* variables in the
# caller's shell. Dies on anything malformed rather than half-configuring.
load_bot_conf() {
    local name="$1" conf

    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] ||
        die "invalid bot name '$name' (allowed: letters, digits, dash, underscore)"
    check_not_example_bot "$name"

    conf="$BOTS_DIR/$name.conf"
    [[ -f $conf ]] ||
        die "no config for '$name': expected $conf (copy bots/example.conf to start)"

    BOT_NAME='' BOT_HOST='' BOT_USER='' REMOTE_MOUNT='' MOUNT_POINT='' BOT_DIR=''
    REMOTE_WS='' BUILD_CMD='' SOURCE_CMD='' SEARCH_EXCLUDE='' LOCAL_REPOS=''

    # shellcheck disable=SC1090  # path is built from a validated bot name
    source "$conf" || die "failed to read $conf"

    [[ -n $BOT_HOST ]] || die "$conf: BOT_HOST is required"
    [[ -n $BOT_USER ]] || die "$conf: BOT_USER is required"

    : "${BOT_NAME:=$name}"
    [[ $BOT_NAME == "$name" ]] ||
        die "$conf: BOT_NAME is '$BOT_NAME' but the file is named '$name.conf' — they must match"

    # REMOTE_MOUNT has no default on purpose. What to mount is a per-robot
    # decision that depends on that robot's actual layout -- where the workspace
    # lives, how much build output and how many bags sit under the home
    # directory. Run `bot probe <name>` to gather the evidence, decide, and
    # record the reason in notes/<name>/decisions.md.
    [[ -n $REMOTE_MOUNT || ${BOTKIT_LENIENT_CONF:-0} == 1 ]] ||
        die "$conf: REMOTE_MOUNT is required -- run 'bot probe $name' to see the robot's layout, then set it"

    # Laptop project root. Not a mount. bot up creates it.
    #   ~/dev/<name>/mount     sshfs
    #   ~/dev/<name>/<repo>    LOCAL_REPOS clones
    BOT_DIR="$DEV_DIR/$name"
    : "${MOUNT_POINT:=$BOT_DIR/mount}"
    : "${SEARCH_EXCLUDE:=$DEFAULT_SEARCH_EXCLUDE}"
    : "${LOCAL_REPOS:=}"

    local repo
    # shellcheck disable=SC2086
    for repo in $LOCAL_REPOS; do
        [[ $repo =~ ^[A-Za-z0-9_-]+$ ]] ||
            die "$conf: LOCAL_REPOS entry '$repo' is not a valid name (letters, digits, dash, underscore)"
        [[ $repo != "$name" ]] ||
            die "$conf: LOCAL_REPOS cannot include the bot's own name '$name'"
        case "$repo" in
            mount|notes|docs)
                die "$conf: LOCAL_REPOS cannot include '$repo' (reserved under ~/dev/$name/)" ;;
        esac
    done

    [[ $MOUNT_POINT == /* ]] || die "$conf: MOUNT_POINT must be an absolute path"
    [[ -z $REMOTE_MOUNT || $REMOTE_MOUNT == /* ]] || die "$conf: REMOTE_MOUNT must be an absolute path"
}

# Create ~/dev/<name>/ as a laptop project: mount subdir, notes symlink, Matt
# skill stand-ins, LOCAL_REPOS clones moved in from ~/dev/<repo> if they were
# left at the old location. Never writes into a live mount.
ensure_bot_workspace() {
    local repo dest old

    if is_mounted "$BOT_DIR"; then
        die "$BOT_DIR is a mount from an older layout. Run 'bot down $BOT_NAME', then 'bot up $BOT_NAME'. The mount will sit at $BOT_DIR/mount."
    fi

    mkdir -p -- "$BOT_DIR" || die "cannot create project directory $BOT_DIR"
    mkdir -p -- "$MOUNT_POINT" || die "cannot create mount point $MOUNT_POINT"

    ln -sfn -- "../notes/$BOT_NAME" "$BOT_DIR/notes"
    mkdir -p -- "$BOT_DIR/docs"
    ln -sfn -- "../notes/agents" "$BOT_DIR/docs/agents"
    ln -sfn -- "notes/scratch" "$BOT_DIR/.scratch"
    ln -sfn -- "notes/CONTEXT.md" "$BOT_DIR/CONTEXT.md"

    if [[ -f $AGENTS_MD ]]; then
        ln -sfn -- "../AGENTS.md" "$BOT_DIR/AGENTS.md"
        ln -sfn -- "AGENTS.md" "$BOT_DIR/CLAUDE.md"
    fi

    # shellcheck disable=SC2086
    for repo in $LOCAL_REPOS; do
        dest="$BOT_DIR/$repo"
        old="$DEV_DIR/$repo"
        if [[ -e $dest ]]; then
            continue
        fi
        if [[ -e $old ]]; then
            if is_mounted "$old"; then
                die "$old is a mount. Not moving it into $dest."
            fi
            mv -- "$old" "$dest" || die "could not move $old to $dest"
            ok "moved $old -> $dest"
        else
            warn "clone $repo to $dest"
        fi
    done
}

# ---------------------------------------------------------------- mounts ----

# Read /proc/mounts rather than calling mountpoint(1) or stat(1). A wedged sshfs
# blocks any syscall against the mount forever, and this check has to stay
# answerable when that has happened. /proc/mounts encodes spaces as \040.
is_mounted() {
    awk -v target="$1" '
        { p = $2; gsub(/\\040/, " ", p); if (p == target) found = 1 }
        END { exit !found }
    ' /proc/mounts 2>/dev/null
}

# Does the mount actually answer? A readdir forces a round trip to the robot,
# where stat-ing the mount point alone can be served from the kernel cache.
mount_live() {
    timeout -k 1 5 ls -A -- "$1" >/dev/null 2>&1
}

bot_reachable() {
    timeout -k 1 10 ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new \
        "$1@$2" true >/dev/null 2>&1
}

# ------------------------------------------------------------- settings ----

# Apply a jq filter to a JSON file. Extra arguments after the filter are
# passed through to jq (--arg, --argjson). Writes atomically via a temp file
# in the same directory, so an interrupted run can never leave a truncated
# file behind.
json_file_edit() {
    local file="$1" filter="$2"; shift 2
    local dir tmp

    require_cmd jq
    dir="$(dirname -- "$file")"
    mkdir -p -- "$dir"
    [[ -f $file ]] || printf '{}\n' > "$file"

    jq -e . "$file" >/dev/null 2>&1 ||
        die "$file is not valid JSON — fix it by hand before re-running"

    tmp="$(mktemp -- "$dir/.botkit.XXXXXX")" || die "mktemp failed"
    if jq "$@" "$filter" "$file" > "$tmp"; then
        _commit_tmp_file "$tmp" "$file"
    else
        rm -f -- "$tmp"
        die "failed to update $file"
    fi
}

# mv is atomic on the same filesystem, but it fails with "Device or resource
# busy" if another process has the destination inode open. Fall back to
# overwriting in place.
_commit_tmp_file() {
    local tmp="$1" dest="$2"
    if mv -- "$tmp" "$dest" 2>/dev/null; then
        return 0
    fi
    cat -- "$tmp" > "$dest" || { rm -f -- "$tmp"; die "failed to update $dest"; }
    rm -f -- "$tmp"
}

settings_json_edit() {
    json_file_edit "$SETTINGS_JSON" "$@"
}

# Copy file to file.botkit-bak once, and refresh file.botkit-prev every call.
# The .bak is the genuine pre-botkit state and is what uninstall restores.
backup_once() {
    local file="$1"
    [[ -f $file ]] || return 0
    if [[ ! -f "$file.botkit-bak" ]]; then
        cp -- "$file" "$file.botkit-bak"
        ok "backed up $(basename -- "$file") -> $(basename -- "$file").botkit-bak"
    else
        skip "$(basename -- "$file").botkit-bak already exists (kept — it is the pre-botkit state)"
    fi
    cp -- "$file" "$file.botkit-prev"
}

# Turn one SEARCH_EXCLUDE list into Claude Code permission deny rules.
#
# Only Read() rules are generated. Read deny rules use gitignore syntax, cover
# Read/Grep/Glob and the file-reading Bash commands Claude Code recognises, and
# also block Edit and Write on the same path. Glob() and Write() path rules are
# accepted by Claude Code but never consulted, so writing those would be a
# silent no-op.
search_deny_rules() {
    local mount_point="$1" exclude_list="$2" pattern
    # shellcheck disable=SC2086  # word splitting is how the list is expressed
    for pattern in $exclude_list; do
        case "$pattern" in
            *'*'*) printf 'Read(//%s/**/%s)\n'    "${mount_point#/}" "$pattern" ;;
            *)     printf 'Read(//%s/**/%s/**)\n' "${mount_point#/}" "$pattern" ;;
        esac
    done
}

# Replace this mount's deny rules in settings.json.
#
# JSON has no comments, so ownership is claimed by prefix: botkit owns every
# deny entry starting with "Read(//<mount>/" and rewrites exactly those. Rules
# anywhere else in the array are left untouched. Running this twice produces a
# byte-identical file.
write_search_denies() {
    local mount_point="$1" exclude_list="$2" rules

    rules="$(search_deny_rules "$mount_point" "$exclude_list" | jq -R . | jq -s .)"

    settings_json_edit '
        .permissions //= {}
        | .permissions.deny = (
            ((.permissions.deny // []) | map(select(startswith($prefix) | not)))
            + $rules
          )
    ' --arg prefix "Read(//${mount_point#/}/" --argjson rules "$rules"
}

# Regenerate the file the unslop hook reads. The hook fires on every Write and
# Edit, so it must not source bots/*.conf itself — this collapses all of them
# into one small file it can source in a few microseconds.
write_unslop_conf() {
    local name tmp
    mkdir -p -- "$CLAUDE_DIR"
    tmp="$(mktemp -- "$CLAUDE_DIR/.botkit-unslop.XXXXXX")" || die "mktemp failed"

    {
        printf '# Generated by botkit. Do not edit — regenerated by install.sh and `bot up`.\n'
        printf '# For your own additions, create %s/botkit-unslop.local instead.\n\n' "$CLAUDE_DIR"
        printf 'BOTKIT_MOUNTS=(\n'
        while read -r name; do
            ( load_bot_conf "$name" >/dev/null 2>&1 && printf '  %q\n' "$MOUNT_POINT" ) || true
        done < <(list_bots)
        printf ')\n\n'
        printf 'BOTKIT_EXCLUDES=(\n'
        {
            # shellcheck disable=SC2086
            printf '%s\n' $DEFAULT_SEARCH_EXCLUDE
            while read -r name; do
                # shellcheck disable=SC2086
                ( load_bot_conf "$name" >/dev/null 2>&1 && printf '%s\n' $SEARCH_EXCLUDE ) || true
            done < <(list_bots)
        } | sort -u | while read -r pattern; do printf '  %q\n' "$pattern"; done
        printf ')\n'
    } > "$tmp"

    _commit_tmp_file "$tmp" "$UNSLOP_CONF"
}

# Content hash of a directory tree. Used to tell an actual change from a re-copy
# of identical bytes, so a second install.sh can report "nothing changed" and be
# telling the truth.
dir_hash() {
    [[ -d $1 ]] || { printf 'absent\n'; return 0; }
    ( cd -- "$1" && find . -type f -print0 | sort -z |
        xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 )
}

file_hash() {
    [[ -f $1 ]] && sha256sum -- "$1" | cut -d' ' -f1 || printf 'absent\n'
}

# -------------------------------------------------------------- agents ----

list_agent_adapters() {
    local path base
    local -a names=()
    shopt -s nullglob
    for path in "$AGENTS_DIR"/*.sh; do
        base="$(basename -- "$path" .sh)"
        [[ $base == generic ]] && continue
        names+=("$base")
    done
    shopt -u nullglob
    ((${#names[@]})) || return 0
    printf '%s\n' "${names[@]}" | sort
}

load_agent() {
    local name="$1"
    [[ -f "$AGENTS_DIR/$name.sh" ]] || die "no agent adapter: $name"
    # shellcheck disable=SC1090
    source "$AGENTS_DIR/$name.sh"
}

agent_has_cap() {
    local id="$1" cap="$2"
    [[ " ${AGENT_CAPS[$id]:-} " == *" $cap "* ]]
}

# Populate APPLIED_AGENTS from adapters on disk. With FORCE_AGENT set, that
# adapter is applied even if it is not detected. generic.sh is not in this
# list; callers always run it separately.
select_agents() {
    APPLIED_AGENTS=()
    LOOKED_FOR_AGENTS=()
    AGENT_LABEL=()
    AGENT_CAPS=()
    AGENT_CONTEXT=()
    AGENT_SKILLS_PATHS=()

    local name take
    while read -r name; do
        LOOKED_FOR_AGENTS+=("$name")
        load_agent "$name"
        take=0
        if [[ -n $FORCE_AGENT ]]; then
            [[ $name == "$FORCE_AGENT" ]] && take=1
        elif agent_detect; then
            take=1
        fi
        if (( take )); then
            APPLIED_AGENTS+=("$name")
            AGENT_LABEL[$name]="$(agent_label)"
            AGENT_CAPS[$name]="$(agent_capabilities | tr '\n' ' ')"
            AGENT_CONTEXT[$name]="${AGENT_CONTEXT_FILE:-AGENTS.md}"
            AGENT_SKILLS_PATHS[$name]="${AGENT_SKILLS_PATH:-}"
        fi
    done < <(list_agent_adapters)

    if [[ -n $FORCE_AGENT ]]; then
        local found=0 n
        for n in ${LOOKED_FOR_AGENTS[@]+"${LOOKED_FOR_AGENTS[@]}"}; do
            [[ $n == "$FORCE_AGENT" ]] && found=1
        done
        (( found )) || die "unknown --agent $FORCE_AGENT (have: ${LOOKED_FOR_AGENTS[*]})"
    fi
}

apply_generic_agent() {
    load_agent generic
    agent_apply
}

apply_selected_agents() {
    local name
    for name in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
        load_agent "$name"
        agent_apply
    done
}

revert_selected_agents() {
    local name
    for name in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
        load_agent "$name"
        agent_revert
    done
}

count_skill_dirs() {
    local dir="$1" n=0
    [[ -d $dir ]] || { printf '0\n'; return 0; }
    local path
    shopt -s nullglob
    for path in "$dir"/*/SKILL.md; do
        n=$((n + 1))
    done
    shopt -u nullglob
    printf '%s\n' "$n"
}

# Copy one skill directory into dest, replacing any previous copy.
# Returns 0 if the skill changed on disk, 3 if it was already identical,
# 1 if it could not be installed at all.
copy_skill_to() {
    local dest="$1" name="$2" src="$3" before after
    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || die "refusing to install skill with odd name: $name"
    [[ -d $src ]] || { warn "skill '$name' not found at $src — skipped"; return 1; }
    before="$(dir_hash "$dest/$name")"
    rm -rf -- "${dest:?}/$name"
    mkdir -p -- "$dest"
    cp -R -- "$src" "$dest/$name" || { warn "failed to copy skill $name"; return 1; }
    after="$(dir_hash "$dest/$name")"
    [[ $before == "$after" ]] && return 3
    return 0
}

# One place to turn a copy_skill_to result into output and a change record.
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

# The provenance file is what uninstall reads to decide what it may remove,
# so it has to describe everything botkit currently has installed, not just
# what this run happened to touch. A run with --no-skills must not erase the
# record of skills installed by an earlier run, or uninstall would orphan them.
write_provenance_to() {
    local dest="$1"
    acting "write $dest" || return 0

    local -A handled=()
    local line name
    for line in ${PROV_LINES[@]+"${PROV_LINES[@]}"}; do
        handled["${line%%$'\t'*}"]=1
    done

    local -a kept=()
    if [[ -f $dest ]]; then
        while IFS= read -r line; do
            [[ -z $line || $line == \#* ]] && continue
            name="${line%%$'\t'*}"
            [[ -n ${handled[$name]:-} ]] && continue
            [[ -d "$(dirname -- "$dest")/$name" ]] || continue
            kept+=("$line")
        done < "$dest"
    fi

    (( ${#kept[@]} + ${#PROV_LINES[@]} )) || return 0

    local -a entries=()
    entries+=(${kept[@]+"${kept[@]}"})
    entries+=(${PROV_LINES[@]+"${PROV_LINES[@]}"})
    local new_body old_body
    new_body="$(printf '%s\n' "${entries[@]}")"
    if [[ -f $dest ]]; then
        old_body="$(awk '!/^#/ && NF' "$dest")"
        if [[ $old_body == "$new_body" ]]; then
            skip "$dest is current"
            return 0
        fi
    fi

    mkdir -p -- "$(dirname -- "$dest")"
    {
        printf '# Installed by botkit. Last updated %s\n' "$(date -Iseconds)"
        printf '# skill\tsource\tcommit\n'
        printf '%s\n' ${kept[@]+"${kept[@]}"} ${PROV_LINES[@]+"${PROV_LINES[@]}"}
    } > "$dest"
}

install_skills_from_stage() {
    local dest="$1" label="${2:-}"
    [[ -n ${BOTKIT_SKILLS_STAGE:-} && -d $BOTKIT_SKILLS_STAGE ]] || return 0
    acting "copy staged skills -> $dest" || return 0

    local src name rc
    mkdir -p -- "$dest"
    shopt -s nullglob
    for src in "$BOTKIT_SKILLS_STAGE"/*/; do
        [[ -d $src ]] || continue
        name="$(basename -- "$src")"
        copy_skill_to "$dest" "$name" "$src"
        rc=$?
        if [[ -n $label ]]; then
            case "$rc" in
                0) ok "$label: $name"; note_change "installed skill: $name -> $dest" ;;
                3) skip "$label: $name is up to date" ;;
            esac
        else
            report_skill "$rc" "$name" "staged" local
        fi
    done
    shopt -u nullglob

    write_provenance_to "$dest/.botkit-provenance"
}

remove_skills_from_provenance() {
    local dest="$1"
    local prov="$dest/.botkit-provenance"
    if [[ ! -f $prov ]]; then
        warn "no provenance file at $prov — no skills removed"
        warn "remove them by hand if you want them gone: ls $dest"
        return 0
    fi
    local name
    while IFS=$'\t' read -r name _source _commit; do
        [[ -z $name || $name == \#* ]] && continue
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || { warn "odd skill name in provenance, skipping: $name"; continue; }
        if [[ -d "$dest/$name" ]]; then
            rm -rf -- "${dest:?}/$name"; ok "removed skill $name"
        else
            skip "skill $name already gone"
        fi
    done < "$prov"
    rm -f -- "$prov"
}

restore_json_backup() {
    local file="$1"
    if [[ -f "$file.botkit-bak" ]]; then
        cp -- "$file" "$file.botkit-uninstall-prev" 2>/dev/null
        mv -- "$file.botkit-bak" "$file"
        ok "restored $(basename -- "$file") from $(basename -- "$file").botkit-bak"
        info "  (your pre-uninstall version is at $(basename -- "$file").botkit-uninstall-prev)"
        return 0
    fi
    return 1
}

# ------------------------------------------------------- AGENTS.md block ----

strip_generated_block() {
    awk -v begin="$BOTKIT_BEGIN" -v end="$BOTKIT_END" '
        $0 == begin { skip = 1; next }
        $0 == end   { skip = 0; next }
        skip { next }
        { print }
    ' "$1"
}

agents_static_differs() {
    local src="$1" dst="$2"
    local a b
    a="$(strip_generated_block "$src")"
    b="$(strip_generated_block "$dst")"
    [[ $a != "$b" ]]
}

# Enforcement line for one applied agent. Names what is a hook or deny rule
# and what is only an instruction in this file.
generated_enforcement_line() {
    local id="$1"
    local label="${AGENT_LABEL[$id]}"
    local hook='written down' excl='written down'
    agent_has_cap "$id" hooks && hook='enforced (a hook nudge; it cannot apply the skill itself)'
    agent_has_cap "$id" exclusions && excl='enforced (deny rules)'
    printf -- '- %s. Search exclusions: %s. unslop: %s.\n' "$label" "$excl" "$hook"
}

_load_bot_for_generate() {
    local name="$1"
    ( BOTKIT_LENIENT_CONF=1 load_bot_conf "$name" ) >/dev/null 2>&1 || return 1
    BOTKIT_LENIENT_CONF=1 load_bot_conf "$name"
}

generated_agents_body() {
    local name any=0 repo path status

    printf '## Generated for this machine\n\n'
    printf 'botkit writes this block. Edit outside the markers. install.sh and `bot up` regenerate everything in between.\n\n'

    printf '### Projects\n\n'
    while read -r name; do
        if _load_bot_for_generate "$name"; then
            any=1
            printf -- '- `%s` at `%s`. Mount: `%s`.\n' "$name" "$BOT_DIR" "$MOUNT_POINT"
        fi
    done < <(list_bots)
    if (( ! any )); then
        printf 'No bots configured yet. Copy `bots/example.conf` to `bots/<name>.conf`.\n'
    fi
    printf '\n'

    printf '### Associated local repos\n\n'
    printf 'Laptop clones that belong with a robot. Not mounts. They live inside that bot'\''s project folder. Build and edit these locally. When working on the bot, read these too. When working on one of these, read the bot.\n\n'
    any=0
    while read -r name; do
        if _load_bot_for_generate "$name"; then
            # shellcheck disable=SC2086
            for repo in $LOCAL_REPOS; do
                any=1
                path="$BOT_DIR/$repo"
                if [[ -d $path ]]; then
                    status="at \`$path\`"
                else
                    status="listed, not cloned yet (clone it to \`$path\`)"
                fi
                printf -- '- `%s` belongs with bot `%s` (%s). Notes: `notes/%s/`.\n' "$repo" "$name" "$status" "$repo"
            done
        fi
    done < <(list_bots)
    if (( ! any )); then
        printf 'None. Set `LOCAL_REPOS=gui` in a bot conf, then clone the GUI to `~/dev/<bot>/gui`.\n'
    fi
    printf '\n'

    printf '### Paths not to search\n\n'
    printf 'Build artifacts, bags, and weights. Searching them is slow and they are not source.\n\n'
    any=0
    while read -r name; do
        if _load_bot_for_generate "$name"; then
            any=1
            printf -- '- `%s` at `%s`: `%s`\n' "$name" "$MOUNT_POINT" "$SEARCH_EXCLUDE"
        fi
    done < <(list_bots)
    if (( ! any )); then
        printf 'None yet. They appear here once a bot is configured.\n'
    fi
    printf '\n'

    printf '### unslop\n\n'
    printf 'When you write user-facing prose (markdown, rst, txt, anything under docs/), apply the unslop skill to it before continuing. Skip `progress.md`, `inbox/`, and anything under a mount.\n\n'

    printf '### What is enforced, and what is only written down\n\n'
    printf 'A line in this file is an instruction. You may ignore it. A hook or a deny rule is enforced by the agent. They are not the same.\n\n'

    local id
    for id in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
        generated_enforcement_line "$id"
    done
    printf -- '- Any other agent. Everything in this block is an instruction only. Skills are not installed for it.\n'
}

# Replace the marked region in AGENTS.md. If the markers are missing, append
# them. Returns 0 if the file changed, 3 if it was already identical.
replace_generated_block() {
    local file="$1"
    local bodyfile tmp
    [[ -f $file ]] || return 1

    bodyfile="$(mktemp)" || die "mktemp failed"
    generated_agents_body > "$bodyfile"
    tmp="$(mktemp -- "$(dirname -- "$file")/.agents.botkit.XXXXXX")" || die "mktemp failed"

    if awk -v begin="$BOTKIT_BEGIN" -v end="$BOTKIT_END" '
            $0 == begin { b = 1 }
            $0 == end   { e = 1 }
            END { exit !(b && e) }
        ' "$file"; then
        awk -v begin="$BOTKIT_BEGIN" -v end="$BOTKIT_END" -v bodyfile="$bodyfile" '
            $0 == begin {
                print
                while ((getline line < bodyfile) > 0) print line
                close(bodyfile)
                skip = 1
                next
            }
            $0 == end { skip = 0; print; next }
            skip { next }
            { print }
        ' "$file" > "$tmp"
    else
        cat -- "$file" > "$tmp"
        printf '\n%s\n' "$BOTKIT_BEGIN" >> "$tmp"
        cat -- "$bodyfile" >> "$tmp"
        printf '%s\n' "$BOTKIT_END" >> "$tmp"
    fi
    rm -f -- "$bodyfile"

    if cmp -s -- "$file" "$tmp"; then
        rm -f -- "$tmp"
        return 3
    fi
    _commit_tmp_file "$tmp" "$file"
    return 0
}

regenerate_agents_md() {
    [[ -f $AGENTS_MD ]] || return 0
    acting "regenerate generated block in $AGENTS_MD" || return 0
    replace_generated_block "$AGENTS_MD"
    case $? in
        0) ok "regenerated generated block in ~/dev/AGENTS.md"; note_change "regenerated ~/dev/AGENTS.md generated block" ;;
        3) skip "~/dev/AGENTS.md generated block is current" ;;
    esac
}
