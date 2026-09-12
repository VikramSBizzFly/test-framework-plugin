---
name: test-ci
description: Run the suite unattended and turn its exit code into a job verdict. Use when wiring the framework into CI, when a pipeline needs the right flags and environment, or when deciding which stages can run on a machine with no browser.
---

# CI

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

CI has no person watching, so everything this framework normally says in a panel
has to survive as an exit code and an artifact. Delegate the wiring to the
`ci-wirer` agent; start from `templates/<stack>/ci/github-actions.yml`, which is
copied in, never auto-enabled.

## The exit code is the verdict

| exit | meaning | the job should |
| --- | --- | --- |
| `0` | all pass | pass |
| `1` | test failures | fail |
| `2` | **a privilege boundary was crossed** | fail, and say so distinctly |
| `3` | could not run — app down, no session, guard refused | fail as **infrastructure** |

Never re-derive the verdict from parsed output; `tf.sh summary` already decided
it. Keeping `2` and `3` distinct from `1` is the whole point: a security failure
is not "some tests are red", and an app that never started is not a test result
at all.

## Flags and environment

- `--json` for a machine, `--quiet` for one line, `--no-color` always — CI logs
  mangle colour and the panel's box drawing.
- `TF_PROGRESS=checkpoint` (or `0`/`off` to silence it) — the live progress bar
  is for a terminal; CI gets throttled plain lines on stderr, capped per run.
- `TF_TESTS_DIR` relocates the suite when the job checks the app out elsewhere.

## What actually runs, by tier

- **Tier 0** — the curl pass (`tf.sh run-api`) only. Recipe replay needs the
  Playwright MCP, which a CI runner does not have. Say this plainly rather than
  wiring a job that silently tests a fraction of the suite.
- **Tier 1/2** — the project's own runner over the promoted specs, which is what
  the templates invoke. At Tier 2 the runner emits JUnit XML; otherwise
  `tf.sh junit <xml>` converts results into the run CSV.

Always upload `tests/results/*.csv` as an artifact — the run panel is
reconstructible from it, and `tf.sh diff` needs the previous run to report a
regression.

## Never

Commit `tests/credentials.json`, or write a credential into a workflow file —
roles come from repository secrets, referenced by name, and the job builds the
file at runtime. Leave `allow_remote` at `false`: a CI job pointed at production
is precisely what the production guard exists to stop.
