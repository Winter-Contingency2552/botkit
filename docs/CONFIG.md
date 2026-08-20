# Configuration reference

Two things are configurable: the per-bot config files, and what `install.sh`
writes for each detected agent.

## `bots/<name>.conf`

Shell-sourceable `KEY=value`, no logic. One file per robot. The checkout
gitignore denies everything except the framework, and from `bots/` that is
only `example.conf`. `bots/.gitignore` repeats the local half of that, so
looking in this directory is enough. Do not `git add -f` a real conf.

The filename is authoritative: `bots/robot.conf` must set
`BOT_NAME=robot`. `bot` refuses to run if they disagree, because a mismatch
means one of the two is a typo and guessing which is worse than stopping.

| Field | Required | Default | What it does |
|---|---|---|---|
| `BOT_NAME` | no | the filename | Local nickname. Must match the filename if set. Not a login. |
| `BOT_HOST` | **yes** | none | Hostname or IP. `robot.local` works if mDNS does. |
| `BOT_USER` | **yes** | none | Linux account on the robot. `ssh` and `sshfs` log in as `BOT_USER@BOT_HOST`. Often a shared account such as `team`, not your laptop username. |
| `REMOTE_MOUNT` | **yes** | none | Absolute path on the robot to mount. See below. |
| `MOUNT_POINT` | no | `$HOME/dev/<name>/mount` | sshfs path inside that bot's laptop project. Absolute. Not `~/dev/<name>` itself. |
| `REMOTE_WS` | no | unset | Workspace on the robot. `bot run` and `bot build` `cd` here first. |
| `BUILD_CMD` | no | unset | What `bot build` runs. Required only for `bot build`. |
| `SOURCE_CMD` | no | unset | Sourced before every `bot run` command. |
| `SEARCH_EXCLUDE` | no | see below | Paths under the mount the agent must not search. |
| `LOCAL_REPOS` | no | empty | Space-separated names of laptop clones under `~/dev/<name>/`. The GUI is the usual case. Not mounts. Names `mount`, `notes`, and `docs` are reserved. |
| `LOCAL_REPO_URLS` | no | empty | Space-separated `name=url` pairs, one per `LOCAL_REPOS` entry to auto-clone. See below. |

The file is sourced by bash, so `$HOME` and earlier variables expand. That is why
`SOURCE_CMD` can refer to `$REMOTE_WS`, as long as `REMOTE_WS` is set above it.

### `BOT_USER` and `BOT_HOST`

A robot prompt like `user@robot` is `BOT_USER@hostname`. `BOT_USER` is
the Linux login (`whoami` on the robot). `BOT_HOST` is whichever of `hostname`,
`hostname.local`, or an IP actually answers from the laptop (`ping -c1` each).

`.local` is mDNS. Avahi on Ubuntu, not a botkit suffix. Use it only when that
form is the one that pings. An IP is always valid.

