---
description: Set this project up for testing and log in
---

> `tf.sh` = `"$CLAUDE_PLUGIN_ROOT/scripts/tf.sh"` (not on PATH).

Set up testing here. Arguments: `$ARGUMENTS` (`--tier 0` forces browser-only,
`--ci` also writes a CI workflow).

**1. Work out what this project is.** Delegate to the `stack-detector` agent.
It probes manifests *and* runtimes — a `package.json` does not prove Node is
installed — and writes `tests/framework.json`. It returns six lines; use its
`TIER`/`STACK`/`WHY`. **Never install anything**, and do not re-detect here.

**2. Scaffold**, without overwriting anything that exists:
- `tf.sh init-csv` — creates `tests/`, the suite files and the supporting
  folders in one go
- `tf.sh xlsx` — creates `tests/testcases.xlsx`, the workbook holding flows,
  cases and their statuses. This is the file the user opens and edits; the CSV
  under `tests/.cache/` is the engine's copy. With no Python on the machine it
  says so and the CSV stays at `tests/testcases.csv`.
- `tests/framework.json` from `templates/shared/framework.example.json`
- `tests/credentials.json` from the example — **only if absent**. It holds real
  logins; never overwrite it.
- append to `.gitignore`: `tests/credentials.json`, `tests/.auth/`,
  `tests/.cache/`, `tests/evidence/`, `tests/results/`
- copy `templates/<stack>/` **only if tier >= 1**

**3. Older suites migrate themselves.** Any `tf.sh` call brings an out-of-date
suite up to the current schema and layout on its own, keeping every id, status
and note, and leaving a `.old` backup. Nothing to run, nothing to tell the user
to run — mention it only if you see the migration notice go by.

**4. Log in.** For each role in `credentials.json`, delegate to the
`login-broker` agent — one call per role. It tries `tf.sh login <role>` first,
falls back to a real browser for a JavaScript or SSO login, and leaves **both**
artifacts a run needs: the curl cookie jar at `tests/.auth/<role>.cookies` and
the Playwright storage state at `tests/.auth/<role>.json`. A role with only the
jar looks logged in to the API pass and logged out to every browser case.

It returns `OK`, `FAIL` or `MANUAL`. On `MANUAL` there is a 2FA prompt or a
CAPTCHA: relay what the person has to do and wait — **never try to solve or
bypass one yourself.** Do not start `/test-run` with a role still unresolved.

**Never print a password or cookie into the transcript.** The agent does not
return them; do not go looking for them either.

**5. CI, on `--ci` only.** Delegate to the `ci-wirer` agent: it adapts
`templates/<stack>/ci/github-actions.yml` and wires the `0/1/2/3` exit codes.
Skip this step entirely without the flag.

Finish by telling the user the tier, why, and to run `/test-run`.
