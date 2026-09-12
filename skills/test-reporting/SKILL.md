---
name: test-reporting
description: Summarise a test run, diff it against the previous one, and publish the report. Use during /test-report, including /test-report --coverage, or when asked how the last run went.
---

# Reporting

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

**The model never sees a passing row.** A green run should cost almost nothing
to report. `tf.sh` holds the results; you read only what failed.

```sh
tf.sh summary                         # the CLI dashboard panel
tf.sh latest 2                        # two most recent result files
tf.sh diff <previous> <latest>        # REGRESSED / FIXED / NEW only
tf.sh render <latest> tests/results/report.html
tf.sh stats                           # suite-wide counts
tf.sh cover tests/.cache/routes.txt   # uncovered/thin routes
```

## Print the panel; do not describe it

`tf.sh summary` already renders the verdict, the pass-rate bar, the per-type
breakdown, security failures, regressions, fixes, warnings and the suggested
next command — laid out, aligned and colour-aware.

**Print that output verbatim as your final message. Add nothing.**

Re-narrating it in prose costs more tokens than the entire run did, and says
less. `run-api` already prints it, so in the normal path you say *nothing at
all* after the run — the panel is the answer.

Add a sentence of your own only when you know something the panel cannot: an
app that would not start, a login that failed, a case you chose to skip.

Its exit code is meaningful — `0` all pass · `1` failures · `2` a security
failure · `3` could not run — so use it rather than re-deriving the verdict.

Other modes: `--quiet` (one line), `--json` (CI), `--ascii` (terminals that
mangle Unicode), `--no-color`.

For prose beyond the panel, coverage reporting and Artifact publishing, see
`references/prose-coverage-publishing.md`; for `--bug <id>`, the report shape and
the `gh issue create` hand-off are in `references/bug-reports.md`.

## Never report an unverified pass as a pass

If the panel warns that cases ran without a session, those verdicts are
worthless — a logged-out request is denied whether or not the app is secure.
Repeat that warning in any prose summary. Reporting them as green is the most
damaging thing this framework can do.

## Redaction

Redact on write, not on display. Anything reaching `results/`, `evidence/`, a
bug report or an Artifact must already be free of credential values before it
gets there. Detail in `references/prose-coverage-publishing.md`.
