# Configuration reference

Two things are configurable: the per-bot config files, and what `install.sh`
writes into `~/.claude/settings.json`.

## `bots/<name>.conf`

Shell-sourceable `KEY=value`, no logic. One file per robot. `bots/.gitignore`
ignores every `*.conf` except `example.conf`, so your real configs stay out of
the public repo.

The filename is authoritative: `bots/smartbot.conf` must set
`BOT_NAME=smartbot`. `bot` refuses to run if they disagree, because a mismatch
means one of the two is a typo and guessing which is worse than stopping.

| Field | Required | Default | What it does |
|---|---|---|---|
| `BOT_NAME` | no | the filename | Must match the filename if set. |
| `BOT_HOST` | **yes** | none | Hostname or IP. `smartbot.local` works if mDNS does. |
| `BOT_USER` | **yes** | none | The ssh user on the robot. |
| `REMOTE_MOUNT` | **yes** | none | Absolute path on the robot to mount. See below. |
| `MOUNT_POINT` | no | `$HOME/dev/<name>` | Where it appears locally. Absolute. |
| `REMOTE_WS` | no | unset | Workspace on the robot. `bot run` and `bot build` `cd` here first. |
| `BUILD_CMD` | no | unset | What `bot build` runs. Required only for `bot build`. |
| `SOURCE_CMD` | no | unset | Sourced before every `bot run` command. |
| `SEARCH_EXCLUDE` | no | see below | Paths under the mount the agent must not search. |

The file is sourced by bash, so `$HOME` and earlier variables expand. That is why
`SOURCE_CMD` can refer to `$REMOTE_WS`, as long as `REMOTE_WS` is set above it.

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

## What `install.sh` writes to `~/.claude/settings.json`

Backed up to `settings.json.botkit-bak` before the first change. That backup is
written **once** and never overwritten, so it always holds the genuine
pre-botkit state, which is what `uninstall.sh` restores. A
`settings.json.botkit-prev` is refreshed on every run for same-day mistakes.

If `jq` is missing, the installer says so and exits. It will not do text surgery
on your JSON.

### The hook

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

Re-running the installer matches the existing entry by its command path and
replaces it, so entries never stack up. Other hooks in your settings are left
alone.

### The search exclusions

Each `SEARCH_EXCLUDE` entry becomes a `Read` deny rule under
`permissions.deny`, anchored with `//` at the filesystem root:

| Config entry | Generated rule |
|---|---|
| `build` | `Read(//home/you/dev/mybot/**/build/**)` |
| `*.bag` | `Read(//home/you/dev/mybot/**/*.bag)` |

Only `Read` rules are generated, and that is not an oversight. `Read` deny rules
cover Read, Grep, and Glob, block Edit and Write on the same path, and apply to
the file-reading Bash commands Claude Code recognises. `Glob(path)` and
`Write(path)` rules are accepted by Claude Code but never consulted, so writing
those instead would look right and do nothing.

They do **not** cover arbitrary subprocesses. A Python script or a hand-rolled
`find` that reads those paths is not stopped by anything here. That is why the
README also tells agents not to search them.

**Ownership by prefix.** JSON has no comments, so botkit claims every deny entry
beginning with `Read(//<mount point>/` and rewrites exactly those on each run.
Rules anywhere else in the array are never touched. Adding your own deny rules
for other paths is safe.

These are written on install and again on every `bot up`, from the same function,
so the config and the settings cannot drift apart.

### `~/.claude/botkit-unslop.conf`

Generated. Holds the mount points and exclusion globs the hook needs:

```bash
BOTKIT_MOUNTS=( /home/you/dev/mybot )
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

## `~/dev/CLAUDE.md`

Copied from `templates/CLAUDE.md` on first install and **never overwritten**. If
the template later changes and yours differs, the installer writes
`~/dev/CLAUDE.md.new` alongside it and tells you to diff them.
