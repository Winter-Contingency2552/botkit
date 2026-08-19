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
CLAUDE_DIR="$HOME/.claude"
SETTINGS_JSON="$CLAUDE_DIR/settings.json"
SKILLS_DIR="$CLAUDE_DIR/skills"
PROVENANCE="$SKILLS_DIR/.botkit-provenance"
UNSLOP_CONF="$CLAUDE_DIR/botkit-unslop.conf"
BIN_DIR="$HOME/.local/bin"

# Defaults applied when a bot config leaves a field out.
DEFAULT_SEARCH_EXCLUDE="build install log .ros bags *.bag *.mcap *.pt *.onnx .cache .git"

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

# Source bots/<name>.conf and validate it. Sets the BOT_* variables in the
# caller's shell. Dies on anything malformed rather than half-configuring.
load_bot_conf() {
    local name="$1" conf

    [[ $name =~ ^[A-Za-z0-9_-]+$ ]] ||
        die "invalid bot name '$name' (allowed: letters, digits, dash, underscore)"

    conf="$BOTS_DIR/$name.conf"
    [[ -f $conf ]] ||
        die "no config for '$name': expected $conf (copy bots/example.conf to start)"

    BOT_NAME='' BOT_HOST='' BOT_USER='' REMOTE_MOUNT='' MOUNT_POINT=''
    REMOTE_WS='' BUILD_CMD='' SOURCE_CMD='' SEARCH_EXCLUDE=''

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

    : "${MOUNT_POINT:=$DEV_DIR/$name}"
    : "${SEARCH_EXCLUDE:=$DEFAULT_SEARCH_EXCLUDE}"

    [[ $MOUNT_POINT == /* ]] || die "$conf: MOUNT_POINT must be an absolute path"
    [[ -z $REMOTE_MOUNT || $REMOTE_MOUNT == /* ]] || die "$conf: REMOTE_MOUNT must be an absolute path"
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

# Apply a jq filter to ~/.claude/settings.json. Extra arguments are passed
# through to jq (--arg, --argjson). Writes atomically via a temp file in the
# same directory, so an interrupted run can never leave a truncated settings
# file behind.
settings_json_edit() {
    local filter="$1"; shift
    local tmp

    require_cmd jq
    mkdir -p -- "$CLAUDE_DIR"
    [[ -f $SETTINGS_JSON ]] || printf '{}\n' > "$SETTINGS_JSON"

    jq -e . "$SETTINGS_JSON" >/dev/null 2>&1 ||
        die "$SETTINGS_JSON is not valid JSON — fix it by hand before re-running"

    tmp="$(mktemp -- "$CLAUDE_DIR/.settings.botkit.XXXXXX")" || die "mktemp failed"
    if jq "$@" "$filter" "$SETTINGS_JSON" > "$tmp"; then
        mv -- "$tmp" "$SETTINGS_JSON"
    else
        rm -f -- "$tmp"
        die "failed to update $SETTINGS_JSON"
    fi
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

    mv -- "$tmp" "$UNSLOP_CONF"
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
