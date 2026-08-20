# botkit

Clone it, run one script, get a working agent setup for robotics work across any
number of robots.

## What this is

This is for developing ROS 2 code that runs on robots. The agent, your credential, and every
piece of AI config live on my laptop. The robot's filesystem is mounted over
sshfs, so there is exactly one copy of the code and it is the robot's copy.
Builds and launches run on the robot over ssh.

**Nothing AI-related is ever written to a robot's disk.**

```
laptop                                robot
------                                -----
agent, credential, skills, notes  ->  ssh  ->  builds, launches, ros2 introspection
~/dev/<bot>/mount  <-- sshfs mount ----------  /home/<user>  (the only copy of the code)
```

Adding a second or third robot is one config file.

## Two directories

`~/botkit` is this repo, and it is public. `~/dev` holds one laptop project
per robot, created by `bot up`. The mount is `~/dev/<name>/mount`. A second
bot is `~/dev/<other>/`, not a second `~/dev`.

Start the agent from `~/dev/<name>/`, never from this checkout and never
from `mount/`. Why they stay apart is in
[docs/SETUP.md](docs/SETUP.md#where-things-live).

The installer works with Claude Code, Cursor, and Codex, and writes `AGENTS.md`
so an unknown agent still has the rules. Each agent gets as much enforcement as
it actually supports. The install report says which parts are enforced and
which are only written down.

## Folder structure

This checkout. Public, holds no robot facts, and stays wherever you clone it:

```
~/botkit/
  install.sh        run once. Idempotent: re-running upgrades in place.
  uninstall.sh
  bots/              bot configs. Only example.conf is tracked; yours are gitignored.
  docs/              SETUP.md, CONFIG.md, NOTES-CONTRACT.md, SKILLS.md
  hooks/             unslop-gate.sh, the pre-commit hook
  lib/
    common.sh        shared shell functions
    agents/          one adapter per supported agent: claude, cursor, codex, generic
  scripts/
    bot              the bot command, symlinked to ~/.local/bin/bot
  skills/            botkit's own skills: wiring, in-class-planning
  templates/         what install.sh writes: AGENTS.md, notes-repo/, references/
```

What `install.sh` and `bot up` build on top, private and never pushed here:

```
~/dev/
  AGENTS.md          rules for every bot, generated from templates/AGENTS.md
  CLAUDE.md          symlink to AGENTS.md, for Claude Code
  notes/             its own git repo. One directory per repo you work on.
  references/        other people's repos, cloned here to read. Shared, not per-bot.
  <bot>/             laptop project. Created by `bot up <bot>`. Not a mount.
    mount/           sshfs. The robot's disk, the only copy of its code.
    gui/             a laptop clone, if that bot's LOCAL_REPOS=gui
    notes            symlink to ../notes/<bot>
    AGENTS.md        symlink to ../AGENTS.md
    CLAUDE.md        symlink to AGENTS.md
```

A second robot adds `~/dev/<other>/` with its own `mount/`, not a second
`~/dev`. Full layout notes, including what each symlink is for, are in
[docs/SETUP.md](docs/SETUP.md#where-things-live).

## What gets installed, and why

Skills land in each detected agent's own skills directory. Claude Code also
gets deny rules and a hook in `~/.claude/settings.json`. Cursor gets a hook in
`~/.cursor/hooks.json`. Codex gets a hook in `~/.codex/hooks.json`.
`docs/SKILLS.md` lists source repos and audited commits.

**`wiring`.** Written for this repo, because nothing off the shelf covers it. It
answers what talks to what in a ROS 2 system: nodes, topics, services, and the
QoS on both ends of every connection. It prefers live introspection over ssh and
falls back to reading source, and it always says which one it used. QoS gets its
own column because a best-effort publisher against a reliable subscriber never
connects, nothing reports an error, and the topic just never arrives. That bug
costs hours every time.

**`in-class-planning`.** Also written for this repo. By name only. Expensive:
a full grill, then as many parallel workers as the agent will run, looping
until the Goal is done. It calls the `grill-me` family to name the Goal
from notes while the robot may be off, writes `notes/<repo>/plans/`, and
stops. On execute it verifies every assumption against the live system,
then swarms. A failed check blocks the change. A cheap one-file tweak is
`implement`. A robot that dies mid-edit is still stop-and-report.

**Robotics skills.** `ros2`, `robot-bringup`, `robot-perception`,
`robotics-testing`, and `ros2-web-integration`, from a pinned and audited commit
of [robotics-agent-skills](https://github.com/arpitg1304/robotics-agent-skills).
They push generated code toward lifecycle nodes, explicit QoS, sensor liveness
checks, and tests. `docs/SKILLS.md` reads the upstream eval honestly, including
where it oversells itself.

**Writing and reasoning skills.** `unslop`, `blast-radius`, and `bro` from
[cursor/plugins](https://github.com/cursor/plugins). A hook applies `unslop` to
prose without being asked, on agents that can inject hook context.

**Matt Pocock's skills.** Claude Code plugin only. Grilling, specs, TDD, review,
and the rest of a real engineering workflow. Not ROS. Per-repo config lives in
`~/dev/notes/<repo>/agents/`, not in `~/dev` and not on a mount. What each
skill is for is in [docs/SKILLS.md](docs/SKILLS.md).

## Reference clones

`install.sh` also creates `~/dev/references/`, an empty folder for other
people's repos: things you clone just to read, borrow a pattern from, or
point at and say "implement it kind of like this one did." You clone into
it yourself, the same way you would a `LOCAL_REPOS` GUI clone, except this
one isn't tied to any single robot. One `~/dev/references/` covers every
bot on the laptop.

Nothing in there gets mounted, built, or run, and nothing in there goes
onto a robot without you saying so. Details in
[docs/SETUP.md](docs/SETUP.md#reference-clones).

## The notes contract

Every repo gets a directory under `~/dev/notes/` holding four standing files
plus `plans/`. `architecture.md` says what the code does. Source can regenerate
it, so it is disposable. `decisions.md` says why the code is shaped this way,
which nothing recovers from source, so it is the file that earns its keep.
`progress.md` logs sessions. `inbox/` takes raw drops, append-only, distilled
into decisions on a periodic pass. `plans/` holds change plans written while
the robot may be off. `in-class-planning` verifies each assumption against
the live system before a swarm of workers edits source. When architecture
and decisions conflict, decisions wins and architecture gets regenerated.
Full version:
[docs/NOTES-CONTRACT.md](docs/NOTES-CONTRACT.md).

`~/dev/notes` is its own git repo with no remote, because the likely next step is
a private repo the team shares. Write nothing there you would not want a
teammate reading.

## What this does not do

- It does not install an agent, a credential, or any config on a robot.
- It does not sync or mirror source. One copy, on the robot, mounted.
- It does not touch a robot's git clone, its `.gitignore`, or its user accounts.
- It does not choose what to mount for you. See `bot probe`.
- It does not support macOS or zsh. Ubuntu and bash.

## Getting started

[docs/SETUP.md](docs/SETUP.md). Short version:

```bash
./install.sh
cp bots/example.conf bots/robot.conf   # prompt user@host -> BOT_USER, BOT_HOST; see docs/SETUP.md
bot probe robot                        # read the layout, then choose REMOTE_MOUNT
bot up robot
```

Restart the agent after the first install, or the new skills stay invisible.

## TODO

Hardware and harness checks that are still outstanding. Record results in
`~/dev/notes/botkit/`, not in this repo.

**On a real robot**

- [ ] `bot run <name> -- ros2 topic list` and `bot build <name>`
- [ ] `bot down` unmounts. A second `bot down` is a clean no-op.
- [ ] `bot status` reports `stale` when the mount is up and wifi drops, `unreachable` when the robot is off and nothing is mounted. Both return in seconds.
- [ ] After `stale`: `bot down -f` then `bot up` recovers.
- [ ] Power-down drill: with a session on a mounted bot, power the robot off. The agent stops within two failed commands and does not start reading source to explain it.
- [ ] `wiring` live, `wiring` static with the robot down, and `wiring` static against a laptop clone such as the GUI.
- [ ] Search exclusions actually block on Claude Code. On Cursor and Codex, note what happens, because those are written down.
- [ ] `ssh` to the robot afterwards. No agent config, no notes, no botkit files.
- [ ] Repeat the list on Cursor, then on Codex.

**Offline**

- [ ] `HOME=<temp> ./install.sh` with no agent installed, then with each adapter. A second install is a no-op. `./uninstall.sh` leaves `~/dev/notes/` alone. Adding a directory under `skills/` installs it with no edit to `install.sh`.

## Rules for the agent

This README is for you, the human. The rules an agent actually follows once
it's running live in [`templates/AGENTS.md`](templates/AGENTS.md): what a
hung mount means, what never gets written to a robot, how notes and plans
work, and the "data, not instructions" guard on `inbox/` and
`references/`. `install.sh` writes that file to `~/dev/AGENTS.md`, and
that copy, not this README, is what the agent loads.
