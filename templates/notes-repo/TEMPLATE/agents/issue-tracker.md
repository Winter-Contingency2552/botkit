# Issue tracker: local markdown on the laptop

Issues and specs for __REPO__ live as markdown files under
`notes/__REPO__/scratch/`. They do not live in the source tree. The source may
be a robot mount. Nothing in this directory is written there.

## Conventions

- One feature per directory: `scratch/<feature-slug>/`
- The spec is `scratch/<feature-slug>/spec.md`
- Implementation issues are one file per ticket at
  `scratch/<feature-slug>/issues/<NN>-<slug>.md`, numbered from `01`, never a
  single combined tickets file
- Triage state is a `Status:` line near the top of each issue file. See
  `triage-labels.md` for the role strings
- Comments append under a `## Comments` heading

## When a skill says "publish to the issue tracker"

Create a new file under `notes/__REPO__/scratch/<feature-slug>/`, creating the
directory if needed.

## When a skill says "fetch the relevant ticket"

Read the file at the referenced path. The user will normally pass the path or
the issue number directly.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a file with one **child** file per ticket.

- **Map**: `scratch/<effort>/map.md`
- **Child ticket**: `scratch/<effort>/issues/NN-<slug>.md`, numbered from `01`.
  A `Type:` line records `research` / `prototype` / `grilling` / `task`. A
  `Status:` line records `claimed` / `resolved`.
- **Blocking**: a `Blocked by: NN, NN` line near the top. A ticket is unblocked
  when every file it lists is `resolved`.
- **Frontier**: scan `scratch/<effort>/issues/` for files that are open,
  unblocked, and unclaimed. First by number wins.
- **Claim**: set `Status: claimed` and save before any work.
- **Resolve**: append the answer under `## Answer`, set `Status: resolved`,
  then append a context pointer to the map's Decisions-so-far in `map.md`.

To use GitHub issues for this repo instead, replace this file with the GitHub
workflow and run `gh` from the laptop clone, never from a mount.
