---
description: Show the last test result again
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Show the last result. Arguments: `$ARGUMENTS`
(`--coverage` for gaps · `--bug <id>` for a bug report · `--flakes` for unstable
cases · `--publish` for a shareable page).

Run `tf.sh xlsx --status` first so the workbook matches the last run, then
`tf.sh summary` and **print its output verbatim. Add nothing.** It already
renders the verdict, what regressed, what got fixed and what to do next.
Re-describing it costs more than the run did.

Load the **test-reporting** skill for anything beyond that.

**`--coverage`** → the `coverage-analyst` agent. It runs
`tf.sh cover tests/.cache/routes.txt` and returns uncovered and thin routes
grouped by area and ranked by risk — behind a login, takes input, touches money
or personal data — capped at 20 lines. Print what it returns; do not re-list.

**`--bug <id>`** → the `bug-reporter` agent. It reads `tests/evidence/<id>/` and
`source_files` so the evidence never reaches this conversation, records the bug
in `tests/bug-report.xlsx` with `tf.sh bug from`, and returns a ready
`gh issue create`. Offer the command; let the user run it. It declines a case
triage called anything other than an app bug. **Never put a password in a bug
report.**

Whenever bugs exist, say how many are open and point at `tests/bug-report.xlsx`
— `tf.sh bug list --status Open` has the rows. The run panel already names any
open bug whose case now passes; that is the retest to suggest.

**`--flakes`** → the `flake-analyst` agent: cases that flip verdict across runs
with no matching source change, and the `tf.sh set <id> status=Flaky` commands
to quarantine them. It proposes; you apply only if the user says so.

**`--publish`** → `tf.sh render`, then publish it as an Artifact — after
checking no credential appears anywhere in the HTML.
