# Setup

Ubuntu with bash. No macOS, no zsh.

## Dependencies

| Command | Install | Why |
|---|---|---|
| `sshfs` | `sudo apt install sshfs` | mounting the robot |
| `jq` | `sudo apt install jq` | editing JSON config safely |
| `git` | `sudo apt install git` | the notes repo, fetching skills |
| `ssh` | `sudo apt install openssh-client` | running commands on the robot |

`install.sh` checks those four and names every missing one at once rather than
failing on the first. Agents are detected separately. If none is found, that is
a warning, not an error: the installer writes `AGENTS.md`, installs `bot`, and
says which agents it looked for.

You also want key-based ssh to each robot. `bot` runs ssh with `BatchMode=yes`,
so a password prompt is a failure, not a prompt.

```bash
ssh-copy-id team@robot.local
```

## Install

```bash
git clone <this repo> ~/botkit
cd ~/botkit
./install.sh
```

Options:

| Flag | Effect |
|---|---|
| `--dry-run` | report what would change, change nothing |
| `--no-skills` | skip every third-party skill download (offline install) |
| `--no-plugins` | skip the mattpocock marketplace step |
| `--agent NAME` | configure only this adapter, plus the generic layer |

**Keep the checkout where you put it.** `~/.local/bin/bot` is a symlink into it,
and hook paths in agent config are absolute. Moving the directory breaks
both; re-run `./install.sh` afterwards and it repairs them.

If `~/.local/bin` is not on your `PATH`, the installer says so and prints the
line to add.

### The plugin step

`install.sh` uses the non-interactive path when your `claude` build has one:

```bash
claude plugin marketplace add mattpocock/skills
claude plugin install mattpocock-skills@mattpocock -y --scope user
```

The marketplace is named `mattpocock`, not `skills`, so the id is
`mattpocock-skills@mattpocock`. If either command fails or your build has no
`plugin marketplace` subcommand, the installer says so and prints these to paste
into a Claude Code session instead:

```
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock
```

Skip the whole step with `--no-plugins`.

## Restart or reload, per agent

**Claude Code.** Restart after a first install. It watches `~/.claude/skills/`
for changes and normally picks up new skills live, without a restart, but only
if that directory existed when the session started. On a first install it does
not exist, so nothing is watching it. Check with `/context` or `/skills`
afterwards. Plugin changes need a restart or `/reload-plugins`.

**Cursor.** Reload or restart after a first install so it sees `~/.cursor/skills/`.
Hooks in `~/.cursor/hooks.json` reload on their own.

**Codex.** Restart after a first install so it sees `~/.agents/skills/`. Trust
the new PostToolUse hook with `/hooks` before it will run; untrusted hooks are
skipped.

**Unknown agent.** There is nothing to reload. Read `~/dev/AGENTS.md`.

## Your first bot

```bash
cp bots/example.conf bots/mybot.conf
```

Edit three fields. Leave `REMOTE_MOUNT` empty for now.

| Field | What to put |
|---|---|
| `BOT_NAME` | Same as the filename. `bots/mybot.conf` means `BOT_NAME=mybot`. This is a local nickname, not a login. |
| `BOT_HOST` | Hostname or IP of the robot. |
| `BOT_USER` | The Linux account on the robot. Whatever you would type in `ssh BOT_USER@BOT_HOST`. On a shared robot this is often a shared account (`team`), not the username on this laptop. |

You need key-based ssh as that user before `bot probe` will work:

```bash
ssh-copy-id team@mybot.local
ssh team@mybot.local true    # must succeed without a password
```

Substitute the `BOT_USER` and `BOT_HOST` you just set.

### Choosing REMOTE_MOUNT

There is no default, on purpose. What to mount depends on how that robot is laid
out, and a bad guess is paid for on every search you ever run against it.

```bash
bot probe mybot
```

That connects over ssh, writes nothing to the robot, and reports:

- top-level directory sizes under the remote home
- every directory that looks like a ROS 2 workspace, with its `build/`,
  `install/`, and `log/` sizes and its package count
- how many bags, mcaps, and model weights are lying around
- how many files a recursive search would walk, with and without the artifact
  directories

Then decide:

- **A workspace** (`/home/team/ws`) keeps searches fast and scoped. Right when
  the probe shows a large home directory, a lot of recorded data, or work that
  only ever happens in one place.
- **The home directory** (`/home/team`) is robust when you do not know the
  layout yet, when config outside the workspace matters, or when work spans
  several workspaces. It costs search breadth, which `SEARCH_EXCLUDE` contains.

