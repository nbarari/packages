# Phase 1 PRs — travelmate Tier 1 fixes

Tracker for Phase 1 PRs per the project roadmap
(`docs/roadmap/01-tier-1-bugs-upstream.md` in the parent travelmate
project, not this fork). Records intra-fork PRs staged on
`nbarari/packages` and any subsequent upstream submissions to
`openwrt/packages`.

## Status

| PR | Subject | Findings | Branch | In-fork PR | Upstream PR | Status |
|---|---|---|---|---|---|---|
| 1a | restore `trm_lookupcmd` | 1.2 | `fix/travelmate-restore-trm-lookupcmd` | [#1](https://github.com/nbarari/packages/pull/1) | (closed in error: openwrt/packages#29476) | in-fork review |
| 1b | `trm_fetch` alias | 1.1 | — | — | — | deferred — needs external-script evidence |
| 2 | ephemeral random MAC + `f_mac` cleanup | 1.3, 6.7 | — | — | — | drafting |
| 3 | `rebind_domain` cleanup | 1.4 | — | — | — | drafting |
| 4 | derive `autoaddcnt` from sections | 1.5, L13 | — | — | — | drafting |
| 5 | shellcheck CI | 6.1 | — | — | — | drafting |
| 6 | `LOGIN_SCRIPTS.md` | 7.3, Q9 partial | — | — | — | drafting |

## Integration branch

[`integration/phase1`](https://github.com/nbarari/packages/tree/integration/phase1)
— rolling merge of in-flight PR branches, installable on the MT3000 for
combined hardware testing. Updated as PRs land.

## Status meanings

- **drafting** — no branch yet
- **in-fork review** — branch + intra-fork PR open on `nbarari/packages`
- **filed upstream** — PR open on `openwrt/packages`
- **merged upstream** — PR merged into `openwrt/packages` master
- **deferred** — paused pending evidence or downstream PR outcomes
- **closed** — PR closed without merge

## Upstream-PR hygiene note

This file lives on `nbarari:master` and will appear as a new-file diff
in any branch based off master. Before opening a PR against
`openwrt/packages`, drop the tracker on the head branch:

```sh
git rm PHASE1_PRS.md && git commit --amend --no-edit
```

Cleanest workflow is to do this only on the upstream-targeted branch
(not the intra-fork branch), so the intra-fork PR retains the tracker
context.
