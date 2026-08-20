# Making botkit work with any agent

botkit works with any coding agent. Each one gets as much enforcement as it
genuinely supports. The install report says which parts are enforced and which
are only written down. Claude Code keeps everything it had.

## What already works with any agent

None of this needs changing. It is plain shell and plain files.

| Piece | Why it is neutral |
|---|---|
| `scripts/bot` | shell, ssh, sshfs. `bot up` also regenerates AGENTS.md and refreshes per-agent exclusions. |
| `bots/*.conf` | shell key/value. |
| `~/dev/notes/` and `templates/notes-repo/` | markdown in a git repo. |
| `lib/common.sh` mount and ssh helpers | shell. |
| The notes contract | a convention, not a mechanism. |

## What used to be Claude-specific

These now go through adapters. Claude Code still has all of them.

| Piece | Mechanism | Adapter |
|---|---|---|
| Instructions file | `~/dev/AGENTS.md`, plus `CLAUDE.md` symlink | generic.sh, claude.sh |
| Skills | copied to each agent's skills directory | claude.sh, cursor.sh, codex.sh |
| unslop nudge | Claude `PostToolUse`, Cursor `postToolUse`, Codex `PostToolUse` | all three, via `hooks/unslop-gate.sh` |
| Search exclusions | Claude `Read(...)` deny rules; Cursor and Codex written into AGENTS.md | claude.sh, generic.sh |
| Plugin install | `claude plugin marketplace add` | claude.sh |
| Preflight | `sshfs jq git ssh`; agents detected separately | install.sh |

## Verified facts

These were checked against live upstream docs and this machine. **Use them.
Do not re-derive them, and do not guess at a path that is not listed here.**

### Claude Code (verified)

- Reads `CLAUDE.md`. **It does not read `AGENTS.md`.** The documented fix is
  `ln -s AGENTS.md CLAUDE.md`, or a `@AGENTS.md` import line inside `CLAUDE.md`.
- Personal skills: `~/.claude/skills/<name>/SKILL.md`.
- Hook config: `~/.claude/settings.json`, key `hooks.PostToolUse`, entries of
  the form `{"matcher": "Write|Edit", "hooks": [{"type": "command", "command": "..."}]}`.
- Hook input: the edited path is at **`.tool_input.file_path`**.
- Hook output: `{"hookSpecificOutput": {"hookEventName": "PostToolUse",
  "additionalContext": "..."}}`.
- Search exclusions: `permissions.deny` entries like
  `Read(//abs/path/**/build/**)`, gitignore pattern syntax, `//` anchors at the
  filesystem root. These cover Read, Grep, Glob, and the file-reading Bash
  commands Claude Code recognises, and they also block Edit and Write on the
  same path.
- **`Glob(path)` and `Write(path)` rules are accepted but never consulted**, and
  warn at startup. Only `Read(...)` rules do anything.
- A skills directory that did not exist when the session started is not watched,
  so a first install needs a restart.

### Cursor (verified)

- Reads `AGENTS.md` in the project root and in subdirectories, combining nested
  files with more specific ones taking precedence.
- Skills: `~/.cursor/skills/<name>/SKILL.md` for user level, `.cursor/skills/`
  for project level. Cursor walks the skills root recursively and the skill's
  identity comes from the folder containing `SKILL.md`. **This is the same
  format botkit already installs, so the skill files copy across unchanged.**
- Hooks: `~/.cursor/hooks.json` for user level, `.cursor/hooks.json` for
  project level. Shape is `{"version": 1, "hooks": {"afterFileEdit": [{"command": "..."}]}}`.
- The file-edit hook event is **`afterFileEdit`**. It has no documented output
  fields, so it cannot inject context. Cursor **`postToolUse`** does: output
  `{"additional_context": "..."}`. That is the event the Cursor adapter uses.
- `afterFileEdit` input: `{"file_path": "<absolute path>", "edits": [{"old_string": "...", "new_string": "..."}]}`.
  The path is at the **top level**, not under `tool_input`.
- `disable-model-invocation: true` is a documented Cursor frontmatter key.
  Skills so marked are only included when explicitly invoked.
- Exclusions: `.cursorignore` in the project root, gitignore syntax. It blocks
  Agent, Tab, Inline Edit, and `@` mentions. **It does not block the terminal or
  MCP server tools**, which is the same limitation Claude's deny rules have.

### Codex (verified)

- Reads `AGENTS.md` in the project (and nested directories). Also reads
  `~/.codex/AGENTS.md` as global instructions. botkit does **not** write the
  global file: that would inject robot rules into every Codex session, including
  ones that are not rooted at `~/dev`.
- Personal skills: `~/.agents/skills/<name>/SKILL.md`. Repo skills would be
  `.agents/skills/` inside the project; botkit does not write that into a mount.