The laptop still connects to an IP. The name is looked up. Login is by SSH key,
not a typed password. `ssh-copy-id` copies your public key to the robot once.
`bot` then uses `BatchMode=yes` and will not prompt. The two checks, and what
each failure means, are in [SETUP.md](SETUP.md#how-ssh-works-without-an-ip-or-a-password).

`BOT_NAME` is not in the prompt. It is the local nickname and must match the
config filename.

### `REMOTE_MOUNT` has no default

Deliberately. What to mount is a decision per robot, not a botkit policy:

- Mounting a **workspace** keeps search fast and scoped.
- Mounting the **home directory** is robust to a layout you do not know yet, and
  covers config that lives outside the workspace.

The cost of the second is search breadth, and how bad that cost is depends
entirely on what is sitting in that particular robot's home directory. `bot probe
<name>` measures it: directory sizes, workspace candidates with build/install/log
sizes, bag and weight counts, and the file count a recursive search would walk
with and without the artifact directories.

Run the probe, choose, and record the reason in
`~/dev/notes/<name>/decisions.md`. The config records the choice; only the notes
record why, and the reason is the part nobody can reconstruct later.

### `SEARCH_EXCLUDE`

Default:

```
build install log .ros bags *.bag *.mcap *.pt *.onnx .cache .git
```

Two shapes, treated differently:

| Entry | Matches |
|---|---|
| no `*` (`build`, `.ros`) | a directory of that name anywhere under the mount |
| contains `*` (`*.bag`) | filenames anywhere under the mount |

Widen it if you mount a home directory. Datasets, virtualenvs, and container
layers are the usual additions.

### `LOCAL_REPOS`

Optional. Space-separated directory names under `~/dev/<BOT_NAME>/`. Each
name is a laptop clone that belongs with this robot. A GUI is the usual
case.

You clone the repo yourself into the project folder `bot up` created, or let
`bot up` do it with `LOCAL_REPO_URLS` below. Either way, botkit never mounts
it and never puts it on the robot.

```
git clone <gui-url> ~/dev/robot/gui
```

Then in the bot conf:

```
LOCAL_REPOS=gui
```

Several names: `LOCAL_REPOS="gui dashboard"`. A name cannot be the bot's own
name, and cannot be `mount`, `notes`, or `docs`.

If a leftover clone still sits at `~/dev/gui` from an older layout, `bot up`
moves it into `~/dev/<bot>/gui`.

Not the same thing as `~/dev/references/`: that directory holds repos you
clone to read, not repos that belong with one robot. It is not a
`LOCAL_REPOS` entry and does not go in a bot conf. See
[SETUP.md](SETUP.md#reference-clones).

`bot up` seeds `~/dev/notes/<repo>/` for each entry. The generated block in
`AGENTS.md` names the link. Start the agent from `~/dev/<bot>/`.

### `LOCAL_REPO_URLS`

Optional. Pairs `LOCAL_REPOS` names with clone URLs, so a bot conf carries
everything a teammate's `bot up` needs to reconstruct the GUI clone, not
just the robot connection:

```
LOCAL_REPOS=gui
LOCAL_REPO_URLS=gui=https://github.com/you/gui
```

`bot up` clones a URL only when nothing already sits at
`~/dev/<bot>/<name>` and no leftover clone was found at the old
`~/dev/<name>` location. It never re-clones, never pulls, and never
overwrites work you already have there. A `LOCAL_REPOS` entry with no
matching `LOCAL_REPO_URLS` pair behaves exactly as before: `bot up` prints
the path and leaves the cloning to you.

Several pairs, space-separated: `LOCAL_REPO_URLS="gui=<url> dashboard=<url>"`.
A name here that isn't in `LOCAL_REPOS`, or a pair missing its `=url`, is a
config error `bot up` refuses to run past.

This is the field that makes a bot conf worth handing to a teammate as-is.
`BOT_HOST`, `BOT_USER`, `REMOTE_MOUNT`, and the rest already describe a
robot the team shares; `LOCAL_REPO_URLS` is what turns "here's the config"
into "here's the config, and your first `bot up` sets up the GUI too."

## What `install.sh` writes, per adapter

`install.sh` does not know about any specific agent. It sources every file in
`lib/agents/` except `generic.sh`, detects which agents are present, and asks
each adapter to apply itself. `generic.sh` always runs: it writes `~/dev/AGENTS.md`.
`--agent <name>` forces one adapter plus the generic layer.

Adding an agent is adding a file to `lib/agents/`. It must not require editing
`install.sh`.

A written rule in `AGENTS.md` is an instruction the agent may ignore. A hook or
a deny rule is enforced. The install report says which is which. Do not treat
them as equivalent.

### Generic (`lib/agents/generic.sh`)

Writes `~/dev/AGENTS.md` from `templates/AGENTS.md` on first install and **never
overwrites** the parts you edit. If the template later changes and yours differs
outside the markers, it writes `~/dev/AGENTS.md.new` alongside it and tells you
to diff them.

The marked block is regenerated on every `install.sh` and every `bot up`:

```markdown
<!-- botkit:begin generated -->
...mount paths, per-bot exclusion lists, unslop, enforcement...
<!-- botkit:end generated -->
```

Replace only what is between the markers. If they are absent, they are appended.

### Claude Code (`lib/agents/claude.sh`)

**Context.** `~/dev/CLAUDE.md` as a symlink to `AGENTS.md`, because Claude Code
does not read `AGENTS.md`. `install.sh` and `bot up` both create that link.
A regular file already at that path is copied to `CLAUDE.md.botkit-bak` once,
then replaced. You do not run `ln` by hand.

**Skills.** Copied to `~/.claude/skills/<name>/`. Provenance:
`~/.claude/skills/.botkit-provenance`.

**Hook.** Merged into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "<botkit>/hooks/unslop-gate.sh" }]
      }
    ]
  }
}
```

Backed up to `settings.json.botkit-bak` before the first change. That backup is
written **once** and never overwritten, so it always holds the genuine
pre-botkit state, which is what `uninstall.sh` restores. A
`settings.json.botkit-prev` is refreshed on every run for same-day mistakes.

Re-running matches the existing entry by its command path and replaces it, so
entries never stack up. Other hooks in your settings are left alone.

**Exclusions.** Each `SEARCH_EXCLUDE` entry becomes a `Read` deny rule under
`permissions.deny`, anchored with `//` at the filesystem root:

| Config entry | Generated rule |
|---|---|
| `build` | `Read(//home/you/dev/robot/**/build/**)` |
| `*.bag` | `Read(//home/you/dev/robot/**/*.bag)` |

Only `Read` rules are generated, and that is not an oversight. `Read` deny rules
cover Read, Grep, and Glob, block Edit and Write on the same path, and apply to
the file-reading Bash commands Claude Code recognises. `Glob(path)` and
`Write(path)` rules are accepted by Claude Code but never consulted, so writing
those instead would look right and do nothing.

They do **not** cover arbitrary subprocesses. A Python script or a hand-rolled
`find` that reads those paths is not stopped by anything here. That is why
`AGENTS.md` also tells agents not to search them.

**Ownership by prefix.** JSON has no comments, so botkit claims every deny entry
beginning with `Read(//<mount point>/` and rewrites exactly those on each run.
Rules anywhere else in the array are never touched. Adding your own deny rules
for other paths is safe.

These are written on install and again on every `bot up`, from the same function,
so the config and the settings cannot drift apart.

**Plugin.** `claude plugin marketplace add mattpocock/skills` and
`claude plugin install mattpocock-skills@mattpocock`. Skip with `--no-plugins`.

### Cursor (`lib/agents/cursor.sh`)

**Context.** `~/dev/AGENTS.md`. Cursor reads it.

**Skills.** Copied to `~/.cursor/skills/<name>/`. Provenance:
`~/.cursor/skills/.botkit-provenance`. Independent of Claude's copy. Uninstalling
one agent does not touch the other.

**Hook.** Merged into `~/.cursor/hooks.json`:

```json
{
  "version": 1,
  "hooks": {
    "postToolUse": [{ "command": "<botkit>/hooks/unslop-gate.sh" }]
  }
}
```

Cursor's `postToolUse` accepts `additional_context` on stdout, which is how the
unslop nudge reaches the model. `afterFileEdit` is the file-edit event, but it
documents no output fields, so it cannot deliver the nudge. The hook script
emits both Claude's `hookSpecificOutput.additionalContext` and Cursor's
`additional_context`.

Backed up the same way as `settings.json`: `hooks.json.botkit-bak` once,
`hooks.json.botkit-prev` every run.

**Exclusions.** Not a Cursor capability. A `.cursorignore` inside `~/dev/<bot>/`
would land on the robot's disk, which is forbidden. The global ignore list in
Cursor user settings replaces the default list rather than merging with it, so
writing it would drop the built-in `.env` and key ignores. Those paths are
listed in `AGENTS.md` instead, and the capability report says `written down`.

### Codex (`lib/agents/codex.sh`)

**Context.** `~/dev/AGENTS.md`. Codex reads it when the session is rooted there.
`~/.codex/AGENTS.md` is left alone so robot rules do not leak into other
projects.

**Skills.** Copied to `~/.agents/skills/<name>/`. Provenance:
`~/.agents/skills/.botkit-provenance`. Independent of Claude's and Cursor's
copies.

**Hook.** Merged into `~/.codex/hooks.json`:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Write|Edit|apply_patch",
        "hooks": [{ "type": "command", "command": "<botkit>/hooks/unslop-gate.sh" }]
      }
    ]
  }
}
```

Codex file edits go through `apply_patch`. The matcher aliases `Edit` and
`Write` still match that tool. The hook script pulls paths from
`*** Add File:` / `*** Update File:` lines in `tool_input.command`. Codex reads
Claude's `hookSpecificOutput.additionalContext` field.

Backed up the same way: `hooks.json.botkit-bak` once, `hooks.json.botkit-prev`
every run.

Codex skips the hook until you trust it. Run `/hooks` in a Codex session after
install.

**Exclusions.** Not a Codex capability. A permission profile in `config.toml`
would replace the user's `sandbox_mode` rather than adding denials beside it.
A project `.codex/` inside `~/dev/<bot>/` would land on the robot. Those paths
are listed in `AGENTS.md` instead, and the capability report says `written down`.

### `~/.claude/botkit-unslop.conf`

Generated. Holds the mount points and exclusion globs the hook needs:

```bash
BOTKIT_MOUNTS=( /home/you/dev/robot )
BOTKIT_EXCLUDES=( build install log .ros bags '*.bag' ... )
```

The hook fires on every Write and Edit, so it sources this one small generated
file rather than reading every `bots/*.conf` itself.

**Do not edit it.** `install.sh` and `bot up` overwrite it. For your own
additions, create `~/.claude/botkit-unslop.local`, which is never regenerated:

```bash
# ~/.claude/botkit-unslop.local
BOTKIT_EXCLUDES+=( vendor third_party '*.ipynb' )
```

To change which files count as prose at all, edit `INCLUDE_GLOBS` and
`EXCLUDE_GLOBS` at the top of `hooks/unslop-gate.sh`.

If `jq` is missing, the installer says so and exits. It will not do text surgery
on your JSON.
