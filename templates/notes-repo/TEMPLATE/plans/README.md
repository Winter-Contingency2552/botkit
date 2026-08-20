# plans

One file per piece of work. Written while the robot may be off.
`in-class-planning` execute reads this, checks every assumption, then
runs a parallel worker swarm until the Goal is done.

The planning stage exists to name the Goal. Warn that the skill is
expensive before using it.

Never write a plan under `mount/`.

## Format

```
# <short title>
Status: draft | aligned | executing | done | blocked
Date: YYYY-MM-DD
Repo: __REPO__

## Goal
One or two lines. What done looks like. The swarm stops when this is true.

## Evidence
Which notes files were read. architecture.md is possibly stale.

## Assumptions
Numbered. Each one is a claim that must be true before the change is safe,
and each one says how to check it once the robot is up.

1. Claim: ...
   Check: `bot run <name> -- ...` or a path under mount/ or a path in a
   LOCAL_REPOS clone.

## Workstreams
Independent slices for parallel workers. One owner per file.

1. Name: ...
   Owns: <paths>
   Blocked by: none | <other workstream names>
   Done when: ...

## Out of scope

## Open questions
Things the notes cannot answer. These become checks at execute, or they
block. Do not fill them with a guess.
```

Status `aligned` means the user agreed. Execute will not swarm a `draft`.
A failed check sets `blocked`. A finished change sets `done`. Keep the
file. Do not delete it.
