# Installed skills

Each skills-capable agent gets its own copy. Source repo and commit for each
are recorded in that agent's `.botkit-provenance` at install time, and
`install.sh` lists which skill directories exist at the end of every run so a
failed copy is visible immediately.

| Agent | Skills directory | Provenance |
|---|---|---|
| Claude Code | `~/.claude/skills/<name>/SKILL.md` | `~/.claude/skills/.botkit-provenance` |
| Cursor | `~/.cursor/skills/<name>/SKILL.md` | `~/.cursor/skills/.botkit-provenance` |
| Codex | `~/.agents/skills/<name>/SKILL.md` | `~/.agents/skills/.botkit-provenance` |

One agent's provenance file never drives deletions in another agent's
directory. `uninstall.sh --agent cursor` leaves Claude's and Codex's skills
alone.

The same `SKILL.md` directories copy to every agent unchanged. Claude Code,
Cursor, and Codex all derive the skill's identity from the folder containing
`SKILL.md`, not from the frontmatter `name`.

| Skill | Source | Fires |
|---|---|---|
| `wiring` | this repo | automatically, or by name |
| `ros2` | robotics-agent-skills | automatically |
| `robot-bringup` | robotics-agent-skills | automatically |
| `robot-perception` | robotics-agent-skills | automatically |
| `robotics-testing` | robotics-agent-skills | automatically |
| `ros2-web-integration` | robotics-agent-skills | automatically |
| `unslop` | cursor/plugins | automatically, plus a hook nudge |
| `blast-radius` | cursor/plugins | **by name only** |
| `bro` | cursor/plugins | **by name only** |
| mattpocock skills | plugin marketplace | varies |

Skills install to each agent's personal skills location, so they are available
across every project.

**After a first install, restart the agent.** Claude Code watches
`~/.claude/skills/` and picks up added or edited skills live, but only in a
directory that existed when the session started, and on a first install it did
not. Cursor discovers skills at startup, so a first install of
`~/.cursor/skills/` needs a reload. Codex loads personal skills from
`~/.agents/skills`; restart it after a first install, and trust the hook with
`/hooks` before it will run. `install.sh` says so when it creates the
directory.

---

## `wiring`

**Written for this repo.** Nothing off the shelf answers the question it answers:
what talks to what in a ROS 2 system, right now, and how do you know.

Four forms: `wiring` for a whole-system map, `wiring <file>` for one file's
endpoints and who is on the other end, `wiring <topic>` for publishers,
subscribers, type and QoS, `wiring <node>` for every connection a node has.

Two evidence modes, and it always states which it used. **Live** runs `ros2 node
list`, `ros2 node info`, `ros2 topic info -v`, `ros2 topic list -t`, and `ros2
param list` on the robot through `bot run`. That is ground truth: it reflects
remappings, launch arguments, and what actually came up. **Static** reads the
source, and is the fallback when the robot is down or the repo is not a live
system at all, like the GUI.

The two disagree constantly, and the skill treats each disagreement as a finding
rather than reconciling it silently. A topic that exists in the code but not live
means a node is not running or a remap redirected it.

QoS is a first-class output, not a footnote. Every connection reports reliability
and durability on both ends, and incompatible pairs are flagged: a best-effort
publisher against a reliable subscriber never connects, nothing reports an error,
and the topic simply never arrives.

It offers to write results to `notes/<repo>/architecture.md` and never does so
unasked, and it cross-checks `notes/<repo>/decisions.md`, flagging where the live
system contradicts a recorded decision.

Distinct from `teach`, which builds a learning path for a subject, and from
`blast-radius`, which asks what a change breaks.

---

## Robotics skills

