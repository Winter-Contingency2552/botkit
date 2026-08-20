# Engineering-skill config for __REPO__

Matt Pocock's skills look for `docs/agents/` inside a git repo. This directory
is that folder, on the laptop. The session is rooted at `~/dev/<bot>/`. A
robot's source is under `mount/`. Neither of those is the right place for
these files.

| File | What it is |
|---|---|
| `issue-tracker.md` | Where tickets for __REPO__ live |
| `domain.md` | Where `CONTEXT.md` and ADRs live |
| `triage-labels.md` | Status strings for local tickets |

Tickets go in `../scratch/`. Durable decisions stay in `../decisions.md`.
Change plans go in `../plans/`. `CONTEXT.md` is created later by
`/grill-with-docs`, next to this directory, not inside the source tree.