- Hook config: `~/.codex/hooks.json` (user level). Shape matches Claude:
  `{"hooks": {"PostToolUse": [{"matcher": "...", "hooks": [{"type": "command", "command": "..."}]}]}}`.
  Do not put a project `.codex/` inside `~/dev/<bot>/`.
- Hooks are on by default. Non-managed command hooks are skipped until the user
  trusts them with `/hooks`.
- File edits go through `apply_patch`. `matcher` values `apply_patch`, `Edit`,
  and `Write` all match that tool; hook input still reports
  `tool_name: "apply_patch"`. The edited path is **not** at `.tool_input.file_path`.
  It is inside `.tool_input.command`, as `*** Update File:` / `*** Add File:`
  lines in the patch.
- Hook output: `{"hookSpecificOutput": {"hookEventName": "PostToolUse",
  "additionalContext": "..."}}`. Same field Claude uses.
- Exclusions: Codex permission profiles (`default_permissions` plus
  `[permissions.*.filesystem]`) do not compose with `sandbox_mode`. Setting
  `default_permissions` would replace the user's sandbox. No profile is written.

### How the above was verified

```bash
curl -sfL https://docs.claude.com/en/docs/claude-code/memory.md
curl -sfL https://docs.claude.com/en/docs/claude-code/hooks.md
curl -sfL https://docs.claude.com/en/docs/claude-code/permissions.md
curl -sfL https://cursor.com/docs/rules
curl -sfL https://cursor.com/docs/skills
curl -sfL https://cursor.com/docs/hooks
curl -sfL https://cursor.com/docs/reference/ignore-file
curl -sfL https://developers.openai.com/codex/hooks
curl -sfL https://developers.openai.com/codex/skills
curl -sfL https://developers.openai.com/codex/guides/agents-md
curl -sfL https://developers.openai.com/codex/concepts/customization
```

## The design

An adapter layer. `install.sh` does not know about any specific agent and asks
adapters instead.

```
lib/agents/
  generic.sh   always applied, to every agent, including ones nobody wrote an adapter for
  claude.sh
  cursor.sh
  codex.sh
```

Each adapter defines these functions. `install.sh` sources one adapter at a
time and calls them.

```bash
agent_label          # human name, e.g. "Claude Code"
agent_detect         # exit 0 if this agent is present on the machine
agent_capabilities   # print any of: context skills hooks exclusions
agent_apply          # do the work. Must be idempotent.
agent_revert         # uninstall.sh, per agent
```

Rules for the layer:

- **`generic.sh` always runs, for every agent.** It only writes `AGENTS.md`. That
  is what makes an unknown agent work rather than fail.
- An adapter reports only what it can genuinely do. Anything it leaves out of
  `agent_capabilities` gets folded into `AGENTS.md` as written instruction by the
  generic layer.
- Adding an agent means adding one file to `lib/agents/`. It must not require
  editing `install.sh`.
- `install.sh --agent <name>` forces a specific adapter. With no flag, it detects
  and configures every agent it finds.

## What was built

### 1. AGENTS.md is the instructions file

`templates/AGENTS.md` installs to `~/dev/AGENTS.md`. The Claude adapter creates
`~/dev/CLAUDE.md` as a symlink to `AGENTS.md`. If `CLAUDE.md` already exists as
a real file, it is left alone and the install report tells you to merge by hand.

Non-clobber: if `~/dev/AGENTS.md` already exists and differs from the template
outside the markers, write `AGENTS.md.new` beside it and say so. Never
overwrite the user-edited part.

### 2. A regenerated block inside AGENTS.md

Markers:

```markdown
<!-- botkit:begin generated -->
...regenerated content...
<!-- botkit:end generated -->
```

`regenerate_agents_md` in `lib/common.sh` replaces only what is between the
markers. If they are absent, it appends them. `install.sh` and `bot up` both
call it. The block lists mount paths, per-bot exclusion lists, the unslop
instruction, and which of those are enforced on each applied agent.

### 3. The hook script speaks three dialects

`hooks/unslop-gate.sh` reads `.tool_input.file_path`, `.tool_input.path`, or
`.file_path`, and for Codex `apply_patch` it also parses
`*** Add File:` / `*** Update File:` lines out of `.tool_input.command`.

On a match it emits both Claude's `hookSpecificOutput.additionalContext` and
Cursor's `additional_context`. Codex uses the Claude-shaped field. It still
exits 0 on every path, including bad input and a missing `jq`.

### 4. The Cursor adapter

Capabilities: `context skills hooks`. Exclusions are not in the list.

- Skills: copy into `~/.cursor/skills/<name>/`.
- Hook: merge into `~/.cursor/hooks.json` as `postToolUse`, matching and
  replacing any existing botkit entry by its command path.
- Exclusions: folded into `AGENTS.md`. See resolved questions below.

