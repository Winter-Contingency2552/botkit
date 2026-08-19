# Making botkit work with any agent

A work spec. Hand this to an agent in this repo and it should be able to do the
job without asking what any of the pieces are.

## Goal

botkit currently assumes Claude Code. The shell tooling does not, but the
installer does, and every piece of enforcement it configures is written in
Claude Code's formats. Change that so botkit works with any coding agent, gives
each one as much enforcement as it genuinely supports, and says plainly which
parts are enforced and which are only written down.

Do not remove any Claude Code capability while doing it.

## What already works with any agent

None of this needs changing. It is plain shell and plain files.

| Piece | Why it is neutral |
|---|---|
| `scripts/bot` | shell, ssh, sshfs. No agent involved. |
| `bots/*.conf` | shell key/value. |
| `~/dev/notes/` and `templates/notes-repo/` | markdown in a git repo. |
| `lib/common.sh` mount and ssh helpers | shell. |
| The notes contract | a convention, not a mechanism. |

## What is Claude-specific today

| Piece | Current mechanism | Lives in |
|---|---|---|
| Instructions file | `~/dev/CLAUDE.md` | `install.sh`, `templates/CLAUDE.md` |
| Skills | copied to `~/.claude/skills/<name>/` | `install.sh` |
| unslop nudge | `PostToolUse` hook in `~/.claude/settings.json` | `install.sh`, `hooks/unslop-gate.sh` |
| Search exclusions | `permissions.deny` `Read(...)` rules in `settings.json` | `lib/common.sh` `write_search_denies` |
| Plugin install | `claude plugin marketplace add` | `install.sh` |
| Preflight | requires the `claude` binary | `install.sh` `DEPENDENCIES` |

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
- The file-edit hook event is **`afterFileEdit`**, not `PostToolUse`.
- `afterFileEdit` input: `{"file_path": "<absolute path>", "edits": [{"old_string": "...", "new_string": "..."}]}`.
  The path is at the **top level**, not under `tool_input`.
- Exclusions: `.cursorignore` in the project root, gitignore syntax. It blocks
  Agent, Tab, Inline Edit, and `@` mentions. **It does not block the terminal or
  MCP server tools**, which is the same limitation Claude's deny rules have.

### Codex (NOT verified, check before using)

- Config lives at `~/.codex/config.toml` and it supports lifecycle hooks.
- It reads `AGENTS.md`.
- The exact hook event names, payload shape, and config keys were **not**
  confirmed. Verify against `https://developers.openai.com/codex/config-reference`
  before writing this adapter. If you cannot confirm them, ship Codex as a
  generic agent instead of inventing a config format.

### How the above was verified

```bash
curl -sfL https://docs.claude.com/en/docs/claude-code/memory.md
curl -sfL https://docs.claude.com/en/docs/claude-code/hooks.md
curl -sfL https://docs.claude.com/en/docs/claude-code/permissions.md
curl -sfL https://cursor.com/docs/rules
curl -sfL https://cursor.com/docs/skills
curl -sfL https://cursor.com/docs/hooks
curl -sfL https://cursor.com/docs/reference/ignore-file
```

## The design

An adapter layer. `install.sh` stops knowing about any specific agent and asks
adapters instead.

```
lib/agents/
  generic.sh   always applied, to every agent, including ones nobody wrote an adapter for
  claude.sh
  cursor.sh
```

Each adapter defines these four functions. `install.sh` sources one adapter at a
time and calls them.

