#!/usr/bin/env bash
#
# Reverses install.sh. Leaves ~/dev/notes/ alone — see the notice below.

set -uo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

MP_MARKETPLACE='mattpocock'
MP_PLUGIN='mattpocock-skills@mattpocock'

ASSUME_YES=0
KEEP_PLUGINS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       ASSUME_YES=1 ;;
        --keep-plugins) KEEP_PLUGINS=1 ;;
        -h|--help)
            cat <<'USAGE'
usage: ./uninstall.sh [options]

  -y, --yes         do not prompt
  --keep-plugins    leave the mattpocock marketplace and plugin installed
USAGE
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

cat <<EOF
${C_BOLD}botkit uninstall${C_RESET}

This will remove:
  - $BIN_DIR/bot
  - the skills botkit installed into $SKILLS_DIR (only those it recorded)
  - $UNSLOP_CONF
  - the mattpocock marketplace and plugin$( ((KEEP_PLUGINS)) && printf ' (skipped)' )
  - and restore $SETTINGS_JSON from settings.json.botkit-bak

${C_YELLOW}${C_BOLD}~/dev/notes/ is NOT touched.${C_RESET}
That directory is its own git repo. It may have a remote, and it may have
teammates. Nothing here deletes it, and nothing here should. If you really want
it gone, remove it yourself, deliberately, after checking it is pushed.

~/dev/CLAUDE.md is also left in place — it is yours once written.

EOF

if (( ! ASSUME_YES )); then
    read -r -p "Proceed? [y/N] " reply
    [[ ${reply,,} == y* ]] || { info "aborted"; exit 0; }
fi

# ------------------------------------------------------------------ bot ----

step "Removing the bot command"
target="$BIN_DIR/bot"
if [[ -L $target ]]; then
    if [[ "$(readlink -f -- "$target")" == "$(readlink -f -- "$BOTKIT_ROOT/scripts/bot")" ]]; then
        rm -f -- "$target"; ok "removed $target"
    else
        warn "$target points somewhere else — left alone"
    fi
elif [[ -e $target ]]; then
    warn "$target is not a symlink — left alone"
else
    skip "$target is not installed"
fi

# --------------------------------------------------------------- skills ----

step "Removing installed skills"
if [[ -f $PROVENANCE ]]; then
    # Only ever remove what botkit recorded installing. Never a blanket delete
    # of the skills directory — anything else in there belongs to the user.
    while IFS=$'\t' read -r name _source _commit; do
        [[ -z $name || $name == \#* ]] && continue
        [[ $name =~ ^[A-Za-z0-9_-]+$ ]] || { warn "odd skill name in provenance, skipping: $name"; continue; }
        if [[ -d "$SKILLS_DIR/$name" ]]; then
            rm -rf -- "${SKILLS_DIR:?}/$name"; ok "removed skill $name"
        else
            skip "skill $name already gone"
        fi
    done < "$PROVENANCE"
    rm -f -- "$PROVENANCE"
else
    warn "no provenance file at $PROVENANCE — no skills removed"
    warn "remove them by hand if you want them gone: ls $SKILLS_DIR"
fi

[[ -f $UNSLOP_CONF ]] && { rm -f -- "$UNSLOP_CONF"; ok "removed $UNSLOP_CONF"; }

# -------------------------------------------------------------- plugins ----

step "Removing the mattpocock plugin"
if (( KEEP_PLUGINS )); then
    skip "--keep-plugins given"
elif ! command -v claude >/dev/null 2>&1; then
    skip "claude not on PATH"
else
    claude plugin uninstall "$MP_PLUGIN" >/dev/null 2>&1 &&
        ok "uninstalled $MP_PLUGIN" || skip "$MP_PLUGIN was not installed"
    claude plugin marketplace remove "$MP_MARKETPLACE" >/dev/null 2>&1 &&
        ok "removed marketplace $MP_MARKETPLACE" || skip "marketplace $MP_MARKETPLACE was not configured"
fi

# ------------------------------------------------------------- settings ----

step "Restoring settings.json"
if [[ -f "$SETTINGS_JSON.botkit-bak" ]]; then
    cp -- "$SETTINGS_JSON" "$SETTINGS_JSON.botkit-uninstall-prev" 2>/dev/null
    mv -- "$SETTINGS_JSON.botkit-bak" "$SETTINGS_JSON"
    ok "restored settings.json from settings.json.botkit-bak"
    info "  (your pre-uninstall version is at settings.json.botkit-uninstall-prev)"
else
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
fi

printf '\n%s==> Done.%s ~/dev/notes/ was not touched.\n' "$C_BOLD" "$C_RESET"