### 5. The Codex adapter

Capabilities: `context skills hooks`. Exclusions are not in the list.

- Skills: copy into `~/.agents/skills/<name>/`.
- Hook: merge into `~/.codex/hooks.json` as `PostToolUse`, matcher
  `Write|Edit|apply_patch`, matching and replacing any existing botkit entry by
  its command path. The install report tells you to trust it with `/hooks`.
- Exclusions: folded into `AGENTS.md`. No `config.toml` is written.

### 6. botkit's own skills install to every agent

Every directory under `skills/` that contains `SKILL.md` is staged, then copied
to each skills-capable agent. Adding a second folder under `skills/` installs
it with no edit to `install.sh`. Fetched pstack and robotics skills go to the
same agents. Provenance is per-agent: `.botkit-provenance` lives inside that
agent's skills directory.

`disable-model-invocation: true` is documented for Cursor as well as Claude
Code. Codex does not document that key. Recorded in `docs/SKILLS.md`.

### 7. Preflight no longer requires claude

`DEPENDENCIES` is `sshfs jq git ssh`. Agents are detected separately. No known
agent is a warning, not an error.

### 8. The capability report

Printed at the end of the run. A rule written into `AGENTS.md` is an
instruction the agent may ignore. A hook or a deny rule is enforced. The report
says so in words, not only in the table.

### 9. uninstall.sh reverses all of it

Per agent, using `agent_revert`. `--agent NAME` reverts one adapter.
`~/dev/notes/` is not touched. `~/dev/AGENTS.md` is not touched.

### 10. Docs

`docs/SKILLS.md`, `docs/CONFIG.md`, `docs/SETUP.md`, `README.md`, and this file.

## The rule that must hold

Where an agent cannot enforce something, fold the rule into `AGENTS.md` as an
instruction **and say that is what happened.** A written rule is weaker than an
enforced one. The install report and the docs both have to be honest about which
is which, because someone will otherwise assume a deny rule is protecting them
when only a sentence is.

## Resolved questions

**Can Cursor's `afterFileEdit` return context to the agent?** No documented
output fields. Cursor's `postToolUse` does document `additional_context`, so
the Cursor adapter registers that event instead of `afterFileEdit`. The unslop
nudge is a hook on Cursor, not folded into `AGENTS.md`.

**Does a user-level Cursor ignore file exist that we can write without touching
a mount?** `.cursorignore` is project-root only. Putting one inside
`~/dev/<bot>/` would write to the robot. `cursor.general.globalCursorIgnoreList`
in user settings replaces the default list rather than merging, so writing it
would drop the built-in `.env` and key ignores. Exclusions are therefore not a
Cursor capability and are listed in `AGENTS.md` as written down.

**Codex.** Confirmed against the hooks, skills, and AGENTS.md docs. Skills go
to `~/.agents/skills`. The unslop hook is `PostToolUse` in `~/.codex/hooks.json`,
matching `Write|Edit|apply_patch`. File edits send the patch in
`tool_input.command`, so the gate parses `*** Add File:` / `*** Update File:`
lines. Exclusions stay in `AGENTS.md`: a permission profile would hijack
`sandbox_mode`, and a project `.codex/` inside a mount would land on the robot.
`~/.codex/AGENTS.md` is not written, so robot rules do not leak into unrelated
Codex sessions. The hook does nothing until you trust it with `/hooks`.

## Acceptance checks, offline

These need no robot. Run them with `HOME=<a temp dir> ./install.sh` so nothing
touches the real home directory.

1. `./install.sh` succeeds on a machine with no agent installed at all, and says
   so rather than failing.
2. `~/dev/AGENTS.md` exists. `~/dev/CLAUDE.md` is a symlink to it.
3. Claude Code keeps everything it has today: 9 skills, the `PostToolUse` hook,
   and the `Read(...)` deny rules.
4. With Cursor installed, `~/.cursor/skills/` gets the same 9 skill directories,
   botkit's own `wiring` among them.
4b. With Codex installed (or `./install.sh --agent codex`), `~/.agents/skills/`
    gets those same directories, and `~/.codex/hooks.json` has the PostToolUse
    entry. Uninstalling `--agent codex` leaves Claude and Cursor alone.
5. Adding a second directory under `skills/` installs it to every skills-capable
   agent with no edit to `install.sh`.
6. Each agent's skills directory has its own `.botkit-provenance`, and
   uninstalling one agent leaves the other agent's skills untouched.
7. The generated block in `AGENTS.md` lists real mount paths and real exclusion
   lists, and regenerates on `bot up` without touching text outside the markers.
8. Editing `AGENTS.md` by hand outside the markers, then re-running
   `install.sh`, preserves the edit.
9. A second `./install.sh` reports that nothing changed.
10. The capability report distinguishes enforced from written down.
11. `./uninstall.sh` leaves `~/dev/notes/` alone and restores every agent's
    config from its backup.
