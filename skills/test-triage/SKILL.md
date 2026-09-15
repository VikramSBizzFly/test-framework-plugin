---
name: test-triage
description: Diagnose why a case failed and assign a verdict — app bug, stale test, environment, or flake — with the evidence each verdict requires. Use whenever a failing/error row needs a root cause, before filing a bug or touching pass_streak/flake_count, or when a case fails on a locator and might self-heal.
---

# Triage

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Delegate one failing case at a time to the `test-triager` agent; look across
runs for instability with `flake-analyst`, and judge a `tags=visual` diff with
`visual-reviewer`.

**A verdict decides whether a bug is recorded.** Hand every case triaged
`app-bug` to the `bug-reporter` agent, which writes it into
`tests/bug-report.xlsx` with `tf.sh bug from`. `stale-test`, `environment` and
`flake` never become bugs: an out-of-date test, a server that was down, and a
case that flips on its own are not defects in the app, and recording them
trains a team to stop reading the bug sheet. That is why a verdict needs the
evidence below before it is assigned.

A verdict without evidence is a guess. Every one of the four categories below
requires something concrete before you assign it — "probably flaky" is not a
diagnosis, it is how real bugs get waved away.

| Verdict | Required evidence |
| --- | --- |
| **app bug** | actual output contradicts `expected` on a fresh, reproduced run; behaviour, not markup, is wrong |
| **stale test** | the app changed on purpose (route moved, copy changed, field renamed) — cite the diff or source file that shows it |
| **environment** | preflight/login failed, non-2xx before the app logic ran, or a dependency (DB, third-party API) was unreachable — cite the specific error |
| **flake** | the case flipped verdict across runs with **no** code change in `source_files` between them — cite both run timestamps |

Never assign a verdict from the failure row alone. Re-run once against fresh
evidence (`tests/evidence/<id>/`) before deciding — a single sample cannot
distinguish app bug from environment.

## Locator failure vs assertion failure — self-heal only the former

A **locator** failure (element not found, selector timeout) can be self-healed
by re-deriving the locator from a fresh snapshot and reporting the patch — never
silently. An **assertion** failure (found the element, value is wrong) means the
app did something different than expected — that is never self-healed. Decline
to self-heal if the fresh snapshot shows *behaviour* changed, not just markup —
that's an app bug or stale test wearing a locator failure's clothes. Full
procedure and the decline criteria are in `references/self-heal.md`.

## Flake quarantine

A case that flips PASS/FAIL across runs with no matching change in its
`source_files` is unstable, not informative. After it flips **3 times**
(`flake_count` on the row), set:

```sh
tf.sh set <id> status=Flaky flake_count=<n>
```

`flaky` cases are excluded from the gating verdict but never dropped from the
CSV and never hidden from the run report — list them in their own section,
separate from real failures, per **test-reporting**. Mixing them into the
failure list is what trains users to stop reading the failure list.

`pass_streak` resets to 0 on any FAIL; a long streak after a flip is what
distinguishes "fixed" from "still flaky" — do not clear `flake_count` just
because the streak recovered.