Put the answer in `REMOTE_MOUNT` and the reason in
`~/dev/notes/mybot/decisions.md`. The config file records what you chose; only
the notes record why.

### Bring it up

```bash
bot up mybot
```

Mounts it, seeds `~/dev/notes/mybot/`, writes the search exclusions, regenerates
the marked block in `AGENTS.md`, and prints the mount path. Running it twice is
a no-op.

```bash
bot run mybot -- ros2 topic list
bot build mybot
bot status
bot down mybot
```

## Search latency

Mounting a remote home means recursive search covers build artifacts, bags,
logs, and model weights unless the exclusions hold. Measure it for each robot
rather than assuming:

```bash
# everything
time rg --files ~/dev/mybot | wc -l

# with the exclusions this bot actually uses
time rg --files ~/dev/mybot \
  -g '!build' -g '!install' -g '!log' -g '!.ros' -g '!bags' \
  -g '!*.bag' -g '!*.mcap' -g '!*.pt' -g '!*.onnx' -g '!.cache' -g '!.git' | wc -l
```

Record both numbers here, per robot:

| Robot | REMOTE_MOUNT | Full tree | Excluded | Measured |
|---|---|---|---|---|
| _(none yet)_ | | TBD | TBD | |

If the excluded case is still slow, that robot should be mounting its workspace
instead of its home directory. Change `REMOTE_MOUNT`, `bot down` then `bot up`,
and write down why in that robot's `decisions.md`.

## Troubleshooting

**`bot up` says unreachable.** The robot is off, off wifi, or out of range.
Check the robot. This is the common case, not the exception.

**`ls ~/dev/mybot` hangs forever.** The mount is wedged. The connection dropped
while it was mounted. `bot status mybot` reports `stale` without hanging, because
it reads `/proc/mounts` instead of touching the mount. Once the robot is back:
`bot down -f mybot` then `bot up mybot`. Once.

**`bot up` refuses because the mount point is not empty.** Something is already
in `~/dev/mybot/` that is not a mount. Mounting over it would hide it. Look at
what is there and move it before retrying.

**`bot run` fails with "command not found" for a ROS tool.** `SOURCE_CMD` in the
bot config is wrong for that robot. Check the ROS distro and the workspace path:
`bot run mybot -- 'ls /opt/ros'`.

**A password prompt appears.** ssh keys are not set up. `ssh-copy-id
<user>@<host>`.

**The hook does not fire.** For Claude Code, check `settings.json` has the
`PostToolUse` entry pointing at an existing, executable `hooks/unslop-gate.sh`.
For Cursor, check `~/.cursor/hooks.json` has the `postToolUse` entry. For
Codex, check `~/.codex/hooks.json` has the `PostToolUse` entry, then trust it
with `/hooks`. Then re-run `./install.sh`. Test it directly:

```bash
echo '{"tool_input":{"file_path":"/home/you/dev/notes/x/architecture.md"}}' \
  | ./hooks/unslop-gate.sh
```

Cursor's payload puts the path at the top level. That shape works too:

```bash
echo '{"file_path":"/home/you/dev/notes/x/architecture.md"}' \
  | ./hooks/unslop-gate.sh
```

Codex file edits send an `apply_patch` command instead of a path:

```bash
echo '{"tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: /home/you/dev/notes/x/architecture.md\n"}}' \
  | ./hooks/unslop-gate.sh
```

**The agent does not see the skills after installing.** Restart or reload it.
This is the expected behaviour on a first install, not a failure. See
[Restart or reload, per agent](#restart-or-reload-per-agent).

Confirm they are on disk and well-formed in the meantime:

```bash
ls ~/.claude/skills/ ~/.cursor/skills/ ~/.agents/skills/
cat ~/.claude/skills/.botkit-provenance
cat ~/.cursor/skills/.botkit-provenance
cat ~/.agents/skills/.botkit-provenance
```

**A skill is missing.** `install.sh` lists which skill directories exist at the
end of every run. Re-run it; a network failure during the clone is the usual
cause. The provenance file in that agent's skills directory shows what was
installed from where.

## Uninstall

```bash
./uninstall.sh
./uninstall.sh --agent cursor   # one agent, leave the others
```

Removes the `bot` symlink, the skills each adapter recorded installing, the
Claude plugin, and restores each agent's config from its `.botkit-bak`.

**It does not touch `~/dev/notes/`.** That repo may have a remote and teammates.
Deleting it is a deliberate act you perform yourself, after checking it is
pushed. `~/dev/AGENTS.md` and `~/dev/CLAUDE.md` are also left alone.