12. Adding a new adapter file to `lib/agents/` makes that agent work with no
    edit to `install.sh`.

## Acceptance checks, against a real robot

**None of these have ever been run.** botkit was built and validated entirely
offline, against a sandboxed `HOME`, because no robot was available. Everything
below is unverified against hardware. Treat a failure here as a real bug in
botkit, not as a mistake in the test.

Run the whole list once on Claude Code, then again on Cursor, then on Codex if
you have it. The point of the extra passes is that the `bot` toolchain is
supposed to be harness-neutral, so every result should be identical except
where the capability table says otherwise.

Set up first:

```bash
cp bots/example.conf bots/robot.conf   # set BOT_HOST and BOT_USER, leave REMOTE_MOUNT empty
```

### The checks

1. **`bot probe robot`** returns a real layout report: directory sizes, workspace
   candidates with their build/install/log sizes and package counts, bag and
   weight counts, and the two file counts. It must write nothing to the robot.
   Confirm with `ssh <user>@<host> 'ls -la ~'` before and after.
2. **Choose `REMOTE_MOUNT` from what the probe said**, set it, and record the
   reason in `~/dev/notes/robot/decisions.md`. The probe must not have chosen for
   you.
3. **`bot up robot`** mounts, seeds `~/dev/notes/robot/` including `inbox/`,
   writes the exclusions, and prints the mount path.
4. **`bot up robot` again** is a clean no-op that changes nothing.
5. **`bot run robot -- ros2 topic list`** returns real topics. Then
   **`bot build robot`** actually builds on the robot.
6. **`bot down robot`** unmounts. A second `bot down robot` exits 0 without
   erroring.
7. **Stale versus unreachable.** With the bot mounted, drop the robot off wifi.
   `bot status robot` must report `stale` and must return within seconds rather
   than hanging. Power the robot off entirely with nothing mounted:
   `bot status robot` must report `unreachable`. These two are detected
   differently and both paths need exercising.
8. **Recovery.** After a `stale`, bring the robot back, then `bot down -f robot`
   followed by `bot up robot`. It should recover in exactly those two commands.
9. **Power-down drill.** With a session running against a mounted bot, physically
   power the robot off, then ask the agent to do something that touches the
   mount. The agent must detect unreachability, say so, and stop **within two
   failed commands**. If it starts investigating the filesystem or reading source
   to explain the error, the agent-facing rules in `README.md` and `AGENTS.md`
   are not working and need rewriting. This is a test of the documentation, not
   of the code.
10. **`wiring` live.** With the robot up, run `wiring`. It must label itself
    LIVE, cite real `ros2` command output, and report QoS on both ends of the
    connections it lists.
11. **`wiring` static.** With the robot down, run `wiring` again. It must fall
    back, label itself STATIC, say why, and claim no live evidence.
12. **`wiring` on a repo that is not a robot.** Run it against the GUI. It must
    go static without complaining that a robot is missing.
13. **Search latency.** Run the timed comparison from `docs/SETUP.md`, with and
    without the exclusions, and write both numbers into that robot's
    `~/dev/notes/<name>/decisions.md`. Not into SETUP.md. If the excluded case
    is still slow, that robot should mount its workspace instead of its home
    directory, and the reason goes in the same `decisions.md`.
14. **The exclusions actually bite.** With the bot mounted, ask the agent to
    search for something that only exists under `build/` or in a `.bag`. On
    Claude Code the deny rule should block it. On an agent where the rule is only
    written down, note what actually happened. That difference is the whole point
    of the capability table.
15. **Nothing landed on the robot.** After all of the above:
    `ssh <user>@<host> 'ls -la ~; ls -la ~/.claude ~/.cursor ~/.codex ~/.agents 2>/dev/null'`.
    There must be no agent config, no notes, no botkit files. This is the
    constraint the whole project exists to protect, so check it last and check it
    properly.

### What to do with the results

Record them in `~/dev/notes/botkit/progress.md`, and anything that turned out to
be a design decision rather than a result in `decisions.md`. Do not write those
results into this file. This file is public. If a check fails, fix botkit
rather than relaxing the check.

## How to work in this repo

Read `README.md` first, then `docs/CONFIG.md`. The existing code has patterns
worth copying rather than reinventing:

- `settings_json_edit` in `lib/common.sh` is the safe jq read-modify-write.
- `write_search_denies` shows the prefix-ownership trick for editing a shared
  config file without clobbering the user's own entries.
- `dir_hash` and `file_hash` are how the installer tells a real change from a
  re-copy, which is what makes the "nothing changed" report honest.
- Every failure exits nonzero with one line. Keep that.

Test with `HOME=<a temp dir> ./install.sh` so nothing touches the real home
directory. That is how the current install was validated.
