# Setup

Ubuntu with bash. No macOS, no zsh.

## Dependencies

| Command | Install | Why |
|---|---|---|
| `sshfs` | `sudo apt install sshfs` | mounting the robot |
| `jq` | `sudo apt install jq` | editing JSON config safely |
| `git` | `sudo apt install git` | the notes repo, fetching skills |
| `ssh` | `sudo apt install openssh-client` | running commands on the robot |

`install.sh` checks those four and names every missing one at once. It does
not stop at the first hole. Agents are a separate check. Missing every agent
is still a successful install. The script writes `AGENTS.md`, installs `bot`,
and reports which agents it looked for.

You also want key-based ssh to each robot. `bot` runs ssh with `BatchMode=yes`.
A password prompt is a failure.

```bash
ssh-copy-id user@robot.local
```

## Install

```bash
git clone <this repo> ~/botkit
cd ~/botkit
./install.sh
```

Clone it to `~/botkit`, not under `~/dev`. `install.sh` creates `~/dev` next
to this checkout. `bot up <name>` creates `~/dev/<name>/` as that robot's
laptop project. Why they stay apart is in
[Where things live](#where-things-live).

Options:

| Flag | Effect |
|---|---|
| `--dry-run` | report what would change, change nothing |
| `--no-skills` | skip every third-party skill download. Use this offline. |
| `--no-plugins` | skip the mattpocock marketplace step |
| `--agent NAME` | configure only this adapter, plus the generic layer |

**Keep the checkout where you put it.** `~/.local/bin/bot` is a symlink into
it, and hook paths in agent config are absolute. Move the directory and both
break. Re-run `./install.sh` afterwards and it repairs them.

If `~/.local/bin` is not on your `PATH`, the installer says so and prints the
line to add.

### The plugin step

`install.sh` uses the non-interactive path when your `claude` build has one.

```bash
claude plugin marketplace add mattpocock/skills
claude plugin install mattpocock-skills@mattpocock -y --scope user
```

The marketplace is named `mattpocock`, not `skills`, so the id is
`mattpocock-skills@mattpocock`. If either command fails, or your build has no
`plugin marketplace` subcommand, the installer prints these to paste into a
Claude Code session:

```
/plugin marketplace add mattpocock/skills
/plugin install mattpocock-skills@mattpocock
```

Skip the whole step with `--no-plugins`.

## Restart or reload, per agent

**Claude Code.** Restart after a first install. It watches `~/.claude/skills/`
and picks up new skills without a restart, if that directory already existed
when the session started. On a first install it does not exist, so nothing is
watching. Check with `/context` or `/skills` afterwards. Plugin changes need
a restart or `/reload-plugins`.

**Cursor.** Reload or restart after a first install so it sees
`~/.cursor/skills/`. Hooks in `~/.cursor/hooks.json` reload on their own.

**Codex.** Restart after a first install so it sees `~/.agents/skills/`. Trust
the new PostToolUse hook with `/hooks` before it will run. Untrusted hooks
are skipped.

**Unknown agent.** There is nothing to reload. Read `~/dev/AGENTS.md`.

## Where things live

`./install.sh` creates `~/dev`. That is the working root for every robot on
this laptop. botkit stays at `~/botkit`, next to it, never inside it.

```
~/botkit/                 this repo. Public. Installer, `bot`, docs, example.conf.
~/dev/                    created by install.sh.
  AGENTS.md               rules for every bot. Each project folder symlinks this.
  CLAUDE.md               symlink to AGENTS.md
  notes/                  its own git repo. One directory per robot or local clone.
  references/             other people's repos, cloned here to read. Shared, not per-bot.
  robot/                  laptop project. Created by `bot up robot`. Not a mount.
    mount/                sshfs. The robot's disk.
    gui/                  a laptop clone, if LOCAL_REPOS=gui
    notes                 symlink to ../notes/robot
```

**Two directories, not one.** botkit is a public clone. Hostnames, probe
output, search timings, and notes must not land in it. `~/dev` holds a
laptop project per robot. `notes/` is a second git repo, on purpose. Nesting
either repo inside botkit mixes public installer code with private robot
facts, and makes uninstall delete the wrong thing.

If botkit lived under `~/dev`, an agent rooted at a bot project would see
this checkout as just another project and write those facts into it. That is
the failure this split exists to prevent. Keep the clone at `~/botkit`. If
you move it, `~/.local/bin/bot` and the hook paths break until you re-run
`./install.sh`.

**One `~/dev`, a folder per bot.** A second robot is `bots/other.conf` plus
`bot up other`. That adds `~/dev/other/` with its own `mount/`. It does not
create a second `~/dev`. `MOUNT_POINT` defaults to `$HOME/dev/<name>/mount`.
Leave that unless you have a reason, and if you do, write the reason in that
robot's notes.

**What `~/dev/<bot>` actually does.** It is the project root. Agents load
`AGENTS.md` or `CLAUDE.md` from the directory you start them in. Start from
`~/dev/robot` and one session sees that mount, that GUI, and that notes
directory. Start from `~/dev` only when you need every robot at once. Start
from `~/dev/robot/mount` and the session is rooted on the robot's disk.
Anything the agent writes there lands on the robot.

```bash
cd ~/dev/robot
```

Then start Claude Code, Cursor, or Codex there.

Matt Pocock's skills look for files in the project root. `bot up` puts
`docs/agents/`, `.scratch/`, and `CONTEXT.md` in `~/dev/<bot>/` as symlinks
into `~/dev/notes/<bot>/`. Do not create those under `mount/`.

## Planning without the robot

`bot up` creates `~/dev/robot/` even when the robot is unreachable. Start
the agent there anyway. Notes, the GUI clone, and `AGENTS.md` are enough
to think.

The `in-class-planning` skill writes `notes/<repo>/plans/<slug>.md`. It
calls `grill-me` to refine the idea until the Goal is named. Each
assumption in that file has to be checkable once the robot is up. Then
stop. The agent does not edit robot source during planning.

When the robot is on wifi, say execute. The agent warns that the swarm is
expensive, runs `bot status`, checks every assumption against the live
system, and only then spins up as many parallel workers as it can,
looping until the Goal is done. A failed check blocks the change. Source
stays untouched until every check holds.

GUI-only work can execute without the robot if every assumption is about a
clone on this laptop.

A robot that dies mid-edit is the other case. That is stop-and-report, not
a planning session. The stop rule in `AGENTS.md` still applies.

## Your first bot

```bash
cp bots/example.conf bots/robot.conf
```

The copy is gitignored. Do not commit it, and do not `git add -f` it. Do not
edit `example.conf` itself; that file is tracked. Real hosts, usernames, and
mount paths stay out of this repo.

Edit three fields. Leave `REMOTE_MOUNT` empty for now. If this robot has a GUI
you clone onto the laptop, that is `LOCAL_REPOS`, after `bot up`.

| Field | What to put |
|---|---|
| `BOT_NAME` | Same as the filename. `bots/robot.conf` means `BOT_NAME=robot`. A local nickname. Not a login. |
| `BOT_HOST` | Whatever you put after `@` in `ssh`. Hostname, `hostname.local`, or an IP. See below. |
| `BOT_USER` | The Linux account on the robot, the part before `@` on the robot's prompt. Often a shared account, not the username on this laptop. |

### Reading the robot's prompt

A typical prompt is `user@hostname`. If the robot shows `user@robot`:

| Prompt | Field | Value |
|---|---|---|
| `user`, before `@` | `BOT_USER` | `user` |
| `robot`, after `@` | `BOT_HOST` | `robot`, or `robot.local`, or the IP |
| you pick | `BOT_NAME` | usually `robot`, matching `bots/robot.conf` |

On the robot, `whoami` is `BOT_USER` and `hostname` is the machine's name.

### SSH

**The name is looked up.** `robot` and `robot.local` are names. `ping` and `ssh`
ask the network who that is and get an IP back. `.local` is mDNS. On Ubuntu
that is Avahi. The robot announces `robot.local` on the LAN and the laptop
hears it. No DNS server. No `/etc/hosts` line. botkit does not add `.local`.

```bash
ping -c1 robot
ping -c1 robot.local
```

Whichever one replies is `BOT_HOST`. If both fail, use the IP. `BOT_HOST` is
the string after `ssh user@`. Every later `ssh` and `sshfs` still hits that
looked-up address. A name keeps working when the robot gets a new address. A
hardcoded IP often does not. That is why the extra ping is worth it.

**A key replaces the password.** The laptop has a key pair under
`~/.ssh/`. `ssh-copy-id` logs in with the account password once and appends
your public key to `~/.ssh/authorized_keys` on the robot. After that, ssh
proves you hold the matching private key. The private key never leaves the
laptop.

`bot` runs ssh with `BatchMode=yes`. It will not prompt. It fails. A password
prompt would hang the agent, so keys are required.

```bash
ssh-copy-id user@robot        # or user@robot.local. Password, once.
ssh user@robot true           # must succeed with no password
```

If `ping` fails, put the IP in `BOT_HOST`. If `ssh ... true` asks for a
password, you skipped `ssh-copy-id`.

### Choosing REMOTE_MOUNT

There is no default, on purpose. What to mount depends on how that robot is
laid out. A bad guess is paid for on every search you ever run against it.

```bash
bot probe robot
```

That connects over ssh, writes nothing to the robot, and reports:

- top-level directory sizes under the remote home
- every directory that looks like a ROS 2 workspace, with its `build/`,
  `install/`, and `log/` sizes and its package count
- how many bags, mcaps, and model weights are lying around
- how many files a recursive search would walk, with and without the artifact
  directories

Then decide.

**A workspace, `/home/user/ws`.** Search only walks that tree. Use this when
the probe shows a large home directory, a lot of recorded data, or work that
only ever happens in one place.

**The home directory, `/home/user`.** Covers config outside the workspace, and
work that spans several workspaces. Also the honest choice when you do not
know the layout yet. The cost is search breadth. Widen `SEARCH_EXCLUDE` until
the timed comparison below is acceptable.

Put the path in `REMOTE_MOUNT` and the reason in
`~/dev/notes/robot/decisions.md`. The config file records what you chose. Only
the notes record why.

### Bring it up

```bash
bot up robot
```

Mounts it. Seeds `~/dev/notes/robot/` and notes for any `LOCAL_REPOS`. Writes
the search exclusions, regenerates the marked block in `AGENTS.md`, and prints
the mount path. Running it twice is a no-op.

```bash
bot run robot -- ros2 topic list
bot build robot
bot status
bot down robot
```

## A GUI that belongs with this robot

Robot source stays on the robot, mounted at `~/dev/robot/mount/`. A GUI is
the opposite. It runs on the laptop, so it is an ordinary git clone inside
the laptop project, next to the mount, never inside it.

```bash
git clone <gui-url> ~/dev/robot/gui
```

Mixing those up writes the GUI onto the robot's disk.

Then name it on the bot, in `bots/robot.conf`:

```
LOCAL_REPOS=gui
```

`gui` is the directory name under `~/dev/robot`. Several clones go in one
value, `LOCAL_REPOS="gui dashboard"`. A name cannot be `mount`, `notes`, or
`docs`.

`bot up` seeds `~/dev/notes/gui/` the same way it seeds `~/dev/notes/robot/`,
and writes a line into the generated block of `~/dev/AGENTS.md`. If a leftover
clone still sits at `~/dev/gui`, `bot up` moves it into the project.

Start the agent from `~/dev/robot`. One session there sees the GUI, the
mount, and notes.

Bring the bot up again, or for the first time.

```bash
bot up robot
```

That seeds `~/dev/notes/gui/` the same way it seeds `~/dev/notes/robot/`, and
writes a line into the generated block of `~/dev/AGENTS.md`:

```
- `gui` belongs with bot `robot` (at `~/dev/robot/gui`). Notes: `notes/gui/`.
```

Start the agent from `~/dev/robot`. One session there sees the GUI, the mount,
and notes. When the task is the robot, read the GUI too. When the task is the
GUI, read the robot.

`bot notes gui` works even without a bot config. Use it if you want notes
before the link is declared.

## Reference clones

`install.sh` also creates `~/dev/references/`, empty except for a short
README. Use it for repos you want to read from, not build: "implement it
kind of like this one did."

```bash
git clone <url> ~/dev/references/some-project
```

It differs from a GUI clone in `LOCAL_REPOS` in one way: it is not tied to
a bot. One `~/dev/references/` serves every robot on the laptop, because the
repo worth borrowing from rarely matches whichever robot you're working on
that day. Nothing here is mounted, built, or run, and nothing here goes onto
a robot without you saying so explicitly.

## Search latency

Mounting a remote home means recursive search covers build artifacts, bags,
logs, and model weights unless the exclusions hold. Measure it for each robot.
Do not assume.

```bash
# everything
time rg --files ~/dev/robot/mount | wc -l

# with the exclusions this bot actually uses
time rg --files ~/dev/robot/mount \
  -g '!build' -g '!install' -g '!log' -g '!.ros' -g '!bags' \
  -g '!*.bag' -g '!*.mcap' -g '!*.pt' -g '!*.onnx' -g '!.cache' -g '!.git' | wc -l
```

Record both numbers in that robot's `~/dev/notes/<name>/decisions.md`, next to
the `REMOTE_MOUNT` reason. Not in this file. This repo is public. Robot names,
mount paths, and how fat the tree is do not belong here.

If the excluded case is still slow, that robot should be mounting its workspace
instead of its home directory. Change `REMOTE_MOUNT`, `bot down` then `bot up`,
and write down why in the same `decisions.md`.

## Troubleshooting

**`bot up` says unreachable.** The robot is off, off wifi, or out of range.
Check the robot. This is the common case, not the exception. The project
folder is still there. Start the agent from `~/dev/robot` and plan against
notes. Bring the robot up later and execute.

**`ls ~/dev/robot/mount` hangs forever.** The mount is wedged. The connection dropped
while it was mounted. `bot status robot` reports `stale` without hanging,
because it reads `/proc/mounts` instead of touching the mount. Once the robot
is back, `bot down -f robot` then `bot up robot`. Once.

**`bot up` refuses because the mount point is not empty.** Something is already
in `~/dev/robot/mount/` that is not a mount. Mounting over it would hide it. Look at
what is there and move it before retrying.

**`bot run` fails with "command not found" for a ROS tool.** `SOURCE_CMD` in the
bot config is wrong for that robot. Check the ROS distro and the workspace
path with `bot run robot -- 'ls /opt/ros'`.

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
That is what a first install does. Not a failure. See
[Restart or reload, per agent](#restart-or-reload-per-agent).

Confirm they are on disk:

```bash
ls ~/.claude/skills/ ~/.cursor/skills/ ~/.agents/skills/
cat ~/.claude/skills/.botkit-provenance
cat ~/.cursor/skills/.botkit-provenance
cat ~/.agents/skills/.botkit-provenance
```

**A skill is missing.** `install.sh` lists which skill directories exist at the
end of every run. Re-run it. A network failure during the clone is the usual
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
