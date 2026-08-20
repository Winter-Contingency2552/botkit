# Domain docs for __REPO__

How the engineering skills should consume domain documentation for this repo.
The source tree may be a mount. These files live on the laptop.

## Before exploring, read these

- `notes/__REPO__/CONTEXT.md` if it exists
- `notes/__REPO__/decisions.md`. That file is the ADR log. There is no
  `docs/adr/` copy, and one must not be created in the source tree.

If `CONTEXT.md` does not exist yet, proceed silently. `/grill-with-docs` and
`/domain-modeling` create it when terms actually get resolved. Write it at
`notes/__REPO__/CONTEXT.md`, never at the source root.

## Use the glossary's vocabulary

When output names a domain concept, use the term as defined in `CONTEXT.md`.
If the concept is not in the glossary yet, either the project does not use
that word, or there is a real gap. Note the gap for `/domain-modeling`.

## Flag decision conflicts

If output contradicts `decisions.md`, surface it rather than silently
overriding.