```bash
agent_label          # human name, e.g. "Claude Code"
agent_detect         # exit 0 if this agent is present on the machine
agent_capabilities   # print any of: context skills hooks exclusions
agent_apply          # do the work. Must be idempotent.
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

## Work items

### 1. AGENTS.md becomes the real instructions file

Rename `templates/CLAUDE.md` to `templates/AGENTS.md` and strip the Claude Code
specific wording from it. Install it to `~/dev/AGENTS.md`.

The Claude adapter then creates `~/dev/CLAUDE.md` as a symlink to `AGENTS.md`,
because Claude Code does not read `AGENTS.md`.

Keep the existing non-clobber behaviour: if `~/dev/AGENTS.md` already exists and
differs from the template, write `AGENTS.md.new` beside it and say so. Never
overwrite. If `~/dev/CLAUDE.md` already exists as a real file rather than a
symlink, leave it alone and tell the user to merge it by hand.

### 2. A regenerated block inside AGENTS.md

Folded rules have to be refreshed when bots change, without destroying anything
the user wrote. Use markers:

```markdown
<!-- botkit:begin generated -->
...regenerated content...
<!-- botkit:end generated -->
```

Replace only what is between the markers. If they are absent, append them. This
block holds the rules an agent cannot enforce mechanically:

- the actual mount paths, listed
- the actual excluded paths per bot, listed, since without deny rules the agent
  needs to be told what not to search
- the instruction to apply unslop to prose, for any agent with no hook support
- a line naming which of these are enforced on this agent and which are not

`install.sh` and `bot up` both regenerate it, from one shared function in
`lib/common.sh`, the same way `write_search_denies` and `write_unslop_conf`
already work.

### 3. The hook script speaks both dialects

`hooks/unslop-gate.sh` currently reads `.tool_input.file_path`. Make it accept
either shape:

```bash
path="$(jq -r 'try (.tool_input.file_path // .file_path) // empty')"
```

Keep the existing behaviour that it exits 0 on every path, including bad input
and a missing `jq`. Confirm what Cursor's `afterFileEdit` accepts as output
before emitting Claude's `hookSpecificOutput` shape to it. See open questions.

### 4. The Cursor adapter

Capabilities: `context skills hooks exclusions`, minus hooks if the open
question below resolves against it.

- Skills: copy the same `SKILL.md` directories into `~/.cursor/skills/<name>/`.
- Hook: merge into `~/.cursor/hooks.json` with `jq`, same
  read-modify-write-atomically approach as `settings_json_edit`, matching and
  replacing any existing botkit entry by its command path so re-running never
  stacks duplicates.
- Exclusions: write `.cursorignore` in the mount point. **Check this against the
  rule that botkit never writes to a mount.** A `.cursorignore` inside
  `~/dev/<bot>/` would land on the robot's disk, which is forbidden. If Cursor
  has no user-level ignore file that works from outside the mount, this
  capability must be dropped and folded into `AGENTS.md` instead. Do not break
  the no-writes-to-the-robot rule to gain an ignore file.

### 5. Preflight stops requiring claude

`DEPENDENCIES` becomes `sshfs jq git ssh`. Then detect agents separately. If no
known agent is found, that is a warning and not an error: install everything
neutral, write `AGENTS.md`, and say which agents were looked for.

### 6. The capability report

At the end of the run, print a table. This is the part the user specifically
asked for, so do not reduce it to a single line.

```
Agent          Context      Skills   Hook     Exclusions
Claude Code    CLAUDE.md    9        enforced enforced
Cursor         AGENTS.md    9        enforced written down
Unknown agent  AGENTS.md    -        -        written down
```

State plainly, in words and not just in a table, that a rule written into
`AGENTS.md` is an instruction the agent may ignore, while a hook or a deny rule
is enforced by the harness. They are not equivalent and the report must not
imply they are.

### 7. uninstall.sh reverses all of it

Per agent, using the same adapters. It already refuses to touch `~/dev/notes/`,
and that must stay true.

### 8. Docs

- `docs/SKILLS.md`: per-agent install locations.
- `docs/CONFIG.md`: what each adapter writes, and where.
- `docs/SETUP.md`: the per-agent restart or reload step.
- `README.md`: stop implying Claude Code is required.
- This file: update it as things get built, rather than leaving it as a plan.

## The rule that must hold

Where an agent cannot enforce something, fold the rule into `AGENTS.md` as an
instruction **and say that is what happened.** A written rule is weaker than an
enforced one. The install report and the docs both have to be honest about which
is which, because someone will otherwise assume a deny rule is protecting them
when only a sentence is.

## Open questions

**Can Cursor's `afterFileEdit` return context to the agent?** Claude's
`PostToolUse` supports `hookSpecificOutput.additionalContext`, which is how the
unslop nudge reaches the model. The only Cursor hook output contract found so far
was `{"permission": "allow" | "deny"}`, on a different event. If `afterFileEdit`
cannot inject context, the unslop nudge cannot work as a hook on Cursor and must
fold into `AGENTS.md`. Resolve this at `https://cursor.com/docs/hooks` before
building work item 4.

**Does a user-level Cursor ignore file exist?** Needed to keep work item 4 from
writing into a mount. The docs mention a global ignore list in user settings.
Find out whether it is reachable from a config file rather than only the GUI.

## Acceptance checks

1. `./install.sh` succeeds on a machine with no agent installed at all, and says
   so rather than failing.
2. `~/dev/AGENTS.md` exists. `~/dev/CLAUDE.md` is a symlink to it.
3. Claude Code keeps everything it has today: 9 skills, the `PostToolUse` hook,
   and the `Read(...)` deny rules. Verified by the checks already in this repo.
4. With Cursor installed, `~/.cursor/skills/` gets the same 9 skill directories.
5. The generated block in `AGENTS.md` lists real mount paths and real exclusion
   lists, and regenerates on `bot up` without touching text outside the markers.
6. Editing `AGENTS.md` by hand outside the markers, then re-running
   `install.sh`, preserves the edit.
7. A second `./install.sh` reports that nothing changed, which is already how
   this repo tests idempotency.
8. The capability report distinguishes enforced from written down.
9. `./uninstall.sh` leaves `~/dev/notes/` alone and restores every agent's
   config from its backup.
10. Adding a new adapter file to `lib/agents/` makes that agent work with no
    edit to `install.sh`.

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
