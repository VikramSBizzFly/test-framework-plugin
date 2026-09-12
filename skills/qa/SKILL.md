---
name: qa
description: Test a running web app and find real bugs in it - map its flows, generate test cases into an Excel workbook, check pages in a real browser, hit API endpoints with curl, verify permissions, responsive layout and accessibility, and report what failed. Use whenever someone asks to test an app or site, write or generate test cases, do QA, find bugs, check whether something is broken, look for regressions, map the flows or user journeys of the software, verify a user cannot see what they shouldn't, test an API or endpoints, check whether a page breaks on mobile or at a small screen, run Playwright or browser tests, check accessibility, open or update the test cases workbook, ask what has no test coverage, or ask why a test keeps failing. This is the entry point - start here and route to /test-setup, /test-run or /test-report. Not for unit-testing a single function, questions about a test library the project already uses, or projects with no web app.
---

# QA — start here

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Someone asked about testing in plain language. Your job is to work out what they
actually want, do the free part immediately, and ask before the slow part.

## 1. First, decide whether this is yours

This framework tests a **running web app** end to end. It is the wrong tool for
a unit test of a single function, a question about the project's existing test
library, a native mobile app, or a repo with no web app in it.

If it is one of those, say so in one line and help with the actual question.
**Do not take the request over.** A tool that hijacks every sentence containing
the word "test" gets uninstalled.

## 2. Work out where this project already is

| State | What to do |
| --- | --- |
| no `tests/framework.json` | first time here — run `/test-setup`, then continue |
| no `tests/.cache/flows.txt` and they asked about flows | `flow-mapper` per feature, then `tf.sh xlsx` |
| suite exists, no `tests/results/` | run `/test-run` |
| results exist and the question is about them | `/test-report` — do not re-run to answer a question you already have the answer to |
| `tests/credentials.json` still has empty roles | ask them to fill it in; without a login every permission case is meaningless |

## 3. Match the request to the right entry

| They said | You run |
| --- | --- |
| "test my app", "write tests", "QA this" | `/test-setup` if needed, then `/test-run` |
| "map the flows", "what are the user journeys" | the `flow-mapper` agent, then `tf.sh xlsx` |
| "is it broken on mobile", "check responsive" | `/test-run --responsive` |
| "open/update the test cases file" | `tf.sh xlsx` — the workbook is `tests/testcases.xlsx` |
| "find bugs", "is anything broken" | `/test-run` |
| "is it secure", "can a user see someone else's data" | `/test-run --security` |
| "test my API", "check the endpoints" | `/test-run` — `api` cases run on curl, free |
| "does it work for screen readers" | `/test-run --a11y` |
| "what isn't tested" | `/test-report --coverage` |
| "why does this keep failing" | `/test-report --flakes` |
| "file a bug for that" | `/test-report --bug <id>` |
| "run it in CI" | `/test-setup --ci` |

## 4. Do the free work now, then ask

Run these without asking — they cost nothing and often answer the question on
their own: `tf.sh preflight`, `tf.sh cache-check`, route discovery, and
`tf.sh run-api` for the curl cases.

**Then stop and ask once**, with numbers attached: how many browser cases, how
many minutes, and the projection from `tf.sh cost`. A browser run takes minutes
and spends tokens — nobody should discover that after it started.

Ask first, every time, for: a full browser run, `--allow-destructive`, and any
non-local `base_url`.

## 5. The guards still apply

`tf.sh preflight` refuses a remote target without `allow_remote`. Destructive
cases stay `skipped` unless asked for. A 2FA or CAPTCHA prompt stops the run and
goes back to the person — never try to solve one. Credentials never reach the
transcript.

Each command's own file has the detail; load the skill that command names rather
than improvising the stage yourself.
