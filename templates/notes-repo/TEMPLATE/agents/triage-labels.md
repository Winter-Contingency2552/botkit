# Triage labels

The skills speak in five canonical roles. Local markdown tickets under
`notes/__REPO__/scratch/` use these strings on the `Status:` line.

| Role | `Status:` value | Meaning |
|---|---|---|
| `needs-triage` | `needs-triage` | Needs a human to evaluate |
| `needs-info` | `needs-info` | Waiting on more information |
| `ready-for-agent` | `ready-for-agent` | Specified enough for an agent |
| `ready-for-human` | `ready-for-human` | Requires a human |
| `wontfix` | `wontfix` | Will not be actioned |

When a skill says to apply a role, write the matching `Status:` value.
