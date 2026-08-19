# __REPO__ decisions

> Why the code is shaped the way it is: what was chosen, what was rejected, what
> was tried and failed, what constraint forced a shape. None of this is
> recoverable by reading the source. This is the file that earns its keep.
>
> Superseded decisions get marked superseded. They are never deleted. A decision
> that was reversed tells you more than one that was never made.

## Format

```
## <short title>
Date: YYYY-MM-DD
Status: accepted | superseded by <title> | rejected

Context: what forced the question.
Decision: what was chosen.
Rejected: what else was considered, and why not.
Consequence: what this makes easy, and what it makes hard.
```

---

## What gets mounted for this robot
Date:
Status: accepted

Context: `REMOTE_MOUNT` has no default. The choice trades search speed against
coverage, and `bot probe` reports the numbers for this specific robot. If a
similar robot already has this decision recorded, say what you reused and what
differs.

Decision: <workspace path or home directory>

Rejected: <the other one>, because <the probe numbers or the layout reason>.

Consequence:

<!-- Delete this entry if this repo is not a robot. -->
