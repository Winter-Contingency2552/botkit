#!/usr/bin/env bash
#
# Reverses install.sh. Leaves ~/dev/notes/ alone — see the notice below.

set -uo pipefail

# shellcheck source=lib/common.sh
source "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/lib/common.sh"

ASSUME_YES=0
KEEP_PLUGINS=0
FORCE_AGENT=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)       ASSUME_YES=1 ;;
        --keep-plugins) KEEP_PLUGINS=1 ;;
        --agent)
            [[ -n ${2:-} ]] || die "--agent needs a name"
            FORCE_AGENT="$2"
            shift ;;
        -h|--help)
            cat <<'USAGE'
usage: ./uninstall.sh [options]

  -y, --yes         do not prompt
  --agent NAME      revert only this adapter (leave bot and other agents)
  --keep-plugins    leave the mattpocock marketplace and plugin installed
USAGE
            exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
    shift
done

APPLIED_AGENTS=()
LOOKED_FOR_AGENTS=()
while read -r name; do
    LOOKED_FOR_AGENTS+=("$name")
    if [[ -n $FORCE_AGENT ]]; then
        [[ $name == "$FORCE_AGENT" ]] && APPLIED_AGENTS+=("$name")
    else
        APPLIED_AGENTS+=("$name")
    fi
done < <(list_agent_adapters)

if [[ -n $FORCE_AGENT ]]; then
    local_found=0
    for n in ${LOOKED_FOR_AGENTS[@]+"${LOOKED_FOR_AGENTS[@]}"}; do
        [[ $n == "$FORCE_AGENT" ]] && local_found=1
    done
    (( local_found )) || die "unknown --agent $FORCE_AGENT (have: ${LOOKED_FOR_AGENTS[*]})"
fi

cat <<EOF
${C_BOLD}botkit uninstall${C_RESET}

This will remove:
EOF
if [[ -z $FORCE_AGENT ]]; then
    cat <<EOF
  - $BIN_DIR/bot
  - $UNSLOP_CONF
EOF
fi
for id in ${APPLIED_AGENTS[@]+"${APPLIED_AGENTS[@]}"}; do
    load_agent "$id"
    printf '  - %s (%s)\n' "$(agent_label)" "$id"
done

cat <<EOF

${C_YELLOW}${C_BOLD}~/dev/notes/ is NOT touched.${C_RESET}
That directory is its own git repo. It may have a remote, and it may have
teammates. Nothing here deletes it, and nothing here should. If you really want
it gone, remove it yourself, deliberately, after checking it is pushed.

~/dev/AGENTS.md and ~/dev/CLAUDE.md are also left in place — they are yours
once written.

EOF

if (( ! ASSUME_YES )); then
    read -r -p "Proceed? [y/N] " reply
    [[ ${reply,,} == y* ]] || { info "aborted"; exit 0; }
fi

if [[ -z $FORCE_AGENT ]]; then
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
fi

revert_selected_agents

if [[ -z $FORCE_AGENT ]]; then
    load_agent generic
    agent_revert
    [[ -f $UNSLOP_CONF ]] && { rm -f -- "$UNSLOP_CONF"; ok "removed $UNSLOP_CONF"; }
fi

printf '\n%s==> Done.%s ~/dev/notes/ was not touched.\n' "$C_BOLD" "$C_RESET"