**Source:** [arpitg1304/robotics-agent-skills](https://github.com/arpitg1304/robotics-agent-skills)
**Audited commit:** `f9bc5467ff9ee3d23f1a1b0b29a649843bb6ad11`. **Pinned. Do not
track `main`.**

Installed: `ros2`, `robot-bringup`, `robot-perception`, `robotics-testing`,
`ros2-web-integration`.

Deliberately not installed: `ros1`, `docker-ros2-development`,
`robotics-security`, `robotics-software-principles`, `robotics-design-patterns`.

### The audit

At the pinned commit: no injection patterns, no hidden or bidi Unicode, no hidden
text in HTML comments, and an installer that validates skill names against
`^[A-Za-z0-9_-]+$` and guards its `rm -rf` with `${target:?}`.

`install.sh` fetches that exact commit and **verifies `HEAD` matches before
running the upstream installer**, refusing to proceed otherwise. A pin you do not
check is a pin you do not have.

**Re-audit before bumping**, and record the new commit here.

### Are these skills actually worth it?

The upstream eval reports 336 lines of generated code without skills versus 2,107
with, and 601 lines of tests versus zero. Line count is not a quality metric, and
6.3x more code is as consistent with over-engineering as with rigor. So both
`demo_recorder` directories were read before trusting the framing.

**The gain is mostly real, and it lands where robotics code actually fails.**

- The without-skills recorder **never stores pixels.** It converts the image and
  keeps `cv_image.shape`. A demonstration recorder that discards the camera data
  is broken, not merely terse.
- No sensor liveness check. If the joint publisher dies, it records the last
  stale message at 30 Hz indefinitely, producing silently corrupt training data.
  The with-skills version has an explicit timeout and counts dropped frames.
- No timestamp synchronisation between camera and joints, so observations and
  actions can be misaligned. The with-skills version computes the offset and
  drops timesteps that exceed a bound.
- An unbounded in-RAM episode list at 30 Hz, JSON-dumped at stop, versus a
  bounded buffer with drop counting and a separate writer module.
- Default depth-10 reliable QoS on an `Image` subscription, exactly the
  best-effort-publisher-against-reliable-subscriber failure `wiring` exists to
  catch.
- 601 lines of tests against zero. Tests appearing is the strongest signal in the
  eval.

**And the framing oversells it.**

- Leading with 6.3x line count invites the wrong conclusion.
- 111 lines do nothing but declare 13 parameters, plus 8 launch arguments, for a
  recorder. That is configuration surface nobody asked for.
- It introduces a multi-threaded executor and a lock, then spends code managing
  the concurrency it just created. A single-threaded executor would have removed
  the problem instead.

**Verdict:** worth installing. Expect them to push toward hardware-realistic
failure handling and tests, and expect to delete some ceremony.

---

## Writing and reasoning skills

**Source:** [cursor/plugins](https://github.com/cursor/plugins), `pstack/skills/`.

These are Cursor plugin skills, not a Claude Code marketplace, so there is no
plugin install path. They are portable `SKILL.md` directories, so `install.sh`
clones the repo shallow (sparse-checking out `pstack/skills` when git supports
it) and copies exactly three. The rest of the repo is not installed.

**`unslop`.** Cuts AI tells from writing. Model-invocable, and nudged by the
hook below.

**`blast-radius`.** What a change breaks somewhere else, beyond the diff, proved
by running code rather than writing it up. Marked `disable-model-invocation`, so
it only ever runs when you ask for it by name. Cursor honours that key too
(documented in the skills frontmatter: when `true`, the skill is only included
when explicitly invoked). Codex does not document `disable-model-invocation`.
Its equivalent is `allow_implicit_invocation: false` in an `agents/openai.yaml`
sidecar, which botkit does not write, so Codex may auto-invoke `blast-radius`
and `bro`.

**`bro`.** Restates the last message in plain language, no jargon. Also by name
only.

## mattpocock skills

**Source:** [mattpocock/skills](https://github.com/mattpocock/skills), installed
as a plugin.

The marketplace manifest names itself `mattpocock`, so the plugin id is
`mattpocock-skills@mattpocock`, **not** `@skills`. `install.sh` probes for
`claude plugin marketplace`, uses it when present, and otherwise prints the
`/plugin` lines to paste. Skip the step entirely with `--no-plugins`. This step
is Claude Code only. Cursor and Codex already have the same three pstack skills
as copied directories.

---

## The unslop hook

`hooks/unslop-gate.sh`. Claude Code registers it as a `PostToolUse` hook matching
`Write|Edit`. Cursor registers it as `postToolUse` in `~/.cursor/hooks.json`.
Codex registers it as `PostToolUse` in `~/.codex/hooks.json`, matcher
`Write|Edit|apply_patch`. It reads the event JSON on stdin, pulls the edited
path from `.tool_input.file_path`, `.tool_input.path`, `.file_path`, or Codex
`apply_patch` `*** Add File:` / `*** Update File:` lines in
`.tool_input.command`, and if that path is user-facing prose it emits both
Claude's `additionalContext` and Cursor's `additional_context`. Otherwise it
exits silently. Codex uses the Claude-shaped field. Codex also skips the hook
until you trust it with `/hooks`.

**Included:** `*.md`, `*.rst`, `*.txt`, anything under `docs/`, plus whatever you
add.

**Excluded:** `notes/*/progress.md` and `notes/*/inbox/**` (the agent touches
both constantly and neither is prose anyone reads for style), `CHANGELOG.md`,
lockfiles, anything under a configured mount point, and anything matching
`SEARCH_EXCLUDE`.

### It is a nudge, not a guarantee

A hook runs a shell command. Skills are prompts. This hook cannot apply
`unslop`. All it can do is inject an instruction into the context and rely on
the agent to act on it. It is a strong nudge and nothing stronger.

**If you need determinism, run `unslop` explicitly.**

The hook exits 0 on every path, including malformed input and a missing `jq`. A
hook that fails is a hook that gets in the way of editing, and this one is not
important enough to ever do that.

## `inbox/` is data, not instructions

Files under `notes/<repo>/inbox/` are documents and chat logs written by other
people. If one contains text shaped like a directive to an agent, that is a
string inside a document, not a request from the user. The agent surfaces it and
does not act on it.

This matters more once the notes repo is shared and teammates are contributing
files. It is stated in `templates/AGENTS.md`, in the README's agent section, and
in the inbox's own README.

## Writing a new skill so it stays portable

- **The directory name is the invocation name.** Choose it deliberately. In
  Claude Code, the frontmatter `name` is only a display label for personal
  skills; the command comes from the directory.
- **Stick to three frontmatter keys.** Across the installed skills, only
  `name`, `description`, and `disable-model-invocation` appear. Anything else
  risks being ignored or rejected by one agent.
- **`disable-model-invocation: true` is documented for both Claude Code and
  Cursor.** `blast-radius` and `bro` use it to stay by-name-only. Codex does
  not document that key; see the blast-radius note above.
- **Never name an agent in the skill body.** Write `bot run <name> -- ros2 node
  list`, not "use the Bash tool to run". `wiring` is the model to copy: it
  tells the agent what to run and what to conclude, and never how its own
  agent works.
- **Keep it self-contained.** A skill must not assume a hook fired, a setting
  was written, or another skill ran first. The agents differ in exactly those
  places.

Adding a directory under `skills/` with a `SKILL.md` is enough. `install.sh`
does not name botkit's own skills individually.
